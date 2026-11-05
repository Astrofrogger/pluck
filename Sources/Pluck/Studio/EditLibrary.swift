import CoreImage
import SwiftUI

/// The Transitions, Titles and Effects tabs of the Edit page's panel: tiles to drag onto the
/// timeline (a transition onto a cut, a title where it should start, a look over the clips), or to
/// double-click at the playhead.
struct EditLibraryList: View {
    enum Kind { case transitions, titles, effects }

    @Bindable var model: ProjectModel
    let kind: Kind
    @State private var applying = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Design.Spacing.controls)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch kind {
                    case .transitions:
                        ForEach(Array(ProjectTransition.Group.allCases.enumerated()), id: \.element) { index, group in
                            if index > 0 { SidebarGap() }
                            SidebarSection(title: Text(group.label)) {
                                grid(group.kinds.map { kind in
                                    Tile(item: .transition(kind), title: Text(ProjectTransition(kind: kind, length: 1).label)) {
                                        TransitionPreview(kind: kind, thumbnails: previewFrames)
                                    }
                                })
                            }
                        }
                    case .titles:
                        grid([Tile(item: .plainTitle, title: Text("Title")) { SymbolPreview(symbol: "textformat") }])
                            .padding(.top, Design.Spacing.controls)
                        ForEach(MotionTemplate.Category.allCases) { category in
                            let templates = MotionTemplate.all.filter { $0.category == category }
                            if !templates.isEmpty {
                                SidebarGap()
                                SidebarSection(title: Text(category.label)) {
                                    grid(templates.map { template in
                                        Tile(item: .title(templateID: template.id), title: Text(template.name)) {
                                            TemplatePreview(template: template)
                                        }
                                    })
                                }
                            }
                        }
                    case .effects:
                        grid([
                            Tile(item: .adjustment, title: Text("Look")) { SymbolPreview(symbol: "camera.filters") },
                            Tile(item: .stabilize, title: Text("Stabilize")) { SymbolPreview(symbol: "hand.raised.slash") },
                        ])
                        .padding(.top, Design.Spacing.controls)
                    }
                }
                .padding(.horizontal, Design.Sidebar.inset)
                .padding(.bottom, Design.Spacing.controls)
            }
            if applying {
                ProgressView().controlSize(.small).padding(.bottom, Design.Spacing.controls)
            } else if let problem = model.libraryProblem {
                ProblemLabel(text: problem).padding(Design.Spacing.controls)
            }
        }
    }

    /// Two pictures from the edit for the transitions to play between.
    private var previewFrames: [NSImage] {
        let clips = model.project.clips
        func frames(_ clip: ProjectClip?) -> [NSImage] { clip.flatMap { model.thumbnails[ProjectModel.thumbnailKey($0)] } ?? [] }
        let first = frames(clips.first).first
        let second = frames(clips.dropFirst().first).first ?? frames(clips.first).dropFirst(3).first
        return [first, second].compactMap { $0 }
    }

    private func grid(_ tiles: [Tile]) -> some View {
        // The tiles keep the rows' 18 from the panel's edge.
        LazyVGrid(columns: columns, spacing: Design.Spacing.controls) {
            ForEach(tiles) { tile in
                VStack(spacing: 4) {
                    tile.preview
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: Design.Radius.small))
                    tile.title.font(.caption).lineLimit(1).truncationMode(.tail)
                }
                .contentShape(.rect)
                .draggable(tile.item.payload)
                .onTapGesture(count: 2) {
                    applying = true
                    Task {
                        await model.apply(tile.item, at: model.time)
                        applying = false
                    }
                }
                .help(help(tile.item))
            }
        }
        .padding(.horizontal, Design.Sidebar.rowPadding)
    }

    private func help(_ item: EditLibraryItem) -> LocalizedStringKey {
        switch item {
        case .transition: "Drag onto a cut, or double-click for the cut nearest the playhead"
        case .title, .plainTitle: "Drag onto the timeline where it should start, or double-click for the playhead"
        case .adjustment: "Drag onto the timeline for a look over five seconds, or double-click for the playhead"
        case .stabilize: "Drag onto a clip to steady it, or double-click for the clip at the playhead"
        }
    }

    private struct Tile: Identifiable {
        let item: EditLibraryItem
        let title: Text
        let preview: AnyView
        var id: String { item.payload }

        init<Preview: View>(item: EditLibraryItem, title: Text, @ViewBuilder preview: () -> Preview) {
            self.item = item
            self.title = title
            self.preview = AnyView(preview())
        }
    }
}

/// A plain tile: a symbol on the panel's fill.
private struct SymbolPreview: View {
    let symbol: String

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
        }
    }
}

/// A transition playing between two pictures of the edit while the pointer is over it (drawn as
/// the viewer draws it, small).
private struct TransitionPreview: View {
    let kind: ProjectTransition.Kind
    let thumbnails: [NSImage]
    @State private var hovering = false
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let size = CGSize(width: 160, height: 90)

    var body: some View {
        TimelineView(.animation(paused: !hovering)) { context in
            let p = hovering ? (sin(context.date.timeIntervalSinceReferenceDate * 2) + 1) / 2 : 0.5
            ZStack {
                switch kind {
                case .dipBlack, .dipWhite:
                    picture(p > 0.5 ? 1 : 0)
                    (kind == .dipBlack ? Color.black : Color.white).opacity(1 - abs(p - 0.5) * 2)
                default:
                    if let frame = frame(p) { Image(decorative: frame, scale: 1).resizable() }
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func source(_ index: Int) -> CIImage {
        let rect = CGRect(origin: .zero, size: Self.size)
        guard thumbnails.indices.contains(index), let cg = thumbnails[index].cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            let colour = index == 0 ? CIColor(red: 0.95, green: 0.35, blue: 0.6) : CIColor(red: 0.45, green: 0.3, blue: 0.95)
            return CIImage(color: colour).cropped(to: rect)
        }
        let image = CIImage(cgImage: cg)
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: rect)
    }

    private func frame(_ p: Double) -> CGImage? {
        let image = ProjectTransitions.blend(kind, from: source(0), to: source(1), progress: p, size: Self.size)
        return Self.context.createCGImage(image, from: CGRect(origin: .zero, size: Self.size))
    }

    @ViewBuilder private func picture(_ index: Int) -> some View {
        if thumbnails.indices.contains(index) {
            Image(nsImage: thumbnails[index]).resizable().scaledToFill()
        } else {
            (index == 0 ? Design.Brand.pink : Design.Brand.violet).opacity(0.6)
        }
    }
}

/// A motion template as it looks once it's in (drawn once, small).
private struct TemplatePreview: View {
    let template: MotionTemplate
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
        }
        .task(id: template.id) { image = draw() }
    }

    private func draw() -> CGImage? {
        let size = CGSize(width: 320, height: 180)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let kit = BrandKit.shared
        template.render(t: 2.5, in: context, canvas: size, style: kit.style, placement: kit.placement(template))
        return context.makeImage()
    }
}
