import SwiftUI

extension ProjectModel {
    /// Brings files into the project without putting them on the timeline: videos and sound
    /// (folders one level deep), each once. One step to undo. Returns how many came in.
    @discardableResult
    func importMedia(_ files: [URL]) async -> Int {
        var found: [URL] = []
        for file in files {
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &folder) else { continue }
            if folder.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                found += inside.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                found.append(file)
            }
        }
        var known = Set(project.files), new: [String] = []
        for file in found where EditorTarget.canOpen(file) {
            // A moment of a file (from the Library's search) comes in as the whole file.
            let path = file.path
            guard known.insert(path).inserted, await length(of: URL(fileURLWithPath: path)) > 0 else { continue }
            new.append(path)
        }
        guard !new.isEmpty else { return 0 }
        change { project in project.media = project.files + new }
        return new.count
    }

    /// The project's files, or only its songs and other sound.
    func mediaFiles(audioOnly: Bool) -> [String] {
        audioOnly ? project.files.filter { !Converting.isVideo(URL(fileURLWithPath: $0)) } : project.files
    }
}

/// The project's own media (or only its music), to drag onto the timeline. Files come in by
/// dropping them here from Finder, or from the Pluck Library.
struct ProjectMediaList: View {
    @Bindable var model: ProjectModel
    let audioOnly: Bool
    @State private var search = ""
    @State private var picking = false
    @State private var dropTargeted = false
    @State private var selection = MediaSelection.shared
    @FocusState private var listFocused: Bool

    /// Chooses a file for the keys that put media in (E, comma, full stop, P, R), as a click in 3.8.0's media panel did.
    static func choose(_ path: String) {
        MediaSelection.shared.source = MediaSource(path: path, span: nil)
    }

    private var files: [String] {
        let all = model.mediaFiles(audioOnly: audioOnly)
        guard !search.isEmpty else { return all }
        return all.filter { URL(fileURLWithPath: $0).lastPathComponent.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneSearchField(prompt: audioOnly ? "Search music" : "Search media", text: $search)
                .padding(.horizontal, Design.Sidebar.inset)
                .padding(.vertical, Design.Spacing.controls)
            if model.mediaFiles(audioOnly: audioOnly).isEmpty {
                ContentUnavailableView {
                    Label(audioOnly ? "No music yet" : "No media yet", systemImage: audioOnly ? "music.note" : "film.stack")
                } description: {
                    Text("Drop files here")
                } actions: {
                    Button("Import from Pluck Library…") { picking = true }
                        .buttonStyle(GlassCapsuleButtonStyle())
                }
            } else {
                // Not a List: a List insets its rows on its own, off the sidebar's 18.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        SidebarSection(title: Text(audioOnly ? LocalizedStringKey("Music") : "Media"), pinned: true) {
                            ForEach(files, id: \.self) { path in row(path) }
                        } accessory: {
                            importButton
                        }
                    }
                    .padding(.horizontal, Design.Sidebar.inset)
                    .padding(.bottom, 20)
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress { press in
                    // Putting the chosen media in, and playing: the project's, though the list has the focus.
                    let action = Shortcuts.shared.action(for: press, in: .edit)
                    let assembly: Set<ShortcutAction> = [.editAppend, .editInsert, .editOverwrite, .editPlaceOnTop, .editReplace]
                    if let action, assembly.contains(action) { return ProjectView.forward?(press) ?? .ignored }
                    if action == .editFavourite { return MediaFavourites.shared.toggleCurrent(in: model) ? .handled : .ignored }
                    if press.key == .space { return ProjectView.forward?(press) ?? .ignored }
                    return .ignored
                }
            }
        }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            MediaPanel(nav: StudioNavigator.shared) { urls in
                Task { await model.importMedia(urls) }
                picking = false
            }
            .frame(width: 340, height: 520)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(Design.Brand.gradient, lineWidth: 2).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await provider.load(URL.self), url.isFileURL { urls.append(url) }
                }
                await model.importMedia(urls)
            }
            return true
        }
    }

    private var importButton: some View {
        Button {
            picking = true
        } label: {
            Image(systemName: "plus")
        }
        .help("Import from Pluck Library…")
        .accessibilityLabel(Text("Import from Pluck Library…"))
    }

    private func row(_ path: String) -> some View {
        let file = URL(fileURLWithPath: path)
        let onTimeline = model.project.clips.contains { $0.path == path } || (model.project.tracks ?? []).contains { $0.items.contains { $0.path == path } }
            || model.project.music.contains { $0.path == path }
        return SidebarRow(symbol: Converting.isVideo(file) ? "film" : "waveform", title: Text(file.deletingPathExtension().lastPathComponent),
                          detail: model.fileLengths[path].map { Text(Format.duration($0)) },
                          selected: selection.source == MediaSource(path: path, span: nil)) {
            if onTimeline {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.tertiary)
                    .help("On the timeline")
            }
        }
        .task(id: path) { _ = await model.length(of: file) }
        .contentShape(.rect)
        .onDrag { NSItemProvider(object: file as NSURL) }
        .onTapGesture(count: 2) {
            Task {
                if audioOnly { await model.addMusic(file) } else { await model.add([file]) }
            }
        }
        .onTapGesture { Self.choose(path); listFocused = true }
        .help(audioOnly ? "Drag onto the timeline, or double-click to add it as music" : "Drag onto the timeline, or double-click to add it at the end. Click, then E, comma, full stop, P or R to put it in.")
    }
}
