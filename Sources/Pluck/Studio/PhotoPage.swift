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
    @State private var labelFilter: String?
    /// The checks' filter: only what looks fine, or only possible rejects.
    @State private var checkFilter: Bool?
    /// Moments: similar photos stacked, the strongest on top. Starts on for anyone who had "One per Burst" on.
    @AppStorage("photoMoments") private var momentsOn = false
    @State private var styles = PhotoStyles.shared
    /// The moments opened in place: a photo of each (its first when opened), so it stays open when regrouped.
    @State private var openMoments: Set<String> = []
    @State private var momentsCache = MomentsCache()
    @State private var checks = PhotoChecks.shared
    @State private var importing = false
    @State private var importAlbum: UUID?
    @AppStorage("photoSidebarHidden") private var sidebarHidden = false
    @AppStorage("photoInspectorHidden") private var inspectorHidden = false
    @State private var renamingAlbum: UUID?
    @State private var albumName = ""
    @State private var dropTargeted = false
    @State private var renamingFolder: UUID?
    @State private var folderName = ""
    @State private var closedFolders: Set<UUID> = []

    /// The album or list open on the left (remembered, so a drop goes into the album you see).
    private var source: PhotoCatalog.Source {
        get {
            // An album or folder that's gone since: all photos instead of nothing.
            switch PhotoCatalog.Source(key: sourceKey) {
            case .album(let id) where !catalog.albums.contains(where: { $0.id == id }): .all
            case .folder(let id) where !FootageFolders.shared.folders.contains(where: { $0.id == id }): .all
            case let kept: kept
            }
        }
        nonmutating set { sourceKey = newValue.key }
    }
    @FocusState private var focused: Bool
    @State private var editing = PhotoEditing.shared

    @State private var search = ""
    @State private var photoIndex = PhotoIndex.shared

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "photoMoments") == nil, defaults.bool(forKey: "photoStackBursts") { defaults.set(true, forKey: "photoMoments") }
    }

    /// What the filters and the search leave, before moments.
    private var filtered: [String] {
        var list = catalog.photos(in: source).filter { path in
            let record = catalog.record(path)
            let fine = checks.check(path).map { !$0.possibleReject }
            return record.rating >= minRating && (flagFilter == nil || record.flag == flagFilter) && (labelFilter == nil || record.label == labelFilter)
                && (checkFilter == nil || fine == checkFilter)
        }
        // What's in the picture (or its text, or its name).
        let words = search.split(separator: " ").map(String.init)
        if !words.isEmpty {
            let found = photoIndex.search(words, within: Set(list)).map(\.path)
            let byName = list.filter { path in words.allSatisfy { PhotoCatalog.displayName(path).localizedCaseInsensitiveContains($0) } }
            var seen: Set<String> = []
            list = (found + byName).filter { seen.insert($0).inserted }
        }
        return list
    }

    /// What the page lists: the filtered photos, or with Moments on, their stacks.
    private var listing: PhotoMoments.Listing {
        guard momentsOn else { return PhotoMoments.Listing(paths: filtered) }
        return momentsCache.listing(filtered, checks: checks.checks, style: styles.chosenStyle, expanded: openMoments)
    }

    private var photos: [String] { listing.paths }

    /// Opens or closes the moment this photo is in (nothing for a photo on its own).
    private func toggleMoment(of path: String) {
        let before = listing
        guard momentsOn, let key = before.moment[path] else { return }
        let members = before.members[key] ?? [key]
        if members.contains(where: openMoments.contains) { openMoments.subtract(members) } else { openMoments.insert(key) }
        keepToShown()
    }

    /// Photos that went back into a stack leave the selection, so a key or an edit never reaches a photo
    /// that can't be seen; a focus that went in moves to its moment's top photo.
    private func keepToShown() {
        guard momentsOn else { return }
        let now = listing
        let shown = Set(now.paths)
        selection.formIntersection(shown)
        if let focus, !shown.contains(focus) {
            let key = now.moment[focus]
            let top = key.flatMap { key in now.paths.first { now.moment[$0] == key } } ?? now.paths.first
            self.focus = top
            if let top, !selection.isEmpty { selection.insert(top) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebar.frame(width: 220)
                Divider()
            }
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
            if !inspectorHidden {
                ResizeHandle(width: $inspectorWidth, range: 280...520, edge: .trailing)
                PhotoInspector(tab: $tab, paths: Array(selection.isEmpty ? (focus.map { [$0] } ?? []) : selection).sorted(), focus: focus)
                    .frame(width: inspectorWidth)
                    .clipped()
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .navigationTitle("Photo")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .onChange(of: focus) { old, new in PhotoPasteboard.focusMoved(from: old, to: new) }
        .onChange(of: selection) { old, new in if old != new { editing.syncAll = true } }
        .onChange(of: momentsOn) { keepToShown() }
        .onChange(of: selection, initial: true) { editing.levelCount = pasteTargets.count }
        .onChange(of: focus) { editing.levelCount = pasteTargets.count }
        .sheet(item: $copySheet) { mode in
            PasteChooser(count: pasteTargets.count, copying: mode == .copy) { _ in
                if mode == .copy { if let focus { PhotoPasteboard.copy(focus) } } else { PhotoPasteboard.paste(PasteGroup.chosen, to: pasteTargets) }
            }
        }
        .onKeyPress("\\", phases: [.down, .up]) { press in
            editing.asShot = press.phase == .down
            return .handled
        }
        .onAppear {
            PhotoPasteboard.perform = { perform($0) }
            SpeedEditor.shared.context = {
                guard view == .edit, let focus else { return nil }
                return ((selection.isEmpty ? [focus] : Array(selection)).sorted(), focus)
            }
            SpeedEditor.shared.start()
            focused = true
            // Back in Edit (or one at a time) from last time: with the first photo.
            if view != .grid, focus == nil { focus = photos.first }
            FootageFolders.shared.start()
            PhotoIndex.shared.enqueue(catalog.allPhotos)
            catalog.readSidecars(catalog.allPhotos)
            checks.enqueue(catalog.allPhotos)
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
            // -PluckScreenshotMask YES: the first photo large, its first mask being shaped.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotMask") {
                focus = photos.first
                view = .edit
                if let first = focus.flatMap({ catalog.record($0).adjust.masks.first }) {
                    editing.selectedMask = first.id
                    editing.selectedPart = first.shape.first?.id
                }
            }
            // -PluckScreenshotImport <folder>: the import sheet, from that folder.
            if ScreenshotMode.scene == "photo", Self.importTest.isEmpty == false { importing = true }
            // -PluckScreenshotFind <text>: the Adjust panel's search filled in. -PluckScreenshotKeys YES: the keys.
            if ScreenshotMode.scene == "photo", let text = UserDefaults.standard.string(forKey: "PluckScreenshotFind") { editing.toolQuery = text }
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotKeys") { editing.showingKeys = true }
            // -PluckScreenshotCrop YES: the first photo being cropped.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotCrop") {
                focus = photos.first
                view = .edit
                editing.cropping = true
            }
            // -PluckScreenshotZoom YES: the first photo at 1:1.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotZoom") {
                focus = photos.first
                view = .edit
                editing.zoomed = true
            }
            // Scene photosync: the first three photos selected in Edit, the "Editing 3" chip showing.
            if ScreenshotMode.scene == "photosync" {
                focus = photos.first
                selection = Set(photos.prefix(3))
                view = .edit
                if UserDefaults.standard.string(forKey: "PluckScreenshotPhotoTab") == nil { tab = .adjust }
            }
            // Scene photobeforeafter: the first photo large, edited, with the split line over it
            // (-PluckScreenshotBeforeAfter side: side by side).
            if ScreenshotMode.scene == "photobeforeafter" {
                focus = photos.first
                view = .edit
                if let first = photos.first {
                    catalog.update([first]) { $0.adjust.exposure = 1.2; $0.adjust.contrast = 25; $0.adjust.saturation = 30 }
                }
                editing.beforeAfter = UserDefaults.standard.string(forKey: "PluckScreenshotBeforeAfter") == "side" ? .sideBySide : .split
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
        .onDisappear { editing.cropping = false; PhotoPasteboard.perform = nil; SpeedEditor.shared.stop() }
        .sheet(isPresented: $editing.showingKeys) { PhotoKeysSheet() }
        .sheet(isPresented: $importing) {
            PhotoImportSheet(initial: Self.importTest) { paths, name in imported(paths, named: name) }
        }
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

    /// Browse (the grid, or one at a time to cull) or Edit (one photo, or two to compare).
    private var editingMode: Bool { (view == .edit || view == .compare) && focus != nil }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: Binding(get: { editingMode }, set: { edit in
                if edit { if focus == nil { focus = photos.first }; view = .edit } else { view = .grid }
            })) {
                Text("Browse").tag(false)
                Text("Edit").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Browse (\(Shortcuts.shared.shortcut(.photoGrid).label)) or edit (\(Shortcuts.shared.shortcut(.photoEdit).label))")
            if editingMode {
                Toggle(isOn: Binding(get: { view == .compare }, set: { view = $0 ? .compare : .edit })) {
                    Image(systemName: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("Compare with the next photo, zoomed together (\(Shortcuts.shared.shortcut(.photoCompare).label))")
                .accessibilityLabel(Text("Compare"))
                Toggle(isOn: $editing.cropping) { Image(systemName: "crop") }
                    .toggleStyle(.button)
                    .help("Crop and straighten (\(Shortcuts.shared.shortcut(.photoCrop).label))")
                    .accessibilityLabel(Text("Crop"))
                Image(systemName: editing.asShot ? "circle.lefthalf.filled.inverse" : "circle.lefthalf.filled")
                    .frame(width: 26, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(editing.asShot ? 0.2 : 0.08)))
                    .contentShape(.rect)
                    .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { editing.asShot = $0 })
                    .help("Hold to see it as shot (or hold \\)")
                    .accessibilityLabel(Text("Hold to see it as shot"))
                    .accessibilityAddTraits(.isButton)
                beforeAfterMenu
                hdrToggle
            } else {
                Toggle(isOn: Binding(get: { view == .cull }, set: { one in
                    if one, focus == nil { focus = photos.first }
                    view = one ? .cull : .grid
                })) {
                    Image(systemName: "rectangle")
                }
                .toggleStyle(.button)
                .help("One at a time, to cull quickly (\(Shortcuts.shared.shortcut(.photoCull).label))")
                .accessibilityLabel(Text("One at a time"))
            }
            filterMenu
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find", text: $search).textFieldStyle(.plain).frame(maxWidth: 150)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .help("Find photos by what’s in them, the text in them or their name")
            Text("^[\(photos.count) photo](inflect: true)").font(.callout).foregroundStyle(.secondary)
            moreMenu
            Button("Import…", systemImage: "square.and.arrow.down") { importPhotos() }
                .buttonStyle(BrandButtonStyle(large: false))
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var filtering: Bool { flagFilter != nil || minRating > 0 || labelFilter != nil || checkFilter != nil }

    /// One menu for every filter: flag, rating, colour label.
    private var filterMenu: some View {
        Menu {
            Picker("Flag", selection: $flagFilter) {
                Text("All").tag(PhotoRecord.Flag?.none)
                Text("Picks").tag(PhotoRecord.Flag?.some(.pick))
                Text("Not Flagged").tag(PhotoRecord.Flag?.some(.none))
                Text("Rejected").tag(PhotoRecord.Flag?.some(.reject))
            }
            .pickerStyle(.inline)
            Picker("Rating", selection: $minRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { stars in Text(String(repeating: "★", count: stars) + "+").tag(stars) }
            }
            .pickerStyle(.inline)
            Picker("Label", selection: $labelFilter) {
                Text("Any Label").tag(String?.none)
                ForEach(PhotoInspector.labels, id: \.self) { name in Text(PhotoInspector.labelTitle(name)).tag(String?.some(name)) }
            }
            .pickerStyle(.inline)
            Picker("Quick Look", selection: $checkFilter) {
                Text("Any Photo").tag(Bool?.none)
                Text("Looks Fine").tag(Bool?.some(true))
                Text("Possible Rejects").tag(Bool?.some(false))
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Moments", isOn: $momentsOn)
            if momentsOn, styles.styles.contains(where: { $0.trained != nil }) {
                Picker("Ranking", selection: $styles.chosen) {
                    Text("Built-in").tag(UUID?.none)
                    ForEach(styles.styles.filter { $0.trained != nil }) { style in Text(style.name).tag(UUID?.some(style.id)) }
                }
            }
            if filtering {
                Divider()
                Button("Show All") { flagFilter = nil; minRating = 0; labelFilter = nil; checkFilter = nil }
            }
        } label: {
            Label(filterTitle, systemImage: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .help("Show only some photos")
    }

    private var filterTitle: String {
        var parts: [String] = []
        if let flagFilter { parts.append(flagFilter == .pick ? String(localized: "Picks") : flagFilter == .reject ? String(localized: "Rejected") : String(localized: "Not Flagged")) }
        if minRating > 0 { parts.append(String(repeating: "★", count: minRating) + "+") }
        if let labelFilter { parts.append(PhotoInspector.labelTitle(labelFilter)) }
        if let checkFilter { parts.append(checkFilter ? String(localized: "Looks Fine") : String(localized: "Possible Rejects")) }
        return parts.isEmpty ? String(localized: "Filter") : parts.joined(separator: " · ")
    }

    /// The rest, out of the way: culling and panels.
    private var moreMenu: some View {
        Menu {
            Toggle("Auto-Advance After Rating", isOn: $autoAdvance)
            Toggle("Show Clipping (\(Shortcuts.shared.shortcut(.photoClipping).label))", isOn: $editing.showClipping)
            Divider()
            Toggle("Show Albums (⇧Tab)", isOn: Binding(get: { !sidebarHidden }, set: { sidebarHidden = !$0 }))
            Toggle("Show Inspector (Tab)", isOn: Binding(get: { !inspectorHidden }, set: { inspectorHidden = !$0 }))
            Divider()
            Button("Keyboard Shortcuts (?)") { editing.showingKeys = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More"))
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
        let listing = listing
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: gridSize, maximum: gridSize * 1.4), spacing: 10)], spacing: 10) {
                    ForEach(photos, id: \.self) { path in
                        PhotoCell(path: path, record: catalog.record(path), selected: selection.contains(path) || (selection.isEmpty && focus == path),
                                  check: checks.check(path), stack: listing.stacked[path] ?? 0, opened: listing.opened[path] != nil,
                                  toggleStack: { toggleMoment(of: path) })
                            .id(path)
                            .onTapGesture(count: 2) { focus = path; selection = [path]; view = .edit }
                            .onTapGesture { click(path) }
                            .contextMenu { menu(for: path) }
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: PhotoCatalog.file(of: path)) as NSURL) }
                    }
                }
                .padding(14)
            }
            .onChange(of: focus) { _, path in
                guard let path else { return }
                if reduceMotion { scroller.scrollTo(path, anchor: .center) } else { withAnimation { scroller.scrollTo(path, anchor: .center) } }
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchSize == nil { pinchSize = gridSize }
                    gridSize = min(max((pinchSize ?? gridSize) * value.magnification, 90), 420)
                }
                .onEnded { _ in pinchSize = nil })
        }
    }

    @State private var pinchSize: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filmstrip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(photos, id: \.self) { path in
                        PhotoCell(path: path, record: catalog.record(path), selected: selection.contains(path) || focus == path, compact: true)
                            .frame(width: 96, height: 72)
                            .id(path)
                            .onTapGesture { click(path) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 88)
            .background(.background.secondary)
            .onChange(of: focus) { _, path in
                guard let path else { return }
                if reduceMotion { scroller.scrollTo(path, anchor: .center) } else { withAnimation { scroller.scrollTo(path, anchor: .center) } }
            }
        }
    }

    private func click(_ path: String) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if selection.contains(path) {
                selection.remove(path)
                // The photo shown leaves the selection: another one in it takes over.
                if path == focus, let other = photos.first(where: selection.contains) { focus = other; return }
            } else {
                selection.insert(path)
            }
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
        Button("Make Virtual Copy") { makeCopy(of: path) }
        if PhotoCatalog.isCopy(path) {
            Button("Remove Virtual Copy") { removeCopies(targets.filter(PhotoCatalog.isCopy)) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: PhotoCatalog.file(of: $0)) }) }
    }

    /// A copy of the photo with its edit, shown next (to try another look on the same file).
    private func makeCopy(of path: String) {
        let copy = catalog.makeCopy(of: path)
        selection = [copy]
        focus = copy
    }

    /// After undo: a copy that's gone isn't shown or chosen any more (an edit would bring it back).
    private func dropGoneCopies() {
        if let focus, PhotoCatalog.isCopy(focus), catalog.records[focus] == nil { self.focus = PhotoCatalog.file(of: focus) }
        selection = selection.filter { !PhotoCatalog.isCopy($0) || catalog.records[$0] != nil }
    }

    private func removeCopies(_ keys: [String]) {
        catalog.removeCopies(keys)
        if let focus, keys.contains(focus) { self.focus = PhotoCatalog.file(of: focus) }
        selection.subtract(keys)
    }

    // MARK: - Importing

    /// Photos chosen (files or folders) go into a new album, or into the given one.
    /// Tests: the folder the import sheet starts from.
    static var importTest: [URL] {
        guard ScreenshotMode.scene == "photo", let folder = UserDefaults.standard.string(forKey: "PluckScreenshotImport") else { return [] }
        return [URL(fileURLWithPath: folder)]
    }

    /// The import sheet (a card or a folder; copied or used where they are).
    private func importPhotos(into album: UUID? = nil) {
        importAlbum = album
        importing = true
    }

    /// What the import sheet brought in: into the album asked for, else a new one.
    private func imported(_ paths: [String], named name: String) {
        if let album = importAlbum {
            catalog.add(paths, to: album)
        } else {
            let created = catalog.newAlbum(named: name, with: paths)
            source = .album(created.id)
        }
        importAlbum = nil
        checks.enqueue(paths)
        focus = paths.first
        selection = []
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

    private enum CopySheet: Identifiable { case copy, paste; var id: Int { self == .copy ? 0 : 1 } }
    @State private var copySheet: CopySheet?

    private var pasteTargets: [String] { selection.isEmpty ? (focus.map { [$0] } ?? []) : Array(selection).sorted() }

    /// Copy and paste of settings (keys and the Edit menu).
    private func perform(_ action: PhotoPasteboard.Action) {
        switch action {
        case .copy: if let focus { PhotoPasteboard.copy(focus) } else { NSSound.beep() }
        case .copyChoosing: if focus != nil { copySheet = .copy } else { NSSound.beep() }
        case .paste:
            if PhotoPasteboard.copied != nil { PhotoPasteboard.paste(PasteGroup.chosen, to: pasteTargets) } else { NSSound.beep() }
        case .pasteChoosing: if PhotoPasteboard.copied != nil { copySheet = .paste } else { NSSound.beep() }
        case .pastePrevious:
            if PhotoPasteboard.lastViewed != nil { PhotoPasteboard.pastePrevious(to: pasteTargets) } else { NSSound.beep() }
        case .level, .levelWithWhiteBalance:
            let targets = pasteTargets, reference = focus
            guard targets.count >= 2 else { NSSound.beep(); return }
            Task { await PhotoLevel.level(targets, reference: reference.flatMap { targets.contains($0) ? $0 : nil }, whiteBalance: action == .levelWithWhiteBalance) }
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let targets = selection.isEmpty ? (focus.map { [$0] } ?? []) : Array(selection)
        switch press.key {
        case .tab:
            // Tab: the inspector; Shift-Tab: both panels (as in Lightroom).
            if press.modifiers.contains(.shift) {
                let show = sidebarHidden || inspectorHidden
                sidebarHidden = !show
                inspectorHidden = !show
            } else {
                inspectorHidden.toggle()
            }
        case .leftArrow where !editing.cropping: move(-1, extending: press.modifiers.contains(.shift))
        case .rightArrow where !editing.cropping: move(1, extending: press.modifiers.contains(.shift))
        case .upArrow where !loupe: move(-columns, extending: press.modifiers.contains(.shift))
        case .downArrow where !loupe: move(columns, extending: press.modifiers.contains(.shift))
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
            if character == "?" { editing.showingKeys = true; return .handled }
            if press.key == "c" || press.key == "v" {
                let copy = press.key == "c"
                switch press.modifiers {
                case .command: perform(copy ? .copy : .paste); return .handled
                case [.command, .shift]: perform(copy ? .copyChoosing : .pasteChoosing); return .handled
                case [.command, .option] where !copy: perform(.pastePrevious); return .handled
                default: break
                }
            }
            if character == "z", press.modifiers == .command { catalog.undo(); dropGoneCopies(); return .handled }
            if character == "z", press.modifiers == [.command, .shift] { catalog.redo(); dropGoneCopies(); return .handled }
            if character == "a", press.modifiers.contains(.command) {
                selection = Set(photos)
                return .handled
            }
            let zoomable = view == .edit || view == .compare
            if view == .grid, press.modifiers.contains(.command), ["=", "+"].contains(character) { gridSize = min(gridSize * 1.25, 420); return .handled }
            if view == .grid, press.modifiers.contains(.command), character == "-" { gridSize = max(gridSize / 1.25, 90); return .handled }
            if zoomable, press.modifiers.contains(.command), ["=", "+"].contains(character) { editing.zoomIn(); return .handled }
            if zoomable, press.modifiers.contains(.command), character == "-" { editing.zoomOut(); return .handled }
            if zoomable, press.modifiers.contains(.command), character == "0" { editing.zoom = nil; return .handled }
            switch Shortcuts.shared.action(for: press, in: .photo) {
            case .photoGrid: view = .grid
            case .photoCull: if focus == nil { focus = photos.first }; view = .cull
            case .photoEdit: if focus == nil { focus = photos.first }; view = .edit
            case .photoCompare: if focus == nil { focus = photos.first }; view = view == .compare ? .edit : .compare
            case .photoClipping: editing.showClipping.toggle()
            case .photoMaskOverlay: if editing.selectedMask != nil { editing.maskOverlay.toggle() } else { return .ignored }
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
            case .photoMoment:
                guard momentsOn, let focus, listing.moment[focus] != nil else { return .ignored }
                toggleMoment(of: focus)
            case .photoVirtualCopy:
                guard let focus else { return .ignored }
                makeCopy(of: focus)
            case .photoBeforeAfter:
                guard view == .edit, focus != nil, !editing.cropping else { return .ignored }
                editing.cycleBeforeAfter()
            // Speed Edit works by holding the key and scrolling (PhotoSpeedEdit); a tap does nothing.
            case .some(let speed) where SpeedEdit.targets[speed] != nil: break
            default: return .ignored
            }
        }
        return .handled
    }

    private var columns: Int { 4 }

    /// Next to the half-circle (hold: as shot): before and after, and what "before" is.
    /// HDR: only on a screen that can show it (macOS 15 and later). Each photo remembers it.
    @ViewBuilder private var hdrToggle: some View {
        if PhotoEditing.canShowHDR(NSApp.keyWindow?.screen ?? NSScreen.main), let focus {
            let on = catalog.record(focus).hdr == true
            Toggle(isOn: Binding(get: { on }, set: { value in
                catalog.update(editing.targets(selection.isEmpty ? [focus] : Array(selection), shown: focus)) { $0.hdr = value ? true : nil }
            })) {
                Text("HDR").font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .help("Edit in HDR: highlights brighter than white, on this screen and in an HDR export")
        }
    }

    private var beforeAfterMenu: some View {
        let snapshots = focus.map { catalog.record($0).snapshots } ?? []
        let chosen = snapshots.first { $0.id == editing.beforeSnapshot }?.id
        return Menu {
            Picker("Before and After", selection: $editing.beforeAfter) {
                Text("Off").tag(BeforeAfter.off)
                Text("Split View").tag(BeforeAfter.split)
                Text("Side by Side").tag(BeforeAfter.sideBySide)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Before", selection: Binding(get: { chosen }, set: { id in
                editing.beforeSnapshot = id
                if editing.beforeAfter == .off, !editing.cropping { editing.beforeAfter = .split }
            })) {
                Text("Before: As Shot").tag(UUID?.none)
                ForEach(snapshots) { snapshot in Text("Before: \(snapshot.name)").tag(UUID?.some(snapshot.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Before and after (\(Shortcuts.shared.shortcut(.photoBeforeAfter).label)): what “before” is")
        .accessibilityLabel(Text("Before and after"))
    }

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

    /// To the photo `step` away; with ⇧ the selection grows to take it in (the photos passed too).
    private func move(_ step: Int, extending: Bool = false) {
        guard !photos.isEmpty else { return }
        let index = focus.flatMap { photos.firstIndex(of: $0) } ?? -1
        let target = min(max(index + step, 0), photos.count - 1)
        let next = photos[target]
        if extending, index >= 0 {
            selection.formUnion(photos[min(index, target)...max(index, target)])
        } else {
            selection = [next]
        }
        focus = next
    }

    private func advance(_ targets: [String]) {
        if autoAdvance, targets.count == 1 { move(1) }
    }
}

// MARK: - A photo in the grid

private struct PhotoCell: View {
    /// What VoiceOver says about a photo: its rating, flag, label and whether it's edited.
    static func describe(_ record: PhotoRecord) -> String {
        var parts: [String] = []
        if record.rating > 0 { parts.append(String(localized: "^[\(record.rating) star](inflect: true)")) }
        if record.flag == .pick { parts.append(String(localized: "Pick")) }
        if record.flag == .reject { parts.append(String(localized: "Rejected")) }
        if let label = record.label { parts.append(PhotoInspector.labelTitle(label)) }
        if record.isEdited { parts.append(String(localized: "Edited")) }
        return parts.joined(separator: ", ")
    }

    let path: String
    let record: PhotoRecord
    let selected: Bool
    var compact = false
    var check: PhotoCheck?
    /// More photos in its moment, behind it; or the last photo of an open moment (to close it by).
    var stack = 0
    var opened = false
    var toggleStack: (() -> Void)?
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
            .overlay(alignment: .bottomTrailing) {
                // What the quick look found (only when something may be wrong), and bursts.
                if !compact {
                    HStack(spacing: 4) {
                        if let check, check.eyesClosed { Image(systemName: "eye.slash").help("Eyes may be closed") }
                        if let check, check.looksSoft { Image(systemName: "circle.dotted").help("May be out of focus") }
                        if stack > 0 {
                            Button { toggleStack?() } label: { Label("+\(stack)", systemImage: "square.stack") }
                                .buttonStyle(.plain)
                                .help("Moment: the strongest shown, ^[\(stack) more photo](inflect: true) behind it")
                        } else if opened {
                            Button { toggleStack?() } label: { Image(systemName: "chevron.up.square") }
                                .buttonStyle(.plain)
                                .help("Close this moment")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((check?.possibleReject ?? false) || stack > 0 || opened ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.clear), in: .capsule)
                    .padding(6)
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
            .overlay(alignment: .topLeading) {
                // A virtual copy: its number.
                if let number = PhotoCatalog.copyNumber(path) {
                    Text(verbatim: "\(number)")
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(compact ? 3 : 6)
                        .help("Virtual copy: its own edit of the same file")
                }
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
            .help(PhotoCatalog.displayName(path))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: PhotoCatalog.displayName(path)))
            .accessibilityValue(Text(Self.describe(record)))
            .accessibilityAddTraits(selected ? [.isImage, .isSelected] : .isImage)
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
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil) else { return nil }
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
    /// "Before" while the comparison is on (at full size once zoomed in past the preview).
    @State private var beforePicture: CIImage?
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
            Design.Photo.surround
            if let picture {
                GeometryReader { geo in
                    let sideBySide = comparing && editing.beforeAfter == .sideBySide
                    // Side by side, each photo has half the view (zoom and place are the same in both).
                    let area = sideBySide ? CGSize(width: geo.size.width / 2, height: geo.size.height) : geo.size
                    let own = pictureFrame(in: area)
                    let frame = sideBySide ? own.offsetBy(dx: area.width, dy: 0) : own
                    ZStack {
                        PhotoCanvas(image: shaped(shownImage ?? picture), frame: frame,
                                    before: comparing ? beforePicture.map(shaped) : nil,
                                    mode: comparing ? editing.beforeAfter : .off, split: editing.split)
                        if let zoom = editing.zoom, !editing.cropping {
                            zoomGestures(zoom: zoom, area: area, frame: own)
                        } else {
                            fitGestures(frame: own, offset: sideBySide ? area.width : 0)
                        }
                        if shapingMask, !editing.cropping, !original, !sideBySide {
                            PhotoMaskHandles(path: path, record: record, frame: frame)
                        } else if editing.mixerTargeting, primary, !editing.cropping, !original, !sideBySide {
                            MixerTarget(path: path, record: record, frame: frame)
                        }
                        if comparing { beforeAfterMarks(frame: frame, area: geo.size) }
                    }
                    .coordinateSpace(name: "loupe")
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
        .overlay(alignment: .bottom) { if editing.cropping, primary, !original { cropBar.padding(14) } }
        .overlay(alignment: .bottom) { if primary { SpeedEditHUD().padding(.bottom, 18) } }
        .onHover { if primary { SpeedEditor.shared.overLoupe = $0 } }
        .background(GeometryReader { geo in Color.clear.onAppear { viewSize = geo.size }.onChange(of: geo.size) { _, size in viewSize = size } })
        .task(id: TaskKey(path: path, record: shownRecord, original: original, overlay: overlay, peak: peak)) { await develop() }
        .task(id: BeforeKey(path: path, record: beforeRecord, on: comparing, full: wantedFull != nil)) { await developBefore() }
        .task(id: wantedFull) {
            // The photo at full size once zoomed in past the preview (decoded once, then only the
            // adjustments are redone).
            guard let key = wantedFull else { return }
            if full == nil || fullKey?.path != key.path { developing = true }
            let path = key.path, record = key.record, marked = key.overlay, peak = key.peak
            let made = await Task.detached(priority: .userInitiated) { PhotoRender.image(path, record: record, maxSize: 0, overlay: marked, peak: peak) }.value
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
        .onChange(of: path) { _, _ in
            if !linked { editing.zoom = nil }
            full = nil; fullKey = nil
            beforePicture = nil
            if primary { editing.selectedMask = nil; editing.beforeSnapshot = nil }
        }
        // (Cropping shows the whole picture with its frame: no comparison then.)
        .onChange(of: editing.cropping) { _, cropping in if cropping, primary { editing.beforeAfter = .off } }
        .onChange(of: editing.zoom) { _, zoom in if zoom == nil { center = CGPoint(x: 0.5, y: 0.5) } }
    }

    /// The crop's controls, on the photo while cropping: the shape, upright or on its side,
    /// straighten, reset and done.
    private var cropBar: some View {
        let a = record.adjust
        let upright = a.cropPortrait ?? PhotoRender.isPortrait(path)
        return HStack(spacing: 10) {
            Picker("Aspect", selection: Binding(get: { a.crop }, set: { value in
                catalog.update([path]) { $0.adjust.crop = value; $0.adjust.cropRect = nil; $0.edited = .now }
            })) {
                ForEach(PhotoAdjustments.Crop.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                catalog.update([path]) { $0.adjust.cropPortrait = !upright; $0.adjust.cropRect = nil; $0.edited = .now }
            } label: {
                Image(systemName: upright ? "rectangle.portrait" : "rectangle")
            }
            .disabled(a.crop.shortOverLong == nil || a.crop == .square)
            .help("Turn the crop upright or on its side (\(Shortcuts.shared.shortcut(.photoTurnCrop).label))")
            .accessibilityLabel(Text("Turn the crop"))
            AdjustSlider(title: "Straighten", value: a.straighten, range: -45...45, format: "%+.1f°") { new in
                catalog.update([path]) { $0.adjust.straighten = new; $0.edited = .now }
            }
            .frame(width: 280)
            Button("Reset") {
                catalog.update([path]) { $0.adjust.crop = .original; $0.adjust.cropRect = nil; $0.adjust.straighten = 0; $0.adjust.cropPortrait = nil; $0.edited = .now }
            }
            Button("Done") { editing.cropping = false }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: .capsule)
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
        let overlay: Int?
        var peak = 1.0
    }

    /// How bright the edit may go on this screen (1 unless the photo is edited in HDR).
    /// (Film makes its own SDR picture.)
    private var peak: Double {
        original || shownRecord.filmOn ? 1 : PhotoEditing.peak(hdr: shownRecord.hdr == true, headroom: editing.headroom)
    }

    private struct BeforeKey: Hashable {
        let path: String
        let record: PhotoRecord
        let on: Bool
        let full: Bool
    }

    private struct FullKey: Hashable {
        let path: String
        let record: PhotoRecord
        let overlay: Int?
        var peak = 1.0
    }

    private var original: Bool { editing.asShot }

    /// Before and after shows: on the photo being edited (not in Compare, not while cropping or
    /// when the photo is held as shot).
    private var comparing: Bool {
        primary && !linked && editing.beforeAfter != .off && !editing.cropping && !original
    }

    /// What "before" is: the photo as shot, or a snapshot's settings (both without film: that takes
    /// seconds), with the crop that shows now so the two line up.
    private var beforeRecord: PhotoRecord {
        var before = PhotoRecord()
        if let id = editing.beforeSnapshot, let snapshot = record.snapshots.first(where: { $0.id == id }) { before.adjust = snapshot.adjust }
        let now = shownRecord.adjust
        before.adjust.crop = now.crop
        before.adjust.cropRect = now.cropRect
        before.adjust.cropPortrait = now.cropPortrait
        before.adjust.straighten = now.straighten
        // Compared as bright as the edit, so HDR itself isn't what looks different.
        before.hdr = shownRecord.hdr
        return before
    }

    /// The picture as shown: with clipping marked when that's on.
    private func shaped(_ image: CIImage) -> CIImage { editing.showClipping ? PhotoEngine.clipping(image, peak: peak) : image }

    private func developBefore() async {
        guard comparing else { beforePicture = nil; return }
        let path = self.path, rec = beforeRecord, size = wantedFull == nil ? PhotoRender.previewSize : 0, peak = self.peak
        let made = await Task.detached(priority: .userInitiated) { PhotoRender.image(path, record: rec, maxSize: size, peak: peak) }.value
        if !Task.isCancelled, let made { beforePicture = made }
    }

    /// The line to drag (the resize cursor over it), and "Before" and "After" in the corners.
    @ViewBuilder
    private func beforeAfterMarks(frame: CGRect, area: CGSize) -> some View {
        let sideBySide = editing.beforeAfter == .sideBySide
        let shown = PhotoComposite.visible(frame: frame, view: area)
        let x = sideBySide ? area.width / 2 : PhotoComposite.splitX(frame: frame, view: area, split: editing.split)
        let left = sideBySide ? 0 : shown.minX, right = sideBySide ? area.width : shown.maxX
        ZStack(alignment: .topLeading) {
            HStack {
                Text("Before").modifier(CornerLabel())
                Spacer(minLength: 0)
                Text("After").modifier(CornerLabel())
            }
            .padding(.leading, left + 10).padding(.trailing, max(area.width - right, 0) + 10).padding(.top, shown.minY + 10)
            Rectangle().fill(.white).frame(width: 1.5, height: shown.height).shadow(color: .black.opacity(0.5), radius: 1.5)
                .offset(x: x - 0.75, y: shown.minY)
                .allowsHitTesting(false)
            if !sideBySide {
                Circle().fill(.white).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: x - 11, y: shown.midY - 11)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: 26, height: shown.height)
                    .contentShape(.rect)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                    .onDisappear { NSCursor.arrow.set() }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("loupe")).onChanged { value in
                        editing.split = min(max((value.location.x - shown.minX) / max(shown.width, 1), 0.02), 0.98)
                    })
                    .offset(x: x - 13, y: shown.minY)
                    .help("Drag to move the line")
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    /// A mask of this photo is being shaped (version 2).
    private var shapingMask: Bool {
        primary && record.adjust.process >= 2 && record.adjust.masks.contains { $0.id == editing.selectedMask }
    }

    /// The mask shown in red while it's shaped.
    private var overlay: Int? {
        guard primary, record.adjust.process >= 2 else { return nil }
        // The one the pointer is over in the list, else the one being shaped.
        if let hover = editing.hoverMask, let index = record.adjust.masks.firstIndex(where: { $0.id == hover }) { return index }
        guard shapingMask, editing.maskOverlay else { return nil }
        return record.adjust.masks.firstIndex { $0.id == editing.selectedMask }
    }

    /// While cropping or shaping a mask, the whole picture shows (the frame marks the crop;
    /// masks are placed on the whole photo).
    private var shownRecord: PhotoRecord {
        var shown = primary ? editing.previewRecord ?? record : record
        // (A look pointed at shows without its film: that takes seconds.)
        if primary, editing.previewRecord != nil { shown.filmOn = false }
        if editing.cropping || shapingMask {
            shown.adjust.cropRect = nil
            shown.adjust.crop = .original
            shown.filmOn = false
        }
        // An Adjust section's eye held: the photo without it.
        if primary, let peek = editing.peek { peek.reset(&shown.adjust) }
        return shown
    }

    /// The settings to show the full size for: zoomed in past the preview's own pixels.
    private var wantedFull: FullKey? {
        guard let zoom = editing.zoom, !editing.cropping, zoom * scaleToFull > 1.05 else { return nil }
        var shown = original ? PhotoRecord() : shownRecord
        shown.filmOn = false
        return FullKey(path: path, record: shown, overlay: original ? nil : overlay, peak: peak)
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
        let area = comparing && editing.beforeAfter == .sideBySide ? CGSize(width: viewSize.width / 2, height: viewSize.height) : viewSize
        let fitted = Self.fitted(picture.extent.size, in: area, inset: 14)
        return Double(fitted.width) * displayScale / max(Double(picture.extent.width) * scaleToFull, 1)
    }

    /// Where the whole photo goes in the view (points, from the top left).
    private func pictureFrame(in area: CGSize) -> CGRect {
        guard let picture else { return .zero }
        let size = picture.extent.size
        if editing.cropping, primary {
            // Room under the photo for the crop's bar.
            let fitted = Self.fitted(size, in: CGSize(width: area.width, height: max(area.height - 52, 1)), inset: 14)
            return fitted
        }
        guard let zoom = editing.zoom else { return Self.fitted(size, in: area, inset: 14) }
        let width = Double(size.width) * scaleToFull * zoom / displayScale, height = Double(size.height) * scaleToFull * zoom / displayScale
        let c = clamped(center, width: width, height: height, view: area)
        let x = area.width / 2 + (0.5 - c.x) * width + drag.width, y = area.height / 2 + (0.5 - c.y) * height + drag.height
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// Fitted: click to look at that place at 100%, pinch to zoom in.
    private func fitGestures(frame: CGRect, offset: Double = 0) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { location in
                guard !editing.cropping, frame.width > 0 else { return }
                // (Side by side, the right half is the same picture shifted over.)
                let x = location.x >= offset && offset > 0 ? location.x - offset : location.x
                center = CGPoint(x: min(max((x - frame.minX) / frame.width, 0), 1),
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
        let marked = original ? nil : overlay, peak = self.peak
        let quick = await Task.detached(priority: .userInitiated) { PhotoRender.image(path, record: shown, maxSize: size, overlay: marked, peak: peak) }.value
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
            // (Not while a mask shows in red.)
            guard !Task.isCancelled, var quick, marked == nil else { return }
            // The histogram and the grid's copy are the SDR picture (an HDR one would clip in them).
            if peak > 1, let sdr = await Task.detached(priority: .utility, operation: { PhotoRender.image(path, record: shown, maxSize: size) }).value {
                guard !Task.isCancelled else { return }
                quick = sdr
            }
            let measured = quick
            if primary { editing.histogram = await Task.detached(priority: .utility) { PhotoEngine.histogram(measured) }.value }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, shown.isEdited else { return }
            await Task.detached(priority: .utility) {
                if let small = PhotoRender.picture(measured, maxSize: 1200) { PhotoRender.savePreview(small, to: cached) }
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
            Design.Photo.surround
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(14) }
            VStack {
                Spacer()
                if let image, let faces = PhotoChecks.shared.check(path)?.faces, !faces.isEmpty {
                    FaceStrip(image: image, faces: faces)
                }
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
                    Text(PhotoCatalog.displayName(path)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
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

/// The faces in a photo, close up, to check eyes and focus at a glance.
private struct FaceStrip: View {
    let image: NSImage
    let faces: [CGRect]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(faces.prefix(8).enumerated()), id: \.offset) { _, face in
                if let crop = crop(face) {
                    Image(decorative: crop, scale: 1).resizable().scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(.white.opacity(0.3)))
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: Design.Radius.control))
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    /// A face with some room around it (Vision's box is from the bottom left).
    private func crop(_ box: CGRect) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = max(box.width * w, box.height * h) * 1.5
        let centre = CGPoint(x: box.midX * w, y: (1 - box.midY) * h)
        let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return cg.cropping(to: rect.integral)
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
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil) else { return nil }
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

/// "Before" and "After", small, in a photo's corners.
private struct CornerLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: .capsule)
            .allowsHitTesting(false)
    }
}
