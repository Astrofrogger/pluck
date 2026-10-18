import SwiftUI

/// The inspector's marks: the markers put down by hand, then what's found in the file at the
/// playhead (its chapters, cuts between shots, pauses, best moments). A click goes there.
struct ProjectMarksPanel: View {
    @Bindable var model: ProjectModel
    @State private var renaming: UUID?
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.section) {
                markers
                if let path = model.focusedPath { FoundMarks(model: model, focus: model.focus(path)) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private var markers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Markers").font(.callout.weight(.semibold))
                Spacer()
                Button("Add Marker", systemImage: "plus") { model.addMarker() }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .help("A marker at the playhead (M)")
            }
            let list = (model.project.markers ?? []).sorted { $0.time < $1.time }
            if list.isEmpty {
                Text("Press M while playing to mark a moment.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(list) { marker in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ProjectMarker.Color.allCases, id: \.self) { color in
                            Button { model.setMarker(marker.id) { $0.color = color } } label: {
                                Label(color.label, systemImage: marker.color == color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "bookmark.fill").foregroundStyle(marker.color.swiftUI)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Colour")
                    if renaming == marker.id {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.setMarker(marker.id) { [name] in $0.title = name }; renaming = nil }
                    } else {
                        Text(marker.title.isEmpty ? String(localized: "Marker") : marker.title)
                            .font(.callout)
                            .foregroundStyle(marker.title.isEmpty ? .secondary : .primary)
                            .lineLimit(2)
                            .onTapGesture(count: 2) { name = marker.title; renaming = marker.id }
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: Format.duration(marker.time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
                .contentShape(.rect)
                .onTapGesture { model.seek(to: marker.time) }
                .contextMenu {
                    Button("Rename…") { name = marker.title; renaming = marker.id }
                    Button("Delete", role: .destructive) { model.removeMarker(marker.id) }
                }
                .help("Click to go there; double-click to name it")
            }
        }
    }
}

/// What's found in one file, in its time; shown where it falls in the edit.
private struct FoundMarks: View {
    @Bindable var model: ProjectModel
    @Bindable var focus: FileFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(focus.file.deletingPathExtension().lastPathComponent).font(.callout.weight(.semibold)).lineLimit(2)
                Spacer()
                if let analysing = focus.analysing {
                    ProgressView().controlSize(.small)
                    Text(analysing).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Which kinds to show.
            let kinds = EditorMarker.Kind.allCases.filter { kind in focus.markers.contains { $0.kind == kind } }
            if !kinds.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(kinds, id: \.self) { kind in
                        let on = focus.shownKinds.contains(kind)
                        Button {
                            if on { focus.shownKinds.remove(kind) } else { focus.shownKinds.insert(kind) }
                        } label: {
                            Label(kind.label, systemImage: kind.symbol).font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
            }
            let shown = focus.markers.filter { focus.shownKinds.contains($0.kind) }.sorted { $0.start < $1.start }
            ForEach(shown.prefix(400)) { marker in
                let out = focus.isOut(marker.start + 0.01)
                HStack(spacing: 8) {
                    Image(systemName: marker.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(marker.title.isEmpty ? marker.kind.one : marker.title)
                        .font(.callout).lineLimit(2)
                        .strikethrough(out)
                        .foregroundStyle(out ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(verbatim: Format.duration(marker.start)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
                .contentShape(.rect)
                .onTapGesture { focus.select(marker) }
                .help(out ? Text("Taken out of the edit") : Text("Click to go there and set the in and out points to it"))
            }
        }
    }
}

extension ProjectMarker.Color {
    var swiftUI: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .purple: .purple
        }
    }

    var label: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .green: String(localized: "Green")
        case .yellow: String(localized: "Yellow")
        case .red: String(localized: "Red")
        case .purple: String(localized: "Purple")
        }
    }
}

extension EditorMarker.Kind {
    /// One of them, by name.
    var one: String {
        switch self {
        case .chapter: String(localized: "Chapter")
        case .cut: String(localized: "Cut")
        case .silence: String(localized: "Pause")
        case .moment: String(localized: "Best moment")
        case .filler: String(localized: "Filler word")
        case .story: String(localized: "Story")
        }
    }

    /// Its colour on the timeline.
    var tint: Color {
        switch self {
        case .chapter: .orange
        case .cut: .white
        case .silence: .gray
        case .moment: .yellow
        case .filler: .red
        case .story: Design.Brand.violet
        }
    }
}
