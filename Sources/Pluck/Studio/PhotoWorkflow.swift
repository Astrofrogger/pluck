import SwiftUI

/// The parts of a photo's settings that can be pasted on their own (as in Lightroom's Paste
/// Settings and Sync).
enum PasteGroup: String, CaseIterable, Identifiable, Codable {
    case profile, light, colour, presence, grading, detail, crop, masks, film

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: String(localized: "Profile")
        case .light: String(localized: "Light")
        case .colour: String(localized: "Colour")
        case .presence: String(localized: "Presence")
        case .grading: String(localized: "Mixer, Curves and Wheels")
        case .detail: String(localized: "Detail")
        case .crop: String(localized: "Crop")
        case .masks: String(localized: "Masks")
        case .film: String(localized: "Film")
        }
    }

    /// This part of `copied` given to `record`. Any of the engine's settings bring the copied
    /// photo's engine version along, so they mean the same.
    func apply(_ copied: PhotoRecord, to record: inout PhotoRecord) {
        let from = copied.adjust
        switch self {
        case .profile:
            record.adjust.profile = from.profile
        case .light:
            record.adjust.exposure = from.exposure; record.adjust.contrast = from.contrast
            record.adjust.highlights = from.highlights; record.adjust.shadows = from.shadows
            record.adjust.whites = from.whites; record.adjust.blacks = from.blacks
        case .colour:
            record.adjust.temperature = from.temperature; record.adjust.tint = from.tint
            record.adjust.vibrance = from.vibrance; record.adjust.saturation = from.saturation
        case .presence:
            record.adjust.texture = from.texture; record.adjust.clarity = from.clarity
            record.adjust.dehaze = from.dehaze; record.adjust.vignette = from.vignette
        case .grading:
            record.adjust.mixer = from.mixer; record.adjust.curves = from.curves; record.adjust.wheels = from.wheels
        case .detail:
            record.adjust.sharpen = from.sharpen; record.adjust.noise = from.noise; record.adjust.moire = from.moire
        case .crop:
            record.adjust.crop = from.crop; record.adjust.cropRect = from.cropRect
            record.adjust.cropPortrait = from.cropPortrait; record.adjust.straighten = from.straighten
        case .masks:
            record.adjust.masks = from.masks
        case .film:
            record.filmOn = copied.filmOn; record.film = copied.film
        }
        if self != .film, self != .crop { record.adjust.process = from.process }
    }

    /// The groups last chosen in Choose What to Paste.
    static var chosen: Set<PasteGroup> {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: "photoPasteGroups")?.compactMap(PasteGroup.init(rawValue:))
            return Set(saved ?? allCases.filter { $0 != .crop && $0 != .masks })
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "photoPasteGroups") }
    }
}

/// The copied settings and what the keys do with them (⌘C, ⇧⌘C, ⌘V, ⇧⌘V, ⌥⌘V).
@MainActor
enum PhotoPasteboard {
    /// A key or menu command on the Photo page.
    enum Action { case copy, copyChoosing, paste, pasteChoosing, pastePrevious, level, levelWithWhiteBalance }

    static var copied: PhotoRecord?
    /// The photo that was shown before the one shown now.
    static var lastViewed: String?
    /// Set by the Photo page while it is open; the Edit menu's items call it.
    static var perform: ((Action) -> Void)?

    static func copy(_ path: String) { copied = PhotoCatalog.shared.record(path) }

    /// The focus moved: the photo left becomes the previous one.
    static func focusMoved(from old: String?, to new: String?) {
        if let old, old != new { lastViewed = old }
    }

    /// The chosen parts of the copied settings onto the photos, as one undo step.
    static func paste(_ groups: Set<PasteGroup>, to paths: [String]) {
        guard let copied else { return }
        apply(copied, groups, to: paths)
    }

    /// The previous photo's settings (its chosen parts) onto the photos.
    static func pastePrevious(to paths: [String]) {
        // (A copy taken away since isn't anything to paste.)
        guard let last = lastViewed, !PhotoCatalog.isCopy(last) || PhotoCatalog.shared.records[last] != nil else { NSSound.beep(); return }
        apply(PhotoCatalog.shared.record(last), PasteGroup.chosen, to: paths.filter { $0 != last })
    }

    private static func apply(_ source: PhotoRecord, _ groups: Set<PasteGroup>, to paths: [String]) {
        guard !paths.isEmpty else { return }
        let catalog = PhotoCatalog.shared
        catalog.endStep()
        catalog.update(paths) { record in
            for group in PasteGroup.allCases where groups.contains(group) { group.apply(source, to: &record) }
            record.edited = .now
        }
        catalog.endStep()
    }
}

/// Choose What to Paste (or to copy): which parts of the settings go onto the selected photos.
struct PasteChooser: View {
    let count: Int
    var copying = false
    let paste: (Set<PasteGroup>) -> Void
    @State private var groups = PasteGroup.chosen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copying ? "Copy" : "Paste").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(PasteGroup.allCases) { group in
                    Toggle(group.title, isOn: Binding(get: { groups.contains(group) },
                                                      set: { on in if on { groups.insert(group) } else { groups.remove(group) } }))
                }
            }
            HStack {
                Button("All") { groups = Set(PasteGroup.allCases) }.buttonStyle(.link)
                Button("None") { groups = [] }.buttonStyle(.link)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    PasteGroup.chosen = groups
                    paste(groups)
                    dismiss()
                } label: {
                    if copying { Text("Copy") } else { Text("Paste to ^[\(count) photo](inflect: true)") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
