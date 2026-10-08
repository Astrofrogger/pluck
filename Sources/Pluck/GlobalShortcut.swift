import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, stored as Carbon key code and modifier mask (what RegisterEventHotKey uses).
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey))

    private static let codeKey = "shortcutKeyCode", modifiersKey = "shortcutModifiers"

    static var stored: KeyCombo {
        let d = UserDefaults.standard
        guard d.object(forKey: codeKey) != nil else { return .default }
        return KeyCombo(keyCode: UInt32(d.integer(forKey: codeKey)), modifiers: UInt32(d.integer(forKey: modifiersKey)))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.codeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: Self.modifiersKey)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press while recording.
    init(event: NSEvent) {
        var mods = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(mods))
    }

    // MARK: - Display

    /// "⌃⌥⌘D", using the key's label on the current keyboard layout (so AZERTY shows the right letter).
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static let functionKeys: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeys: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = specialKeys[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    // MARK: - Rules

    private var modifierCount: Int {
        [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & UInt32($0) != 0 }.count
    }

    /// Why this combination can't be used, or nil if it's fine.
    var problem: String? {
        if !Self.functionKeys.contains(Int(keyCode)) && modifierCount < 2 {
            return String(localized: "Use at least two modifier keys, like ⌃⌥⌘D, so it doesn’t clash with shortcuts in other apps.")
        }
        if Self.isUsedByMacOS(self) {
            return String(localized: "macOS already uses \(display). Choose another shortcut.")
        }
        return nil
    }

    /// Shortcuts macOS reserves (Spotlight, screenshots, Mission Control…), as set in System Settings.
    private static func isUsedByMacOS(_ combo: KeyCombo) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let hotKeys = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return hotKeys.contains { hotKey in
            (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool ?? false)
                && (hotKey[kHISymbolicHotKeyCode as String] as? Int) == Int(combo.keyCode)
                && (hotKey[kHISymbolicHotKeyModifiers as String] as? Int) == Int(combo.modifiers)
        }
    }
}

/// The user's shortcut (⌃⌥⌘D by default) from any app: download the link on the clipboard. Uses the
/// system hotkey API, which needs no Accessibility permission (Pluck never sees other keystrokes).
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var combo = KeyCombo.stored
    private var enabled = false
    private var suspended = false
    /// Set when another app already uses the shortcut.
    private(set) var isTaken = false

    private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Self.action = action
    }

    func update(enabled: Bool) {
        self.enabled = enabled
        refresh()
    }

    /// Tries a new combination. Returns why it can't be used, or nil once it's active and saved.
    func change(to newCombo: KeyCombo) -> String? {
        if let problem = newCombo.problem { return problem }
        let previous = combo
        combo = newCombo
        refresh()
        if isTaken {
            combo = previous
            refresh()
            return String(localized: "Another app already uses \(newCombo.display). Choose another shortcut.")
        }
        newCombo.save()
        return nil
    }

    /// Paused while the user records a new shortcut, so pressing the old one doesn't download.
    func setSuspended(_ value: Bool) {
        suspended = value
        refresh()
    }

    private func refresh() {
        unregister()
        if enabled && !suspended { register() }
    }

    private func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcut.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x504C_434B), id: 1) // "PLCK"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        isTaken = status == eventHotKeyExistsErr
        if status != noErr { hotKey = nil }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isTaken = false
    }
}
