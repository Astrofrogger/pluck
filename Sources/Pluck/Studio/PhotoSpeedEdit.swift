import AppKit
import SwiftUI

/// Speed Edit: hold a letter and scroll over the photo to change one setting (Q exposure, W contrast,
/// A highlights, S shadows, D whites, F blacks, T temperature, Y tint, V saturation). ⌥ held: finer.
/// Key held + Space: back to neutral. A tap of the letter does nothing.
enum SpeedEdit {
    struct Target {
        var keyPath: WritableKeyPath<PhotoAdjustments, Double>
        var range: ClosedRange<Double>
        /// How much one scroll point changes the setting.
        var perPoint: Double
        var name: String

        init(_ keyPath: WritableKeyPath<PhotoAdjustments, Double>, range: ClosedRange<Double>, name: String) {
            self.keyPath = keyPath
            self.range = range
            self.perPoint = (range.upperBound - range.lowerBound) / 400
            self.name = name
        }
    }

    static let targets: [ShortcutAction: Target] = [
        .photoSpeedExposure: Target(\.exposure, range: -5...5, name: String(localized: "Exposure")),
        .photoSpeedContrast: Target(\.contrast, range: -100...100, name: String(localized: "Contrast")),
        .photoSpeedHighlights: Target(\.highlights, range: -100...100, name: String(localized: "Highlights")),
        .photoSpeedShadows: Target(\.shadows, range: -100...100, name: String(localized: "Shadows")),
        .photoSpeedWhites: Target(\.whites, range: -100...100, name: String(localized: "Whites")),
        .photoSpeedBlacks: Target(\.blacks, range: -100...100, name: String(localized: "Blacks")),
        .photoSpeedTemperature: Target(\.temperature, range: -100...100, name: String(localized: "Temperature")),
        .photoSpeedTint: Target(\.tint, range: -100...100, name: String(localized: "Tint")),
        .photoSpeedSaturation: Target(\.saturation, range: -100...100, name: String(localized: "Saturation")),
    ]

    /// The setting after a scroll of `scrollDelta` points (a mouse wheel's counted ×4 by the caller);
    /// `precise` (⌥ held) makes the step 5× finer. Stays inside the range.
    static func value(_ current: Double, scrollDelta: CGFloat, precise: Bool, target: Target) -> Double {
        let step = Double(scrollDelta) * target.perPoint / (precise ? 5 : 1)
        let next = min(max(current + step, target.range.lowerBound), target.range.upperBound)
        return (next * 1000).rounded() / 1000
    }

    /// "Exposure +0.45".
    static func label(_ target: Target, _ value: Double) -> String {
        let text = target.range.upperBound <= 10 ? String(format: "%+.2f", value) : String(format: "%+.0f", value)
        return "\(target.name) \(abs(value) < 0.0005 ? text.replacingOccurrences(of: "+", with: "") : text)"
    }

    /// One scroll step, written like a slider (to every synced photo; a gesture is one undo step).
    @MainActor
    @discardableResult
    static func scroll(_ action: ShortcutAction, delta: CGFloat, precise: Bool, paths: [String], shown: String?) -> Double? {
        guard let target = targets[action], let reference = shown ?? paths.first else { return nil }
        let next = value(PhotoCatalog.shared.record(reference).adjust[keyPath: target.keyPath], scrollDelta: delta, precise: precise, target: target)
        set(target, next, paths: paths, shown: shown)
        return next
    }

    @MainActor
    static func reset(_ action: ShortcutAction, paths: [String], shown: String?) {
        guard let target = targets[action] else { return }
        set(target, 0, paths: paths, shown: shown)
    }

    @MainActor
    private static func set(_ target: Target, _ value: Double, paths: [String], shown: String?) {
        PhotoEditing.shared.edit(paths, shown: shown) { $0.adjust[keyPath: target.keyPath] = value }
    }
}

/// Watches the keys and the scroll wheel while the Photo page is up.
@MainActor
@Observable
final class SpeedEditor {
    static let shared = SpeedEditor()
    /// The photos a change reaches and the one shown; nil when Speed Edit is off (not Edit, no photo).
    @ObservationIgnored var context: (() -> (paths: [String], shown: String?)?)?
    /// The pointer is over the loupe (and the window it's in, the only one Speed Edit listens to).
    @ObservationIgnored var overLoupe = false {
        didSet { if overLoupe { window = NSApp.keyWindow } }
    }
    @ObservationIgnored private weak var window: NSWindow?
    /// What the HUD says (nil: hidden).
    private(set) var hud: String?
    @ObservationIgnored private var held: [ShortcutAction: UInt16] = [:]
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self?.keyDown(event) ?? false } ? nil : event
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.keyUp(event) }
            return event
        }
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self?.scroll(event) ?? false } ? nil : event
        }
        monitors = [down, up, wheel].compactMap { $0 }
        // Keys let go in another app never come up here.
        let away = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.held = [:]
                self?.hide(after: 0)
            }
        }
        observers = [away]
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        held = [:]
        overLoupe = false
        hud = nil
        hideTask?.cancel()
    }

    private func action(_ event: NSEvent) -> ShortcutAction? {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        let flags = event.modifierFlags
        return SpeedEdit.targets.keys.first { action in
            let shortcut = Shortcuts.shared.shortcut(action)
            return shortcut.key == key && shortcut.command == flags.contains(.command)
                && shortcut.shift == flags.contains(.shift) && shortcut.control == flags.contains(.control)
        }
    }

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /// Events in the Photo page's window only (not Settings, the Library's or another window).
    private func inPhotoWindow(_ event: NSEvent) -> Bool {
        guard let event = event.window else { return false }
        return window.map { $0 === event } ?? (event === NSApp.mainWindow)
    }

    /// True when the key is used up here.
    private func keyDown(_ event: NSEvent) -> Bool {
        if typing || !inPhotoWindow(event) { return false }
        held = held.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.value)) }
        if event.keyCode == 49, let (action, _) = held.first, let now = context?() {
            SpeedEdit.reset(action, paths: now.paths, shown: now.shown)
            show(action, now)
            return true
        }
        guard !event.isARepeat, let action = action(event), let now = context?() else { return false }
        held[action] = event.keyCode
        show(action, now)
        return false
    }

    private func keyUp(_ event: NSEvent) {
        held = held.filter { $0.value != event.keyCode }
        if held.isEmpty { hide(after: 0.3) }
    }

    /// True when the scroll is used up here.
    private func scroll(_ event: NSEvent) -> Bool {
        // A key let go while the window wasn't looking is not held any more.
        held = held.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.value)) }
        guard overLoupe, !typing, inPhotoWindow(event), let action = held.keys.first, let now = context?() else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
        if delta != 0 {
            SpeedEdit.scroll(action, delta: delta, precise: event.modifierFlags.contains(.option), paths: now.paths, shown: now.shown)
            show(action, now)
        }
        return true
    }

    private func show(_ action: ShortcutAction, _ now: (paths: [String], shown: String?)) {
        guard let target = SpeedEdit.targets[action], let reference = now.shown ?? now.paths.first else { return }
        hideTask?.cancel()
        hud = SpeedEdit.label(target, PhotoCatalog.shared.record(reference).adjust[keyPath: target.keyPath])
    }

    private func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.hud = nil }
        }
    }
}

/// The small readout at the bottom of the loupe.
struct SpeedEditHUD: View {
    @State private var editor = SpeedEditor.shared

    var body: some View {
        if let text = editor.hud {
            Text(text)
                .font(.callout.monospacedDigit().weight(.medium))
                .padding(.horizontal, Design.Spacing.controls).padding(.vertical, Design.Spacing.controls / 2)
                .background(.ultraThinMaterial, in: .capsule)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
