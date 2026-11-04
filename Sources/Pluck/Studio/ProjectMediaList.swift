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
            HStack(spacing: Design.Spacing.controls) {
                PaneSearchField(prompt: audioOnly ? "Search music" : "Search media", text: $search)
                Button {
                    picking = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Import from Pluck Library…")
                .popover(isPresented: $picking, arrowEdge: .trailing) {
                    MediaPanel(nav: StudioNavigator.shared) { urls in
                        Task { await model.importMedia(urls) }
                        picking = false
                    }
                    .frame(width: 340, height: 520)
                }
            }
            .padding(Design.Spacing.controls)
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
                List(files, id: \.self) { path in
                    row(path)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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

    private func row(_ path: String) -> some View {
        let file = URL(fileURLWithPath: path)
        let onTimeline = model.project.clips.contains { $0.path == path } || (model.project.tracks ?? []).contains { $0.items.contains { $0.path == path } }
            || model.project.music.contains { $0.path == path }
        return HStack(spacing: 8) {
            Image(systemName: Converting.isVideo(file) ? "film" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(file.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if onTimeline {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.tertiary)
                    .help("On the timeline")
            }
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small)
            .fill(selection.source == MediaSource(path: path, span: nil) ? Design.Brand.chosenFill : AnyShapeStyle(Color.clear)))
        .contentShape(.rect)
        .onDrag { NSItemProvider(object: file as NSURL) }
        .onTapGesture(count: 2) {
            Task {
                if audioOnly { await model.addMusic(file) } else { await model.add([file]) }
            }
        }
        .onTapGesture { Self.choose(path) }
        .help(audioOnly ? "Drag onto the timeline, or double-click to add it as music" : "Drag onto the timeline, or double-click to add it at the end. Click, then E, comma, full stop, P or R to put it in.")
    }
}
