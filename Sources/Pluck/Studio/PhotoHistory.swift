import SwiftUI

/// The History panel: this photo's edit steps, kept between sessions (newest at the top, the ones undone greyed), each named by what
/// it changed, and the photo as it was at the start (Original). A click takes the photo back to that step, as a change of its
/// own (so it can be undone again, and the steps after it stay in the list).
struct PhotoHistoryPanel: View {
    let path: String
    @State private var catalog = PhotoCatalog.shared

    var body: some View {
        let _ = catalog.historyVersion
        let steps = catalog.history(of: path)
        let current = catalog.records[path]
        VStack(alignment: .leading, spacing: 2) {
            Text("History").font(Design.Studio.sectionTitle).padding(.horizontal, Design.Sidebar.rowPadding).padding(.bottom, 6)
            if steps.isEmpty {
                Text("Changes made to this photo show here, newest first. Click one to go back to it.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Design.Sidebar.rowPadding)
            }
            ForEach(Array(steps.enumerated().reversed()), id: \.offset) { index, step in
                row(PhotoHistory.describe(step.before, step.after), on: current == step.after && !step.undone, faint: step.undone) {
                    go(to: step.after)
                }
            }
            if let first = steps.first {
                row(String(localized: "Original"), on: current == first.before, faint: false) { go(to: first.before) }
            }
        }
    }

    private func row(_ title: String, on: Bool, faint: Bool, go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 8) {
                Circle().fill(on ? Design.Brand.pink : Design.Studio.line).frame(width: 6, height: 6)
                Text(verbatim: title).font(Design.Studio.body).lineLimit(1)
                    .foregroundStyle(faint ? Design.Studio.textFaint : on ? Design.Studio.text : Design.Studio.textQuiet)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Sidebar.rowPadding)
            .frame(height: 26)
            .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The photo set to how it was then (nil: as it came in), as a change of its own.
    private func go(to record: PhotoRecord?) {
        catalog.endStep()
        catalog.update([path]) { $0 = record ?? PhotoRecord() }
        catalog.endStep()
    }
}

enum PhotoHistory {
    /// A step's name: what it changed ("Exposure +0.40", "Masks", "Rating ★★★"), several joined, at most three.
    static func describe(_ before: PhotoRecord?, _ after: PhotoRecord?) -> String {
        let a = before ?? PhotoRecord(), b = after ?? PhotoRecord()
        var parts: [String] = []
        if a.rating != b.rating { parts.append(String(localized: "Rating") + " " + String(repeating: "★", count: b.rating)) }
        if a.flag != b.flag { parts.append(b.flag == .pick ? String(localized: "Kept") : b.flag == .reject ? String(localized: "Rejected") : String(localized: "Flag removed")) }
        if a.label != b.label { parts.append(String(localized: "Colour Label")) }
        if a.filmOn != b.filmOn { parts.append(b.filmOn ? String(localized: "Film on") : String(localized: "Film off")) } else if a.film != b.film { parts.append(String(localized: "Film")) }
        if a.denoise != b.denoise || a.denoiseAI != b.denoiseAI { parts.append(String(localized: "Denoise")) }
        if a.meta != b.meta { parts.append(String(localized: "Metadata")) }
        if a.snapshots != b.snapshots { parts.append(String(localized: "Snapshot")) }
        parts += adjustments(a.adjust, b.adjust)
        if parts.isEmpty { return String(localized: "Edit") }
        return parts.count > 3 ? parts.prefix(3).joined(separator: ", ") + " …" : parts.joined(separator: ", ")
    }

    /// The edit's changes, each by its slider's name with its new value when it's a number.
    static func adjustments(_ a: PhotoAdjustments, _ b: PhotoAdjustments) -> [String] {
        let old = Dictionary(uniqueKeysWithValues: Mirror(reflecting: a).children.compactMap { child in child.label.map { ($0, child.value) } })
        var parts: [String] = []
        for child in Mirror(reflecting: b).children {
            guard let label = child.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")), let before = old[child.label ?? ""],
                  String(describing: before) != String(describing: child.value), let name = names[label] else { continue }
            if let value = child.value as? Double {
                parts.append(name + " " + (label == "exposure" ? String(format: "%+.2f", value) : String(format: "%+.0f", value)))
            } else {
                parts.append(name)
            }
        }
        return parts
    }

    /// The edit's fields by their names in the panels (fields not listed aren't named in a step).
    static let names: [String: String] = [
        "exposure": String(localized: "Exposure"), "contrast": String(localized: "Contrast"), "highlights": String(localized: "Highlights"),
        "shadows": String(localized: "Shadows"), "whites": String(localized: "Whites"), "blacks": String(localized: "Blacks"),
        "temperature": String(localized: "Temperature"), "tint": String(localized: "Tint"), "vibrance": String(localized: "Vibrance"),
        "saturation": String(localized: "Saturation"), "texture": String(localized: "Texture"), "clarity": String(localized: "Clarity"),
        "dehaze": String(localized: "Dehaze"), "vignette": String(localized: "Vignette"), "sharpen": String(localized: "Sharpen"),
        "noise": String(localized: "Noise"), "colorNoise": String(localized: "Colour Noise"), "moire": String(localized: "Moiré"),
        "glow": String(localized: "Glow"), "grain": String(localized: "Grain"), "profile": String(localized: "Profile"),
        "lookName": String(localized: "Look"), "lookAmount": String(localized: "Look Amount"), "straighten": String(localized: "Straighten"),
        "crop": String(localized: "Crop"), "cropRect": String(localized: "Crop"), "curves": String(localized: "Curves"),
        "wheels": String(localized: "Colour Wheels"), "mixer": String(localized: "Colour Mixer"), "calibration": String(localized: "Calibration"),
        "masks": String(localized: "Masks"), "spots": String(localized: "Heal"), "perspective": String(localized: "Perspective"),
        "lens": String(localized: "Lens"), "depth": String(localized: "Depth"), "negative": String(localized: "Negative"),
        "rolloff": String(localized: "Highlight Roll-off"), "skin": String(localized: "Smooth Skin"), "liquify": String(localized: "Liquify"),
        "toneEngine": String(localized: "Tone Engine"), "process": String(localized: "Update"),
    ]
}
