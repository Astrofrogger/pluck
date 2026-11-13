import SwiftUI

/// The crop's Perspective section (in the inspector while cropping): the keystone sliders, and one-click Level, Vertical and
/// Auto, each one undo step that fills the sliders in for fine-tuning. Straighten stays on the crop's bar.
struct PhotoPerspectivePanel: View {
    let path: String
    let record: PhotoRecord
    @State private var catalog = PhotoCatalog.shared
    @State private var working = false
    @State private var nothingFound = false

    var body: some View {
        let p = record.adjust.perspective ?? PhotoPerspective()
        AdjustFold(title: "Perspective", section: .perspective, adjust: record.adjust, open: true, reset: { set { $0 = PhotoPerspective() } }) {
            slider("Vertical", p.vertical, \.vertical, -100...100)
            slider("Horizontal", p.horizontal, \.horizontal, -100...100)
            slider("Aspect", p.aspect, \.aspect, -100...100)
            slider("Scale", p.scale, \.scale, 100...150, neutral: 100, format: "%.0f%%")
            HStack(spacing: 6) {
                auto("Level (horizon)", .level, help: "Straighten to the horizon")
                auto("Vertical", .vertical, help: "Make upright lines upright and parallel")
                auto("Auto", .both, help: "Level and upright lines together")
                Button("Reset") { set { $0 = PhotoPerspective() } }
                    .disabled(record.adjust.perspective == nil)
                    .help("Take the perspective away")
            }
            .buttonStyle(StudioFlatButtonStyle())
            .disabled(working)
            .padding(.top, 6)
            .padding(.horizontal, Design.Sidebar.rowPadding)
            if nothingFound {
                Text("No clear lines found in this photo.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .padding(.horizontal, Design.Sidebar.rowPadding).padding(.top, 4)
            }
        }
        .onChange(of: path) { nothingFound = false }
    }

    private func slider(_ title: LocalizedStringKey, _ value: Double, _ key: WritableKeyPath<PhotoPerspective, Double>,
                        _ range: ClosedRange<Double>, neutral: Double = 0, format: String = "%+.0f") -> some View {
        AdjustSlider(title: title, value: value, range: range, neutral: neutral, format: format) { new in set { $0[keyPath: key] = new } }
    }

    private func set(_ change: (inout PhotoPerspective) -> Void) {
        catalog.update([path]) { record in
            var p = record.adjust.perspective ?? PhotoPerspective()
            change(&p)
            record.adjust.perspective = p
            record.edited = .now
        }
    }

    private func auto(_ title: LocalizedStringKey, _ kind: PhotoPerspectiveAuto.Kind, help: LocalizedStringKey) -> some View {
        Button(title) {
            working = true
            Task {
                nothingFound = !(await PhotoPerspectiveAuto.run(kind, path: path))
                working = false
            }
        }
        .help(help)
    }
}

/// Level, Vertical and Auto: measured on the photo without its straightening or perspective, then set as one undo step.
@MainActor
enum PhotoPerspectiveAuto {
    enum Kind: Sendable { case level, vertical, both }

    /// The photo's lines and horizon, measured on a copy at most 1024 px across.
    static func reading(_ path: String) async -> PhotoPerspective.Reading? {
        var plain = PhotoCatalog.shared.record(path)
        plain.filmOn = false
        plain.adjust.straighten = 0
        plain.adjust.perspective = nil
        plain.adjust.crop = .original
        plain.adjust.cropRect = nil
        guard let image = try? await PhotoRender.develop(path, record: plain, maxSize: 1024) else { return nil }
        return await Task.detached(priority: .userInitiated) { PhotoPerspective.read(image) }.value
    }

    /// The turn and the perspective a kind of auto finds (nil: nothing it trusts).
    nonisolated static func found(_ kind: Kind, _ r: PhotoPerspective.Reading, keeping p: PhotoPerspective) -> (turn: Double, perspective: PhotoPerspective)? {
        func level() -> (Double, PhotoPerspective)? {
            // (A turn past 20° is more likely a misreading than a horizon.)
            guard let turn = PhotoPerspective.level(r), abs(turn) <= 20 else { return nil }
            return ((turn * 10).rounded() / 10, p)
        }
        func upright() -> (Double, PhotoPerspective)? {
            guard let found = PhotoPerspective.upright(r, keeping: p) else { return nil }
            var q = p
            q.vertical = found.vertical
            return (found.turn, q)
        }
        switch kind {
        case .level: return level()
        case .vertical: return upright()
        // Upright lines decide the turn when there are some (levelling them levels the photo); else the horizon.
        case .both: return upright() ?? level()
        }
    }

    /// Does it; false when nothing was found.
    static func run(_ kind: Kind, path: String) async -> Bool {
        guard let r = await reading(path) else { return false }
        let keep = PhotoCatalog.shared.record(path).adjust.perspective ?? PhotoPerspective()
        guard let result = await Task.detached(priority: .userInitiated, operation: { found(kind, r, keeping: keep) }).value else { return false }
        let catalog = PhotoCatalog.shared
        catalog.endStep()
        catalog.update([path]) { record in
            record.adjust.straighten = min(max(result.turn, -45), 45)
            record.adjust.perspective = result.perspective
            record.edited = .now
        }
        catalog.endStep()
        return true
    }
}

/// A light grid over the picture while its perspective is set, to line things up against.
struct PerspectiveGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1..<8 {
                let x = size.width * Double(i) / 8, y = size.height * Double(i) / 8
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
