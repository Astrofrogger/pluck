import AppKit
import SwiftUI

/// A key, with the modifiers held with it ("⌘B").
struct Shortcut: Codable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    func matches(_ press: KeyPress) -> Bool {
        let m = press.modifiers
        return press.characters.lowercased() == key && m.contains(.command) == command && m.contains(.shift) == shift
            && m.contains(.option) == option && m.contains(.control) == control
    }

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
    }

    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return nil }
        key = characters
        let flags = event.modifierFlags
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }
}

/// Everything that has a key on the Photo and Edit pages. The keys can be changed in Settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case photoGrid, photoCull, photoEdit, photoCompare, photoCrop, photoZoom, photoClipping, photoTurnCrop, photoPick, photoReject, photoUnflag
    case editSelect, editBlade, editSplit, editDuplicate, editUndo, editRedo, editSnapping, editMarkIn, editMarkOut, editTitle

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case photo, edit
        var title: String { self == .photo ? String(localized: "Photo") : String(localized: "Edit") }
    }

    var group: Group { rawValue.hasPrefix("photo") ? .photo : .edit }

    var title: String {
        switch self {
        case .photoGrid: String(localized: "Grid")
        case .photoCull: String(localized: "Cull")
        case .photoEdit: String(localized: "Edit one photo")
        case .photoCompare: String(localized: "Compare two photos")
        case .photoClipping: String(localized: "Show clipping")
        case .photoCrop: String(localized: "Crop")
        case .photoZoom: String(localized: "Zoom to 100%")
        case .photoTurnCrop: String(localized: "Turn the crop")
        case .photoPick: String(localized: "Pick")
        case .photoReject: String(localized: "Reject")
        case .photoUnflag: String(localized: "Unflag")
        case .editSelect: String(localized: "Selection tool")
        case .editBlade: String(localized: "Blade tool")
        case .editSplit: String(localized: "Split at the playhead")
        case .editDuplicate: String(localized: "Duplicate")
        case .editUndo: String(localized: "Undo")
        case .editRedo: String(localized: "Redo")
        case .editSnapping: String(localized: "Snapping")
        case .editMarkIn: String(localized: "Mark in")
        case .editMarkOut: String(localized: "Mark out")
        case .editTitle: String(localized: "Add a title")
        }
    }

    /// As in Lightroom and DaVinci Resolve.
    var standard: Shortcut {
        switch self {
        case .photoGrid: Shortcut("g")
        case .photoCull: Shortcut("n")
        case .photoEdit: Shortcut("e")
        case .photoCompare: Shortcut("c", shift: true)
        case .photoClipping: Shortcut("j")
        case .photoCrop: Shortcut("c")
        case .photoZoom: Shortcut("z")
        case .photoTurnCrop: Shortcut("x", shift: true)
        case .photoPick: Shortcut("p")
        case .photoReject: Shortcut("x")
        case .photoUnflag: Shortcut("u")
        case .editSelect: Shortcut("a")
        case .editBlade: Shortcut("b")
        case .editSplit: Shortcut("b", command: true)
        case .editDuplicate: Shortcut("d", command: true)
        case .editUndo: Shortcut("z", command: true)
        case .editRedo: Shortcut("z", command: true, shift: true)
        case .editSnapping: Shortcut("n")
        case .editMarkIn: Shortcut("i")
        case .editMarkOut: Shortcut("o")
        case .editTitle: Shortcut("t", command: true)
        }
    }
}

/// The keys people chose (only the changed ones are kept).
@MainActor
@Observable
final class Shortcuts {
    static let shared = Shortcuts()
    private static let key = "shortcuts"
    private(set) var changed: [String: Shortcut] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            changed = saved
        }
    }

    func shortcut(_ action: ShortcutAction) -> Shortcut { changed[action.rawValue] ?? action.standard }

    func set(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        changed[action.rawValue] = shortcut == action.standard ? nil : shortcut
        if let data = try? JSONEncoder().encode(changed) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func resetAll() {
        changed = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// The action a key press is for, on a page.
    func action(for press: KeyPress, in group: ShortcutAction.Group) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.group == group && shortcut($0).matches(press) }
    }

    /// Other actions on the same page with this key.
    func clashes(_ action: ShortcutAction) -> [ShortcutAction] {
        let mine = shortcut(action)
        return ShortcutAction.allCases.filter { $0 != action && $0.group == action.group && shortcut($0) == mine }
    }
}

/// Settings ▸ Keys.
struct ShortcutSettings: View {
    @State private var shortcuts = Shortcuts.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?

    var body: some View {
        Form {
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        LabeledContent {
                            HStack(spacing: 6) {
                                if !shortcuts.clashes(action).isEmpty {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        .help(String(localized: "Also used for: \(shortcuts.clashes(action).map(\.title).joined(separator: ", "))"))
                                }
                                Button(recording == action ? String(localized: "Type a key…") : shortcuts.shortcut(action).label) {
                                    recording == action ? stop() : record(action)
                                }
                                .frame(minWidth: 90)
                                if shortcuts.shortcut(action) != action.standard {
                                    Button { shortcuts.set(action, nil) } label: { Image(systemName: "arrow.counterclockwise") }
                                        .buttonStyle(.borderless)
                                        .help("Back to \(action.standard.label)")
                                }
                            }
                        } label: {
                            Text(action.title)
                        }
                    }
                }
            }
            Section {
                Button("Restore All Keys") { shortcuts.resetAll() }
            } footer: {
                Text("Click a key, then press the new one. Esc cancels.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }

    private func record(_ action: ShortcutAction) {
        stop()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if let shortcut = Shortcut(event: event) { shortcuts.set(action, shortcut) }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
