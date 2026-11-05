import SwiftUI

/// The Editor's sidebar, like an editing program's inspector: a row of tabs at the top, and under
/// it one compact panel at a time. In Pluck Studio: the transcript and local AI; always: what's
/// marked on the timeline and the parts of the edit.
struct EditorSidebar: View {
    @Bindable var model: EditorModel
    @AppStorage("editorSidebarTab") private var tab = Tab.ai

    enum Tab: String, CaseIterable, Identifiable {
        case ai, transcript, subtitles, picture, marks, export
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .picture: "crop.rotate"
            case .transcript: "text.quote"
            case .ai: "sparkles"
            case .subtitles: "captions.bubble"
            case .marks: "bookmark"
            case .export: "square.and.arrow.up"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .transcript: "Transcript"
            case .ai: "Local AI"
            case .subtitles: "Subtitles"
            case .picture: "Picture"
            case .marks: "Timeline"
            case .export: "Export"
            }
        }
    }

    private var tabs: [Tab] {
        #if STUDIO
        Tab.allCases
        #else
        [.marks, .export]
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                InspectorTabBar(tabs: tabs, selection: $tab, symbol: \.symbol) { Text($0.title) }
                Divider()
            }
            Text(shown.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Group {
                switch shown {
                #if STUDIO
                case .transcript: EditorAIPanel(model: model, part: .transcript)
                case .ai: EditorAIPanel(model: model, part: .ai)
                case .subtitles: EditorAIPanel(model: model, part: .subtitles)
                #endif
                case .export: EditorExportPanel(model: model)
                case .picture:
                    #if STUDIO
                    ScrollView {
                        ClipLookEditor(look: model.look ?? ClipLook(), path: model.file.path, showsSpeed: false) { record, body in
                            model.changeLook(record: record, body)
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: Stabilizer.shared.finished) { _, _ in Task { await model.applyLook() } }
                    #else
                    EmptyView()
                    #endif
                default: marks
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(.background.secondary)
    }

    private var shown: Tab { tabs.contains(tab) ? tab : .marks }

    // MARK: - Timeline marks and parts

    private var marks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SidebarSection(title: Text("Show")) {
                    ForEach(EditorMarker.Kind.allCases, id: \.self) { kind in
                        let count = model.markers.filter { $0.kind == kind }.count
                        if count > 0 || kind == .chapter || kind == .cut || kind == .silence {
                            SidebarRow(symbol: kind.symbol, title: Text(kind.label), detail: Text(verbatim: "\(count)")) {
                                if kind == .silence, count > 0 {
                                    Button("Cut All") { model.cutOut(model.markers.filter { $0.kind == .silence }.compactMap(\.span)) }
                                        .buttonStyle(.link)
                                        .help("Cut every pause out of the edit (⌘Z undoes it)")
                                }
                                Toggle("", isOn: Binding(get: { model.shownKinds.contains(kind) },
                                                         set: { if $0 { model.shownKinds.insert(kind) } else { model.shownKinds.remove(kind) } }))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                            }
                        }
                    }
                    if let analysing = model.analysing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(analysing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    }
                }

                let chapters = model.markers.filter { $0.kind == .chapter }
                if !chapters.isEmpty {
                    SidebarSection(title: Text("Chapters")) {
                        ForEach(chapters) { chapter in
                            SidebarRow(symbol: "list.number", title: Text(chapter.title), detail: Text(model.timecode(chapter.start))) {
                                EmptyView()
                            }
                            .onTapGesture { model.select(chapter) }
                            .help("Select this chapter")
                        }
                    }
                }

                if model.isEdited {
                    SidebarSection(title: Text("Parts")) {
                        ForEach(Array(model.parts.enumerated()), id: \.element.id) { index, part in
                            SidebarRow(symbol: part.removed ? "scissors" : "film", title: Text("Part \(index + 1)"),
                                       detail: Text(model.timecode(part.length)), dimmed: part.removed,
                                       selected: model.selected.contains(part.start)) {
                                EmptyView()
                            }
                            .onTapGesture {
                                model.select(at: part.start + model.frame, adding: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                                model.seek(to: part.start)
                            }
                        }
                        HStack {
                            Text("Edit \(model.timecode(model.editLength))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") { model.resetEdit() }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Remove all cuts and bring every part back")
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .panelColumn()
            .padding(.bottom, 12)
        }
    }
}

/// A section of the sidebar: a dim Title Case header and rows. With a `fold` key it folds by its
/// header (remembered) and shows its `count` while folded; an `accessory` (a `+`) shows on hover.
/// `pinned` makes it a `Section`, whose header stays at the top of a
/// `LazyVStack(pinnedViews: .sectionHeaders)` while its rows scroll under it.
struct SidebarSection<Content: View, Accessory: View>: View {
    let title: Text
    var count: Int?
    var pinned = false
    private let foldable: Bool
    @AppStorage private var folded: Bool
    private let content: Content
    private let accessory: Accessory
    @State private var hovering = false

    init(title: Text, fold key: String? = nil, count: Int? = nil, pinned: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.pinned = pinned
        foldable = key != nil
        _folded = AppStorage(wrappedValue: false, "sidebar-fold-" + (key ?? ""))
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        if pinned {
            Section {
                if !isFolded { content }
            } header: {
                // Opaque, in the panel's own colour: a panel's `.background(.background.secondary)` makes
                // that its background style, so `.secondary` here again would be a level lighter.
                header.background(.background)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !isFolded { content }
            }
        }
    }

    private var isFolded: Bool { foldable && folded }

    private var header: some View {
        HStack(spacing: 0) {
            // The chevron sits in the gutter left of the title (on hover, and while folded).
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isFolded ? 0 : 90))
                .frame(width: Design.Sidebar.rowPadding)
                .opacity(foldable && (hovering || isFolded) ? 1 : 0)
                .accessibilityHidden(true)
            title
                .font(Design.Sidebar.header)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isFolded, let count {
                Text(verbatim: "\(count)").font(Design.Sidebar.count).foregroundStyle(.tertiary)
            }
            accessory
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.trailing, Design.Sidebar.rowPadding)
        .frame(height: Design.Sidebar.headerHeight)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { if foldable { withAnimation(.snappy(duration: 0.2)) { folded.toggle() } } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SidebarSection where Accessory == EmptyView {
    init(title: Text, fold key: String? = nil, count: Int? = nil, pinned: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, fold: key, count: count, pinned: pinned, content: content) { EmptyView() }
    }
}

/// The hairline between two sections of a sidebar, in the middle of the gap.
struct SidebarGap: View {
    var body: some View {
        Divider()
            .padding(.horizontal, Design.Sidebar.rowPadding)
            .padding(.vertical, Design.Sidebar.sectionGap / 2)
    }
}

/// One row of the sidebar: a symbol, a name, a value (a count, a duration), and controls on the
/// right. Lights up under the pointer. In a tree: `indent` levels in, and `open` puts a chevron
/// in the gutter left of the symbol (true: unfolded).
struct SidebarRow<Trailing: View>: View {
    let symbol: String
    let title: Text
    var detail: Text?
    var dimmed = false
    var selected = false
    var indent = 0
    var open: Bool?
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open == true ? 90 : 0))
                .frame(width: Design.Sidebar.rowPadding)
                .opacity(open == nil ? 0 : 1)
                .accessibilityHidden(true)
            HStack(spacing: Design.Sidebar.iconGap) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: Design.Sidebar.icon)
                    .accessibilityHidden(true)
                title.font(Design.Sidebar.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                detail?.font(Design.Sidebar.count).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                trailing
            }
        }
        .font(.callout)
        .opacity(dimmed ? 0.45 : 1)
        .padding(.leading, CGFloat(indent) * Design.Sidebar.indent)
        .padding(.trailing, Design.Sidebar.rowPadding)
        .frame(minHeight: Design.Sidebar.rowHeight)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small)
            .fill(selected ? Design.Brand.chosenFill : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

extension EditorMarker {
    /// From start to end, for markers that last.
    var span: ClosedRange<Double>? { end.map { start...max($0, start) } }
}
