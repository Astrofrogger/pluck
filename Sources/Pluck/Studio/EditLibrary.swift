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
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    switch kind {
                    case .transitions:
                        grid(ProjectTransition.Kind.allCases.map { kind in
                            Tile(item: .transition(kind), title: Text(ProjectTransition(kind: kind, length: 1).label)) {
                                TransitionPreview(kind: kind, thumbnails: previewFrames)
                            }
                        })
                    case .titles:
                        grid([Tile(item: .plainTitle, title: Text("Title")) { SymbolPreview(symbol: "textformat") }])
                        ForEach(MotionTemplate.Category.allCases) { category in
                            let templates = MotionTemplate.all.filter { $0.category == category }
                            if !templates.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(category.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    }
                }
                .padding(Design.Spacing.controls)
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

/// A transition playing between two pictures of the edit while the pointer is over it.
private struct TransitionPreview: View {
    let kind: ProjectTransition.Kind
    let thumbnails: [NSImage]
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(paused: !hovering)) { context in
            let p = hovering ? (sin(context.date.timeIntervalSinceReferenceDate * 2) + 1) / 2 : 0
            ZStack {
                picture(0, fallback: Design.Brand.pink)
                switch kind {
                case .dissolve:
                    picture(1, fallback: Design.Brand.violet).opacity(p)
                case .dipBlack, .dipWhite:
                    picture(1, fallback: Design.Brand.violet).opacity(p > 0.5 ? 1 : 0)
                    (kind == .dipBlack ? Color.black : Color.white).opacity(1 - abs(p - 0.5) * 2)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func picture(_ index: Int, fallback: Color) -> some View {
        if thumbnails.indices.contains(index) {
            Image(nsImage: thumbnails[index]).resizable().scaledToFill()
        } else {
            fallback.opacity(0.6)
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
