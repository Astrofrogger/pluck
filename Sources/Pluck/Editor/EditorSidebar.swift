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
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }
}

/// A section of the sidebar: a small title and compact rows.
struct SidebarSection<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            content
        }
    }
}

/// One compact row of the sidebar: a symbol, a name, a value, and controls on the right. Lights
/// up under the pointer.
struct SidebarRow<Trailing: View>: View {
    let symbol: String
    let title: Text
    var detail: Text?
    var dimmed = false
    var selected = false
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            title.lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            detail?.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            trailing
        }
        .font(.callout)
        .opacity(dimmed ? 0.45 : 1)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
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
