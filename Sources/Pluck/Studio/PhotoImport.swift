import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Bringing photos in, as Photo Mechanic does: from a memory card (found by itself) or a folder,
/// either used where they are or copied to a folder (and at the same time to a backup), filed by
/// the day they were taken and named as you like. Photos already there are skipped; sidecars
/// (.xmp) come along. The originals on the card are never changed.
struct PhotoImportSheet: View {
    /// Where the photos came from, given (a drop, a folder chosen elsewhere), or nil to choose.
    var initial: [URL] = []
    /// The album the photos go into, when importing into one that exists (no name to type then).
    var intoAlbum: String? = nil
    let done: (_ photos: [String], _ album: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("photoImportCopy") private var copy = true
    @AppStorage("photoImportFolder") private var folderPath = ""
    @AppStorage("photoImportBackup") private var backupOn = false
    @AppStorage("photoImportBackupFolder") private var backupPath = ""
    @AppStorage("photoImportByDate") private var byDate = true
    @AppStorage("photoImportRename") private var rename = false
    @AppStorage("photoImportTemplate") private var templateID = ""
    @State private var templates = PhotoMetadataTemplate.saved
    @State private var editingTemplate: PhotoMetadataTemplate?
    @State private var sources: [URL] = []
    @State private var cards: [URL] = []
    @State private var found: [URL] = []
    @State private var bytes: Int64 = 0
    @State private var album = ""
    @State private var copying = false
    @State private var progress = 0
    @State private var problem: String?

    private var folder: URL {
        folderPath.isEmpty ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck", isDirectory: true)
            : URL(fileURLWithPath: folderPath, isDirectory: true)
    }
    private var backup: URL? { backupOn && !backupPath.isEmpty ? URL(fileURLWithPath: backupPath, isDirectory: true) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Text("Import Photos").font(Design.Typography.sheetTitle)
            // From
            VStack(alignment: .leading, spacing: 6) {
                Text("From").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(cards, id: \.self) { card in
                        // A card is added or taken off the list, so photos from several cameras come in together.
                        Button { toggle(card) } label: {
                            Label(card.lastPathComponent, systemImage: "sdcard").lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(sources.contains(card) ? .accentColor : nil)
                    }
                    Button(sources.isEmpty ? "Choose…" : "Add…", systemImage: "folder.badge.plus") { pick() }
                        .help("Folders or photos; ⌘-click to choose several")
                }
                ForEach(sources.filter { !cards.contains($0) }, id: \.self) { source in
                    HStack(spacing: 6) {
                        Image(systemName: source.hasDirectoryPath ? "folder" : "photo").foregroundStyle(.secondary)
                        Text(verbatim: source.lastPathComponent).lineLimit(1).truncationMode(.middle).help(source.path)
                        Spacer(minLength: 4)
                        Button { choose(sources.filter { $0 != source }) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Remove"))
                    }
                    .font(.callout)
                }
                if !sources.isEmpty {
                    Text(found.isEmpty ? String(localized: "No photos found there.")
                         : String(localized: "^[\(found.count) photo](inflect: true), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // How
            Picker("How", selection: $copy) {
                Text("Copy to a Folder").tag(true)
                Text("Use Where They Are").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if copy {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("To").foregroundStyle(.secondary)
                        folderButton(folder) { folderPath = $0.path }
                    }
                    GridRow {
                        Toggle("Backup", isOn: $backupOn).toggleStyle(.checkbox)
                        if backupOn {
                            folderButton(backup) { backupPath = $0.path }
                        }
                    }
                    GridRow {
                        Text("Files").foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            Toggle("In a folder per day", isOn: $byDate).toggleStyle(.checkbox)
                            Toggle("Date in the name", isOn: $rename).toggleStyle(.checkbox)
                        }
                    }
                }
                .font(.callout)
            }
            HStack {
                Text("Album").foregroundStyle(.secondary)
                if let intoAlbum {
                    Text(verbatim: intoAlbum).lineLimit(1)
                    Spacer()
                } else {
                    TextField("Album", text: $album).textFieldStyle(.roundedBorder)
                }
            }
            .font(.callout)
            HStack {
                Text("Metadata").foregroundStyle(.secondary)
                Menu(template?.name ?? String(localized: "None")) {
                    Button("None") { templateID = "" }
                    if !templates.isEmpty { Divider() }
                    ForEach(templates) { item in Button(item.name) { templateID = item.id.uuidString } }
                    Divider()
                    Button("New Template…") { editingTemplate = PhotoMetadataTemplate(name: "") }
                    if let template { Button("Edit “\(template.name)”…") { editingTemplate = template } }
                }
                .fixedSize()
                .help("Creator, copyright, keywords and more, given to each photo as it comes in")
                Spacer()
            }
            .font(.callout)
            if copying {
                ProgressView(value: Double(progress), total: Double(max(found.count, 1)))
                Text("Copying \(progress) of \(found.count)…").font(.caption).foregroundStyle(.secondary)
            }
            if let problem { ProblemLabel(text: problem) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(copying)
                Button(copy ? "Copy and Import" : "Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(found.isEmpty || copying || (copy && backupOn && backup == nil))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .sheet(item: $editingTemplate) { item in
            PhotoTemplateSheet(template: item) { saved in
                var all = PhotoMetadataTemplate.saved
                all.removeAll { $0.id == item.id }
                if let saved {
                    all.append(saved)
                    all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    templateID = saved.id.uuidString
                } else if templateID == item.id.uuidString {
                    templateID = ""
                }
                PhotoMetadataTemplate.saved = all
                templates = all
            }
        }
        .task {
            // (Not in tests: looking at drives can make macOS ask for access.)
            if ScreenshotMode.scene == nil { cards = Self.memoryCards() }
            if !initial.isEmpty { choose(initial) } else if let card = cards.first { choose([card]) }
            // Tests: -PluckScreenshotImportGo YES starts at once.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotImportGo") {
                try? await Task.sleep(for: .seconds(1))
                start()
            }
        }
    }

    private func folderButton(_ url: URL?, set: @escaping (URL) -> Void) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let picked = panel.url { set(picked) }
        } label: {
            Label(url?.lastPathComponent ?? String(localized: "Choose…"), systemImage: "folder").lineLimit(1)
        }
        .help(url?.path ?? "")
    }

    // MARK: - Where from

    /// Mounted cards and cameras: removable volumes with a DCIM folder.
    static func memoryCards() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { volume in
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let removable = values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
            return removable && FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path)
        }
    }

    /// Folders (or single photos) added to the list: an album's photos often sit in a folder per camera.
    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // .folder too: with only .image a folder can't be chosen, only opened.
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK { choose(sources + panel.urls.filter { !sources.contains($0) }) }
    }

    private func toggle(_ card: URL) {
        choose(sources.contains(card) ? sources.filter { $0 != card } : sources + [card])
    }

    private func choose(_ urls: [URL]) {
        let named = album.isEmpty || album == suggested
        sources = urls
        // A card is copied; a folder already on this Mac is usually used where it is.
        if urls.contains(where: cards.contains) { copy = true }
        if named { album = suggested }
        let list = urls
        Task {
            let photos = await Task.detached(priority: .userInitiated) { PhotoCatalog.photos(in: list).map { URL(fileURLWithPath: $0) } }.value
            guard sources == list else { return }  // (a later choice is being looked through)
            found = photos
            bytes = photos.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }

    /// The album name offered for what's on the list (kept once typed over).
    private var suggested: String {
        sources.count == 1 ? sources[0].lastPathComponent : sources.isEmpty ? "" : String(localized: "Imported \(Date.now.formatted(date: .abbreviated, time: .omitted))")
    }

    // MARK: - Copying

    private var template: PhotoMetadataTemplate? { templates.first { $0.id.uuidString == templateID } }

    /// The template's fields on each photo (its tokens from that photo and the card it came from).
    /// What the photos' sidecars say (ratings from another app) is read first, so it isn't lost.
    private func applyTemplate(_ photos: [(source: URL, path: String)]) async {
        guard let template, !template.meta.isEmpty else { return }
        let catalog = PhotoCatalog.shared
        await catalog.adoptSidecars(of: photos.map(\.path))
        let filled = await Task.detached(priority: .userInitiated) {
            photos.map { ($0.path, PhotoMetadataTemplate.expand(template.meta, file: URL(fileURLWithPath: $0.path), card: PhotoMetadataTemplate.card(of: $0.source))) }
        }.value
        catalog.setMeta(Dictionary(filled.map { ($0.0, $0.1.over(catalog.record($0.0).meta)) }, uniquingKeysWith: { a, _ in a }))
    }

    private func start() {
        guard !found.isEmpty else { return }
        let name = album.trimmingCharacters(in: .whitespaces).isEmpty ? (sources.first?.lastPathComponent ?? "Import") : album
        guard copy else {
            let photos = found.map { (source: $0, path: $0.path) }
            Task {
                await applyTemplate(photos)
                done(photos.map(\.path), name)
                dismiss()
            }
            return
        }
        copying = true
        problem = nil
        progress = 0
        let photos = found, folder = self.folder, backup = self.backup, byDate = self.byDate, rename = self.rename
        Task {
            var imported: [String] = []
            var pairs: [(source: URL, path: String)] = []
            for photo in photos {
                let result = await Task.detached(priority: .userInitiated) {
                    Self.copy(photo, to: folder, backup: backup, byDate: byDate, rename: rename)
                }.value
                switch result {
                case .success(let path): imported.append(path); pairs.append((photo, path))
                case .failure(let error): problem = error.localizedDescription
                }
                progress += 1
            }
            await applyTemplate(pairs)
            copying = false
            if !imported.isEmpty {
                done(imported, name)
                if problem == nil { dismiss() }
            }
        }
    }

    /// One photo copied (and its sidecar), to the folder and the backup; the copy's path. A photo
    /// that's already there (same name and size) isn't copied again.
    nonisolated private static func copy(_ photo: URL, to folder: URL, backup: URL?, byDate: Bool, rename: Bool) -> Result<String, Error> {
        let taken = captureDate(photo)
        var subfolder = ""
        if byDate {
            let day = DateFormatter()
            day.dateFormat = "yyyy/yyyy-MM-dd"
            subfolder = day.string(from: taken)
        }
        var name = photo.lastPathComponent
        if rename {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            name = stamp.string(from: taken) + "-" + name
        }
        var main = ""
        for (i, root) in ([folder] + (backup.map { [$0] } ?? [])).enumerated() {
            let place = subfolder.isEmpty ? root : root.appendingPathComponent(subfolder, isDirectory: true)
            let target = place.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                // The same photo already there (also as name-2, -3… from an earlier import) isn't copied again;
                // another photo with this name (a second card) is kept as name-2, -3….
                var spot = target, n = 1
                while FileManager.default.fileExists(atPath: spot.path) && !sameFile(photo, spot) {
                    n += 1
                    spot = place.appendingPathComponent(target.deletingPathExtension().lastPathComponent + "-\(n)" + (target.pathExtension.isEmpty ? "" : "." + target.pathExtension))
                }
                if !FileManager.default.fileExists(atPath: spot.path) {
                    try FileManager.default.copyItem(at: photo, to: spot)
                    try checked(photo, spot)
                }
                if i == 0 { main = spot.path }
                // Its sidecar too.
                for sidecar in PhotoXMP.sidecars(for: photo.path) where FileManager.default.fileExists(atPath: sidecar.path) {
                    // (A photo kept as name-2 gets its own sidecar name, not the other photo's.)
                    let copyName = spot != target ? spot.deletingPathExtension().lastPathComponent + "." + sidecar.pathExtension
                        : rename ? (name as NSString).deletingPathExtension + "." + sidecar.pathExtension : sidecar.lastPathComponent
                    let to = place.appendingPathComponent(copyName)
                    if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: sidecar, to: to) }
                }
            } catch {
                return .failure(error)
            }
        }
        return .success(main)
    }

    /// The copy read back and compared with the card's (as Offload does): a bad one is removed
    /// and the import stops, so nothing is filed that isn't the photo.
    nonisolated private static func checked(_ photo: URL, _ copy: URL) throws {
        func digest(_ url: URL) throws -> SHA256.Digest {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize()
        }
        guard try digest(photo) == digest(copy) else {
            try? FileManager.default.removeItem(at: copy)
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The copy of “\(photo.lastPathComponent)” didn’t match the original. Check the card and the drive, then import again.")])
        }
    }

    nonisolated private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let one = try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let two = try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        // (Same size alone isn't enough: two cards' IMG_0001.JPG can be.)
        return one == two && FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// When it was taken (the camera's own date), or the file's date.
    nonisolated static func captureDate(_ photo: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(photo as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let format = DateFormatter()
            format.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = format.date(from: text) { return date }
        }
        return (try? photo.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
    }
}
