import SwiftUI
import UniformTypeIdentifiers

/// The Photo page: albums and folders on the left, the photos in a grid to cull (rate, pick,
/// reject with the keyboard) or one at a time with a filmstrip, and the inspector with the
/// adjustments, the film (spektrafilm) and the export. Edits apply to every selected photo.
struct PhotoPage: View {
    @State private var catalog = PhotoCatalog.shared
    @State private var folders = FootageFolders.shared
    @AppStorage("photoSidebarWidth") private var inspectorWidth = 310.0
    @AppStorage("photoInspectorTab") private var tab = PhotoInspector.Tab.adjust
    @AppStorage("photoGridSize") private var gridSize = 180.0
    @AppStorage("photoAutoAdvance") private var autoAdvance = true
    @AppStorage("photoSource") private var sourceKey = "all"
    @State private var selection: Set<String> = []
    @State private var focus: String?
    /// Grid (many at once), Cull (one at a time, quick: the camera's own preview), or Edit.
    enum ViewMode: String { case grid, cull, edit, compare }
    @AppStorage("photoView") private var view = ViewMode.grid
    private var loupe: Bool { view != .grid }
    @State private var flagFilter: PhotoRecord.Flag?
    @State private var minRating = 0
    @State private var renamingAlbum: UUID?
    @State private var albumName = ""
    @State private var dropTargeted = false
    @State private var renamingFolder: UUID?
    @State private var folderName = ""
    @State private var closedFolders: Set<UUID> = []

    /// The album or list open on the left (remembered, so a drop goes into the album you see).
    private var source: PhotoCatalog.Source {
        get { PhotoCatalog.Source(key: sourceKey) }
        nonmutating set { sourceKey = newValue.key }
    }
    @FocusState private var focused: Bool
    @State private var editing = PhotoEditing.shared

    @State private var search = ""
    @State private var photoIndex = PhotoIndex.shared

    private var photos: [String] {
        var list = catalog.photos(in: source).filter { path in
            let record = catalog.record(path)
            return record.rating >= minRating && (flagFilter == nil || record.flag == flagFilter)
        }
        // What's in the picture (or its text, or its name).
        let words = search.split(separator: " ").map(String.init)
        if !words.isEmpty {
            let found = photoIndex.search(words, within: Set(list)).map(\.path)
            let byName = list.filter { path in words.allSatisfy { URL(fileURLWithPath: path).lastPathComponent.localizedCaseInsensitiveContains($0) } }
            var seen: Set<String> = []
            list = (found + byName).filter { seen.insert($0).inserted }
        }
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                Group {
                    if photos.isEmpty {
                        empty
                    } else if view == .cull, let focus {
                        VStack(spacing: 0) {
                            PhotoCullView(path: focus, record: catalog.record(focus), neighbours: neighbours(of: focus))
                            filmstrip
                        }
                    } else if view == .compare, let focus {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                PhotoLoupe(path: focus, record: catalog.record(focus), linked: true)
                                if let other = compared(with: focus) {
                                    PhotoLoupe(path: other, record: catalog.record(other), linked: true, primary: false)
                                }
                            }
                            filmstrip
                        }
                    } else if view == .edit, let focus {
                        VStack(spacing: 0) {
                            PhotoLoupe(path: focus, record: catalog.record(focus), neighbours: neighbours(of: focus).prefix(2).map { ($0, catalog.record($0)) })
                            filmstrip
                        }
                    } else {
                        grid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers { if let url = await provider.load(URL.self) { urls.append(url) } }
                    importPhotos(urls)
                }
                return true
            }
            ResizeHandle(width: $inspectorWidth, range: 280...520, edge: .trailing)
            PhotoInspector(tab: $tab, paths: Array(selection.isEmpty ? (focus.map { [$0] } ?? []) : selection).sorted(), focus: focus)
                .frame(width: inspectorWidth)
                .clipped()
        }
        .frame(minWidth: 1000, minHeight: 600)
        .navigationTitle("Photo")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .onKeyPress("\\", phases: [.down, .up]) { press in
            editing.asShot = press.phase == .down
            return .handled
        }
        .onAppear {
            focused = true
            FootageFolders.shared.start()
            PhotoIndex.shared.enqueue(catalog.allPhotos)
            catalog.readSidecars(catalog.allPhotos)
            PhotoRender.trimCaches()
            // Screenshots: -PluckScreenshotLoupe YES shows the first photo large.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotLoupe") {
                focus = photos.first
                view = .edit
            }
            // -PluckScreenshotCompare YES: the first two side by side (with -PluckScreenshotClipping YES: clipping shown).
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotCompare") {
                focus = photos.first
                view = .compare
                editing.showClipping = UserDefaults.standard.bool(forKey: "PluckScreenshotClipping")
            }
            // -PluckScreenshotZoom YES: the first photo at 1:1.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotZoom") {
                focus = photos.first
                view = .edit
                editing.zoomed = true
            }
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotPhotoExport") {
                selection = Set(photos)
            }
        }
        .task { await FilmEngine.shared.loadProfiles() }
        .onChange(of: editing.cropping) { _, cropping in
            guard cropping else { return }
            if focus == nil { focus = photos.first }
            if focus != nil { view = .edit }
            if focus == nil { editing.cropping = false }
        }
        .onChange(of: view) { _, mode in if mode != .edit { editing.cropping = false; editing.zoomed = false } }
        .onDisappear { editing.cropping = false }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SidebarSection(title: Text("Library")) {
                    row(.all, symbol: "photo.on.rectangle", title: Text("All Photos"))
                    row(.picks, symbol: "flag.fill", title: Text("Picks"))
                    row(.fiveStars, symbol: "star.fill", title: Text("5 Stars"))
                    row(.edited, symbol: "slider.horizontal.3", title: Text("Edited"))
                    row(.rejects, symbol: "xmark.circle", title: Text("Rejected"))
                }
                SidebarSection(title: Text("Albums")) {
                    ForEach(catalog.folders) { folder in
                        let open = !closedFolders.contains(folder.id)
                        SidebarRow(symbol: open ? "folder" : "folder.fill", title: Text(folder.name), detail: Text(verbatim: ""), selected: false) {
                            EmptyView()
                        }
                        .onTapGesture { if open { closedFolders.insert(folder.id) } else { closedFolders.remove(folder.id) } }
                        .contextMenu {
                            Button("Rename…") { folderName = folder.name; renamingFolder = folder.id }
                            Button("New Album") { newAlbum(in: folder.id) }
                            Divider()
                            Button("Delete Folder", role: .destructive) { catalog.deleteFolder(folder.id) }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            for id in ids.compactMap(UUID.init(uuidString:)) { catalog.move(album: id, to: folder.id) }
                            return true
                        }
                        if open {
                            ForEach(catalog.albums.filter { $0.folder == folder.id }) { album in
                                albumRow(album).padding(.leading, 14)
                            }
                        }
                    }
                    ForEach(catalog.albums.filter { album in album.folder == nil || !catalog.folders.contains { $0.id == album.folder } }) { album in
                        albumRow(album)
                    }
                    HStack(spacing: 12) {
                        Button { importPhotos() } label: {
                            Label("New Album…", systemImage: "plus")
                        }
                        Button { renamingFolder = catalog.newFolder(named: String(localized: "New Folder")).id; folderName = String(localized: "New Folder") } label: {
                            Label("Folder", systemImage: "folder.badge.plus")
                        }
                        .help("New folder for albums")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                let photoFolders = folders.folders.filter { !(folders.photos[$0.id] ?? []).isEmpty }
                if !photoFolders.isEmpty {
                    SidebarSection(title: Text("Folders")) {
                        ForEach(photoFolders) { folder in
                            row(.folder(folder.id), symbol: "folder", title: Text(folder.name))
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
        }
        .background(.background.secondary)
        .alert("Rename Album", isPresented: Binding(get: { renamingAlbum != nil }, set: { if !$0 { renamingAlbum = nil } })) {
            TextField("Name", text: $albumName)
            Button("Rename") { if let id = renamingAlbum { catalog.rename(id, to: albumName) }; renamingAlbum = nil }
            Button("Cancel", role: .cancel) { renamingAlbum = nil }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderName)
            Button("Rename") { if let id = renamingFolder { catalog.renameFolder(id, to: folderName) }; renamingFolder = nil }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        row(.album(album.id), symbol: "rectangle.stack", title: Text(album.name))
            .contextMenu {
                Button("Rename…") { albumName = album.name; renamingAlbum = album.id }
                Button("Add Photos…") { importPhotos(into: album.id) }
                if !catalog.folders.isEmpty {
                    Menu("Move to Folder") {
                        ForEach(catalog.folders) { folder in Button(folder.name) { catalog.move(album: album.id, to: folder.id) } }
                        if album.folder != nil {
                            Divider()
                            Button("None") { catalog.move(album: album.id, to: nil) }
                        }
                    }
                }
                Divider()
                Button("Delete Album", role: .destructive) {
                    if source == .album(album.id) { source = .all }
                    catalog.deleteAlbum(album.id)
                }
            }
            .draggable(album.id.uuidString)
            .dropDestination(for: URL.self) { urls, _ in
                catalog.add(PhotoCatalog.photos(in: urls), to: album.id)
                return true
            }
    }

    private func newAlbum(in folder: UUID?) {
        let album = catalog.newAlbum(named: String(localized: "Album \(catalog.albums.count + 1)"))
        catalog.move(album: album.id, to: folder)
        source = .album(album.id)
        albumName = album.name
        renamingAlbum = album.id
    }

    private func row(_ item: PhotoCatalog.Source, symbol: String, title: Text) -> some View {
        SidebarRow(symbol: symbol, title: title, detail: Text(verbatim: "\(catalog.photos(in: item).count)"), selected: source == item) {
            EmptyView()
        }
        .onTapGesture {
            source = item
            selection = []
            focus = catalog.photos(in: item).first
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $view) {
                Image(systemName: "square.grid.3x3").tag(ViewMode.grid).help("Grid (\(Shortcuts.shared.shortcut(.photoGrid).label))")
                Image(systemName: "rectangle.stack").tag(ViewMode.cull).help("Cull: quick, one at a time (\(Shortcuts.shared.shortcut(.photoCull).label))")
                Image(systemName: "slider.horizontal.below.rectangle").tag(ViewMode.edit).help("Edit (\(Shortcuts.shared.shortcut(.photoEdit).label))")
                Image(systemName: "rectangle.split.2x1").tag(ViewMode.compare).help("Compare two, zoomed together (\(Shortcuts.shared.shortcut(.photoCompare).label))")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            Menu {
                Button("All") { flagFilter = nil }
                Button("Picks") { flagFilter = .pick }
                Button("Not Flagged") { flagFilter = PhotoRecord.Flag.none }
                Button("Rejected") { flagFilter = .reject }
            } label: {
                Label(flagTitle, systemImage: "flag")
            }
            .fixedSize()
            Menu {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? String(localized: "Any Rating") : String(repeating: "★", count: stars) + "+") { minRating = stars }
                }
            } label: {
                Label(minRating == 0 ? String(localized: "Any Rating") : String(repeating: "★", count: minRating) + "+", systemImage: "star")
            }
            .fixedSize()
            Toggle("Auto-advance", isOn: $autoAdvance)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("After rating or flagging, go to the next photo")
            Spacer()
            TextField("Find: beach, a menu…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .help("Find photos by what’s in them, the text in them or their name")
            Text("^[\(photos.count) photo](inflect: true)").font(.callout).foregroundStyle(.secondary)
            if view == .grid {
                Slider(value: $gridSize, in: 110...320).frame(width: 90).controlSize(.mini).help("Size")
            }
            Button("Import…", systemImage: "square.and.arrow.down") { importPhotos() }
                .buttonStyle(BrandButtonStyle(large: false))
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var flagTitle: String {
        switch flagFilter {
        case .pick: String(localized: "Picks")
        case .reject: String(localized: "Rejected")
        case .some(.none): String(localized: "Not Flagged")
        case nil: String(localized: "All")
        }
    }

    // MARK: - Photos

    private var empty: some View {
        VStack(spacing: Design.Spacing.section) {
            DropZone(symbol: "photo.on.rectangle.angled", text: Text("Drop photos or a folder of photos"), targeted: dropTargeted)
            Button("Import Photos…", systemImage: "square.and.arrow.down") { importPhotos() }
                .buttonStyle(BrandButtonStyle())
        }
        .padding(Design.Spacing.window)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: gridSize, maximum: gridSize * 1.4), spacing: 10)], spacing: 10) {
                    ForEach(photos, id: \.self) { path in
                        PhotoCell(path: path, record: catalog.record(path), selected: selection.contains(path) || (selection.isEmpty && focus == path))
                            .id(path)
                            .onTapGesture(count: 2) { focus = path; selection = [path]; view = .edit }
                            .onTapGesture { click(path) }
                            .contextMenu { menu(for: path) }
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
                    }
                }
                .padding(14)
            }
            .onChange(of: focus) { _, path in if let path { withAnimation { scroller.scrollTo(path, anchor: .center) } } }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(photos, id: \.self) { path in
                        PhotoCell(path: path, record: catalog.record(path), selected: focus == path, compact: true)
                            .frame(width: 96, height: 72)
                            .id(path)
                            .onTapGesture { focus = path; selection = [path] }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 88)
            .background(.background.secondary)
            .onChange(of: focus) { _, path in if let path { withAnimation { scroller.scrollTo(path, anchor: .center) } } }
        }
    }

    private func click(_ path: String) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
        } else if flags.contains(.shift), let focus, let from = photos.firstIndex(of: focus), let to = photos.firstIndex(of: path) {
            selection = Set(photos[min(from, to)...max(from, to)])
        } else {
            selection = [path]
        }
        focus = path
        focused = true
    }

    @ViewBuilder private func menu(for path: String) -> some View {
        let targets = selection.contains(path) ? Array(selection) : [path]
        Menu("Add to Album") {
            ForEach(catalog.albums) { album in Button(album.name) { catalog.add(targets, to: album.id) } }
            Divider()
            Button("New Album…") {
                let album = catalog.newAlbum(named: String(localized: "Album \(catalog.albums.count + 1)"), with: targets)
                source = .album(album.id)
            }
        }
        if case .album(let id) = source {
            Button("Remove from Album") { catalog.remove(targets, from: id) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0) }) }
    }

    // MARK: - Importing

    /// Photos chosen (files or folders) go into a new album, or into the given one.
    private func importPhotos(into album: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return }
        importPhotos(panel.urls, into: album)
    }

    private func importPhotos(_ urls: [URL], into album: UUID? = nil) {
        let found = PhotoCatalog.photos(in: urls)
        guard !found.isEmpty else { NSSound.beep(); return }
        if let album {
            catalog.add(found, to: album)
        } else if case .album(let current) = source {
            catalog.add(found, to: current)
        } else {
            let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : String(localized: "Imported \(Date.now.formatted(date: .abbreviated, time: .omitted))")
            let created = catalog.newAlbum(named: name, with: found)
            source = .album(created.id)
        }
        focus = found.first
        selection = []
    }

    // MARK: - Keys (culling)

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let targets = selection.isEmpty ? (focus.map { [$0] } ?? []) : Array(selection)
        switch press.key {
        case .leftArrow where !editing.cropping: move(-1)
        case .rightArrow where !editing.cropping: move(1)
        case .upArrow where !loupe: move(-columns)
        case .downArrow where !loupe: move(columns)
        case .space, .return: if editing.cropping { editing.cropping = false } else if focus != nil { view = view == .grid ? .edit : .grid }
        case .escape:
            if editing.cropping { editing.cropping = false } else if editing.zoomed { editing.zoomed = false } else { view = .grid }
        default:
            let character = press.characters.lowercased()
            if let stars = Int(character), (0...5).contains(stars), press.modifiers.isEmpty {
                catalog.update(targets) { $0.rating = stars }
                advance(targets)
                return .handled
            }
            // 6–9: colour labels, as in Lightroom (again takes it off).
            if let number = Int(character), (6...9).contains(number), press.modifiers.isEmpty {
                let label = ["red", "yellow", "green", "blue"][number - 6]
                let all = targets.allSatisfy { catalog.record($0).label == label }
                catalog.update(targets) { $0.label = all ? nil : label }
                return .handled
            }
            if character == "z", press.modifiers == .command { catalog.undo(); return .handled }
            if character == "z", press.modifiers == [.command, .shift] { catalog.redo(); return .handled }
            if character == "a", press.modifiers.contains(.command) {
                selection = Set(photos)
                return .handled
            }
            let zoomable = view == .edit || view == .compare
            if zoomable, press.modifiers.contains(.command), ["=", "+"].contains(character) { editing.zoomIn(); return .handled }
            if zoomable, press.modifiers.contains(.command), character == "-" { editing.zoomOut(); return .handled }
            if zoomable, press.modifiers.contains(.command), character == "0" { editing.zoom = nil; return .handled }
            switch Shortcuts.shared.action(for: press, in: .photo) {
            case .photoGrid: view = .grid
            case .photoCull: if focus == nil { focus = photos.first }; view = .cull
            case .photoEdit: if focus == nil { focus = photos.first }; view = .edit
            case .photoCompare: if focus == nil { focus = photos.first }; view = view == .compare ? .edit : .compare
            case .photoClipping: editing.showClipping.toggle()
            case .photoCrop: editing.cropping.toggle()
            case .photoZoom: if zoomable { editing.zoom = editing.zoom == nil ? 1 : nil } else { return .ignored }
            case .photoTurnCrop:
                guard let focus else { return .ignored }
                catalog.update([focus]) { record in
                    let upright = record.adjust.cropPortrait ?? PhotoRender.isPortrait(focus)
                    record.adjust.cropPortrait = !upright
                    record.adjust.cropRect = nil
                }
            case .photoPick:
                catalog.update(targets) { $0.flag = .pick }
                advance(targets)
            case .photoReject:
                catalog.update(targets) { $0.flag = .reject }
                advance(targets)
            case .photoUnflag: catalog.update(targets) { $0.flag = .none }
            default: return .ignored
            }
        }
        return .handled
    }

    private var columns: Int { 4 }

    /// The photo Compare puts next to the selected one: the other of two selected, else the next.
    private func compared(with focus: String) -> String? {
        if selection.count == 2, let other = selection.first(where: { $0 != focus }) { return other }
        guard let index = photos.firstIndex(of: focus) else { return nil }
        return photos.indices.contains(index + 1) ? photos[index + 1] : index > 0 ? photos[index - 1] : nil
    }

    /// The photos either side, to have ready.
    private func neighbours(of path: String) -> [String] {
        guard let index = photos.firstIndex(of: path) else { return [] }
        return [index + 1, index - 1, index + 2].compactMap { photos.indices.contains($0) ? photos[$0] : nil }
    }

    private func move(_ step: Int) {
        guard !photos.isEmpty else { return }
        let index = focus.flatMap { photos.firstIndex(of: $0) } ?? -1
        let next = photos[min(max(index + step, 0), photos.count - 1)]
        focus = next
        selection = [next]
    }

    private func advance(_ targets: [String]) {
        if autoAdvance, targets.count == 1 { move(1) }
    }
}

// MARK: - A photo in the grid

private struct PhotoCell: View {
    let path: String
    let record: PhotoRecord
    let selected: Bool
    var compact = false
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Color.black.opacity(0.35)
            .aspectRatio(compact ? 4 / 3 : 1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !compact, record.rating > 0 {
                    Text(String(repeating: "★", count: record.rating))
                        .font(.caption2).foregroundStyle(.yellow)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if record.isEdited { Image(systemName: record.filmOn ? "film" : "slider.horizontal.3").font(.caption2) }
                    if record.flag == .pick { Image(systemName: "flag.fill").foregroundStyle(.white) }
                    if record.flag == .reject { Image(systemName: "xmark").foregroundStyle(.red) }
                    if let label = record.label { Circle().fill(PhotoInspector.labelColor(label)).frame(width: 8, height: 8) }
                }
                .font(.caption)
                .padding(5)
                .background(record.flag == .none && !record.isEdited && record.label == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.black.opacity(0.55)),
                            in: .capsule)
                .padding(6)
            }
            .opacity(record.flag == .reject ? 0.45 : 1)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 4 : 8, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.3 : 0.08)),
                                  lineWidth: selected ? 3 : 1)
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .help(URL(fileURLWithPath: path).lastPathComponent)
            .task(id: record) { await load() }
    }

    /// The developed preview when there is one; otherwise the photo as shot.
    private func load() async {
        let cached = PhotoRender.cachedPreview(path, record: record)
        if record.isEdited, let saved = NSImage(contentsOf: cached) { image = saved; return }
        // While a slider moves (often for many selected photos at once), wait for it to rest:
        // the large picture follows the slider, the small ones catch up after.
        if image != nil {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
        }
        let path = self.path
        let thumbnail = image != nil ? nil : await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let thumbnail { image = NSImage(cgImage: thumbnail, size: .zero) }
        // Edited without a saved preview yet (only the adjustments: film previews are made on view).
        if record.isEdited, !record.filmOn, let developed = try? await PhotoRender.develop(path, record: record, maxSize: 480) {
            guard !Task.isCancelled else { return }
            image = NSImage(cgImage: developed, size: .zero)
            PhotoRender.savePreview(developed, to: cached)
        }
    }
}

// MARK: - One photo, large

/// The developed photo, drawn from the GPU as a setting changes (only the adjustments are redone:
/// the decode and the local-tone layers are kept). Zoomed in past the preview, the photo at full
/// size, of which only the part on screen is worked out. With film on, the film render follows
/// when the slider rests. Hold \ to see it as shot.
struct PhotoLoupe: View {
    let path: String
    let record: PhotoRecord
    /// The photos either side (and their settings), decoded ahead.
    var neighbours: [(String, PhotoRecord)] = []
    /// In Compare: zoomed and moved together with the other photo.
    var linked = false
    /// The one whose histogram shows (Compare shows two).
    var primary = true
    /// The developed preview (or the film's picture).
    @State private var picture: CIImage?
    /// The photo at full size, for the settings in `fullKey`.
    @State private var full: CIImage?
    @State private var fullKey: FullKey?
    @State private var fullLong = 0.0
    @State private var developing = false
    @State private var problem: String?
    @State private var editing = PhotoEditing.shared
    @State private var catalog = PhotoCatalog.shared
    @State private var ownCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var ownDrag: CGSize = .zero
    @State private var pinchStart: Double?
    @State private var viewSize: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color.black
            if let picture {
                GeometryReader { geo in
                    let frame = pictureFrame(in: geo.size)
                    ZStack {
                        PhotoCanvas(image: editing.showClipping ? PhotoEngine.clipping(shownImage ?? picture) : shownImage ?? picture, frame: frame)
                        if let zoom = editing.zoom, !editing.cropping {
                            zoomGestures(zoom: zoom, area: geo.size, frame: frame)
                        } else {
                            fitGestures(frame: frame)
                        }
                    }
                    if editing.cropping, !original {
                        let size = picture.extent.size
                        let ratio = size.width / max(size.height, 1)
                        CropOverlay(frame: frame, pictureRatio: ratio,
                                    rect: record.adjust.cropRect ?? CropOverlay.centered(ratio: record.adjust.cropRatio(pictureRatio: ratio), pictureRatio: ratio),
                                    ratio: record.adjust.cropRatio(pictureRatio: ratio), angle: record.adjust.straighten,
                                    change: { rect in catalog.update([path]) { $0.adjust.cropRect = rect; $0.edited = .now } },
                                    rotate: { angle in catalog.update([path]) { $0.adjust.straighten = angle; $0.edited = .now } })
                    }
                }
            }
            VStack {
                HStack {
                    if original { Text("As Shot").font(.caption.weight(.semibold)).padding(6).background(.black.opacity(0.6), in: .capsule) }
                    Spacer()
                    if developing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(record.filmOn ? "Developing the film…" : "Developing…")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                    }
                }
                Spacer()
                if let problem { ProblemLabel(text: problem).padding(8).background(.ultraThinMaterial, in: .rect(cornerRadius: 8)) }
            }
            .padding(14)
        }
        .background(GeometryReader { geo in Color.clear.onAppear { viewSize = geo.size }.onChange(of: geo.size) { _, size in viewSize = size } })
        .task(id: TaskKey(path: path, record: shownRecord, original: original)) { await develop() }
        .task(id: wantedFull) {
            // The photo at full size once zoomed in past the preview (decoded once, then only the
            // adjustments are redone).
            guard let key = wantedFull else { return }
            if full == nil || fullKey?.path != key.path { developing = true }
            let path = key.path, record = key.record
            let made = await Task.detached(priority: .userInitiated) { PhotoRender.image(path, record: record, maxSize: 0) }.value
            guard !Task.isCancelled else { return }
            full = made
            fullKey = key
            developing = false
        }
        .task(id: path) {
            let path = self.path
            fullLong = Double(await Task.detached { PhotoRender.fullLongEdge(path) }.value)
            // The photos either side, decoded ahead, once this one is showing.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let size = PhotoRender.previewSize, ahead = neighbours
            await Task.detached(priority: .utility) {
                for (next, record) in ahead { _ = PhotoRender.base(next, maxSize: size, record: record) }
            }.value
        }
        .onChange(of: path) { _, _ in if !linked { editing.zoom = nil }; full = nil; fullKey = nil }
        .onChange(of: editing.zoom) { _, zoom in if zoom == nil { center = CGPoint(x: 0.5, y: 0.5) } }
    }

    /// Where the zoomed photo looks (shared with the other photo in Compare).
    private var center: CGPoint {
        get { linked ? editing.compareCenter : ownCenter }
        nonmutating set { if linked { editing.compareCenter = newValue } else { ownCenter = newValue } }
    }

    private var drag: CGSize {
        get { linked ? editing.compareDrag : ownDrag }
        nonmutating set { if linked { editing.compareDrag = newValue } else { ownDrag = newValue } }
    }

    private struct TaskKey: Hashable {
        let path: String
        let record: PhotoRecord
        let original: Bool
    }

    private struct FullKey: Hashable {
        let path: String
        let record: PhotoRecord
    }

    private var original: Bool { editing.asShot }

    /// While cropping, the whole picture shows (the frame marks the crop).
    private var shownRecord: PhotoRecord {
        var shown = record
        if editing.cropping {
            shown.adjust.cropRect = nil
            shown.adjust.crop = .original
            shown.filmOn = false
        }
        return shown
    }

    /// The settings to show the full size for: zoomed in past the preview's own pixels.
    private var wantedFull: FullKey? {
        guard let zoom = editing.zoom, !editing.cropping, zoom * scaleToFull > 1.05 else { return nil }
        var shown = original ? PhotoRecord() : shownRecord
        shown.filmOn = false
        return FullKey(path: path, record: shown)
    }

    /// The full size when it's made for what's showing now.
    private var shownImage: CIImage? {
        guard let wanted = wantedFull, fullKey == wanted else { return nil }
        return full
    }

    /// Photo pixels per pixel of the preview.
    private var scaleToFull: Double {
        guard let picture else { return 1 }
        let shownLong = Double(max(picture.extent.width, picture.extent.height))
        return fullLong > 0 && shownLong > 0 ? max(fullLong / shownLong, 1) : 1
    }

    /// The zoom at which the photo just fits.
    private func fitZoom() -> Double {
        guard let picture else { return 1 }
        let fitted = Self.fitted(picture.extent.size, in: viewSize, inset: 14)
        return Double(fitted.width) * displayScale / max(Double(picture.extent.width) * scaleToFull, 1)
    }

    /// Where the whole photo goes in the view (points, from the top left).
    private func pictureFrame(in area: CGSize) -> CGRect {
        guard let picture else { return .zero }
        let size = picture.extent.size
        guard let zoom = editing.zoom, !editing.cropping else { return Self.fitted(size, in: area, inset: 14) }
        let width = Double(size.width) * scaleToFull * zoom / displayScale, height = Double(size.height) * scaleToFull * zoom / displayScale
        let c = clamped(center, width: width, height: height, view: area)
        let x = area.width / 2 + (0.5 - c.x) * width + drag.width, y = area.height / 2 + (0.5 - c.y) * height + drag.height
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// Fitted: click to look at that place at 100%, pinch to zoom in.
    private func fitGestures(frame: CGRect) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { location in
                guard !editing.cropping, frame.width > 0 else { return }
                center = CGPoint(x: min(max((location.x - frame.minX) / frame.width, 0), 1),
                                 y: min(max((location.y - frame.minY) / frame.height, 0), 1))
                editing.zoom = 1
            }
            .gesture(MagnifyGesture().onChanged { value in
                guard !editing.cropping, value.magnification > 1.05 else { return }
                editing.zoom = max(fitZoom(), 0.1) * value.magnification
            })
    }

    /// Zoomed: drag to look around, pinch (or ⌘ and scroll) to zoom, double-click to fit.
    private func zoomGestures(zoom: Double, area: CGSize, frame: CGRect) -> some View {
        Color.clear
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in drag = value.translation }
                .onEnded { value in
                    let c = clamped(center, width: frame.width, height: frame.height, view: area)
                    center = clamped(CGPoint(x: c.x - value.translation.width / frame.width, y: c.y - value.translation.height / frame.height),
                                     width: frame.width, height: frame.height, view: area)
                    drag = .zero
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = zoom }
                    editing.zoom = min(max((pinchStart ?? zoom) * value.magnification, fitZoom() * 0.9), 8)
                }
                .onEnded { _ in
                    pinchStart = nil
                    if let z = editing.zoom, z <= fitZoom() { editing.zoom = nil }
                })
            .onTapGesture(count: 2) { editing.zoom = nil }
            .overlay(alignment: .bottomTrailing) { zoomBar.padding(14) }
    }

    /// Keeps the photo's edges at the view's edges (or the photo centred when it's smaller).
    private func clamped(_ point: CGPoint, width: Double, height: Double, view: CGSize) -> CGPoint {
        func axis(_ v: Double, _ size: Double, _ room: Double) -> Double {
            guard size > room else { return 0.5 }
            let half = room / 2 / size
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(point.x, width, view.width), y: axis(point.y, height, view.height))
    }

    private var zoomBar: some View {
        HStack(spacing: 2) {
            Button("Fit") { editing.zoom = nil }
            ForEach(PhotoEditing.zoomSteps, id: \.self) { step in
                Button(String(format: "%.0f%%", step * 100)) { editing.zoom = step }
                    .fontWeight(abs((editing.zoom ?? 0) - step) < 0.001 ? .bold : .regular)
            }
            if let zoom = editing.zoom, !PhotoEditing.zoomSteps.contains(where: { abs($0 - zoom) < 0.001 }) {
                Text(String(format: "%.0f%%", zoom * 100)).monospacedDigit().foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .capsule)
    }

    /// Where a picture of this size sits when fitted in the view.
    static func fitted(_ size: CGSize, in area: CGSize, inset: CGFloat) -> CGRect {
        let ratio = size.width / max(size.height, 1)
        let width = min(area.width - inset * 2, (area.height - inset * 2) * ratio), height = width / ratio
        return CGRect(x: (area.width - width) / 2, y: (area.height - height) / 2, width: width, height: height)
    }

    /// The adjustments follow at once; the histogram and the grid's copy when the slider rests;
    /// the film (a second or so) after that.
    private func develop() async {
        problem = nil
        let shown = original ? PhotoRecord() : shownRecord
        let path = self.path, size = PhotoRender.previewSize
        let cached = PhotoRender.cachedPreview(path, record: shown)
        if shown.filmOn, let known = FilmPictures.shared.picture(cached.path) {
            picture = known
            developing = false
            return
        }
        let quick = await Task.detached(priority: .userInitiated) { PhotoRender.image(path, record: shown, maxSize: size) }.value
        guard !Task.isCancelled else { return }
        if shown.filmOn, FileManager.default.fileExists(atPath: cached.path), let saved = CIImage(contentsOf: cached) {
            // The film's look from last time while it's developed again at this size.
            picture = saved
        } else if let quick {
            picture = quick
        } else {
            problem = String(localized: "The photo couldn’t be read.")
            return
        }
        if !shown.filmOn {
            developing = false
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let quick else { return }
            if primary { editing.histogram = await Task.detached(priority: .utility) { PhotoEngine.histogram(quick) }.value }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, shown.isEdited else { return }
            await Task.detached(priority: .utility) {
                if let small = PhotoRender.picture(quick, maxSize: 1200) { PhotoRender.savePreview(small, to: cached) }
            }.value
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        developing = true
        do {
            if let developed = try await PhotoRender.develop(path, record: shown, maxSize: size) {
                guard !Task.isCancelled else { return }
                let film = CIImage(cgImage: developed)
                picture = film
                FilmPictures.shared.keep(film, for: cached.path)
                if primary { editing.histogram = await Task.detached(priority: .utility) { PhotoEngine.histogram(film) }.value }
                PhotoRender.savePreview(developed, to: cached)
            }
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
        }
        if !Task.isCancelled { developing = false }
    }
}

/// The last few film pictures made, to show again at once (the film takes a second or so).
@MainActor
final class FilmPictures {
    static let shared = FilmPictures()
    private var pictures: [String: CIImage] = [:]
    private var order: [String] = []

    func picture(_ key: String) -> CIImage? { pictures[key] }

    func keep(_ picture: CIImage, for key: String) {
        if pictures[key] == nil { order.append(key) }
        pictures[key] = picture
        if order.count > 8 { pictures[order.removeFirst()] = nil }
    }
}

// MARK: - Culling

/// One photo at a time, as quick as it gets: the preview the camera made (in RAW files too),
/// with the photos either side made ready. Rate, pick and reject with the keys.
struct PhotoCullView: View {
    let path: String
    let record: PhotoRecord
    let neighbours: [String]
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(14) }
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= record.rating ? "star.fill" : "star")
                                .foregroundStyle(star <= record.rating ? Color.yellow : .white.opacity(0.4))
                        }
                    }
                    if record.flag != .none {
                        Image(systemName: record.flag == .pick ? "flag.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.flag == .pick ? .white : .red)
                    }
                    Text(URL(fileURLWithPath: path).lastPathComponent).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(.bottom, 18)
            }
        }
        .task(id: path) {
            if let ready = CullCache.shared.image(path) { image = ready } else {
                image = await CullCache.shared.load(path)
            }
            for next in neighbours { _ = await CullCache.shared.load(next) }
        }
    }
}

/// The cameras' own previews, kept for the last few photos.
@MainActor
final class CullCache {
    static let shared = CullCache()
    private var images: [String: NSImage] = [:]
    private var order: [String] = []

    func image(_ path: String) -> NSImage? { images[path] }

    func load(_ path: String) async -> NSImage? {
        if let known = images[path] { return known }
        let size = PhotoRender.previewSize
        let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: size,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: .zero)
        images[path] = image
        order.append(path)
        if order.count > 12 { images[order.removeFirst()] = nil }
        return image
    }
}
