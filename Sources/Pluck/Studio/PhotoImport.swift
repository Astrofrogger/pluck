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
    let done: (_ photos: [String], _ album: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage("photoImportCopy") private var copy = true
    @AppStorage("photoImportFolder") private var folderPath = ""
    @AppStorage("photoImportBackup") private var backupOn = false
    @AppStorage("photoImportBackupFolder") private var backupPath = ""
    @AppStorage("photoImportByDate") private var byDate = true
    @AppStorage("photoImportRename") private var rename = false
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
                        Button { choose([card]) } label: {
                            Label(card.lastPathComponent, systemImage: "sdcard").lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(sources == [card] ? .accentColor : nil)
                    }
                    Button("Choose…", systemImage: "folder") { pick() }
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
                TextField("Album", text: $album).textFieldStyle(.roundedBorder)
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

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { choose(panel.urls) }
    }

    private func choose(_ urls: [URL]) {
        sources = urls
        // A card is copied; a folder already on this Mac is usually used where it is.
        if urls.count == 1, cards.contains(urls[0]) { copy = true }
        album = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "Imported \(Date.now.formatted(date: .abbreviated, time: .omitted))")
        let list = urls
        Task {
            let photos = await Task.detached(priority: .userInitiated) { PhotoCatalog.photos(in: list).map { URL(fileURLWithPath: $0) } }.value
            found = photos
            bytes = photos.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }

    // MARK: - Copying

    private func start() {
        guard !found.isEmpty else { return }
        let name = album.trimmingCharacters(in: .whitespaces).isEmpty ? (sources.first?.lastPathComponent ?? "Import") : album
        guard copy else {
            done(found.map(\.path), name)
            dismiss()
            return
        }
        copying = true
        problem = nil
        progress = 0
        let photos = found, folder = self.folder, backup = self.backup, byDate = self.byDate, rename = self.rename
        Task {
            var imported: [String] = []
            for photo in photos {
                let result = await Task.detached(priority: .userInitiated) {
                    Self.copy(photo, to: folder, backup: backup, byDate: byDate, rename: rename)
                }.value
                switch result {
                case .success(let path): imported.append(path)
                case .failure(let error): problem = error.localizedDescription
                }
                progress += 1
            }
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
                if !sameFile(photo, target) {
                    if FileManager.default.fileExists(atPath: target.path) {
                        // Another photo with this name: keep both.
                        let other = place.appendingPathComponent(target.deletingPathExtension().lastPathComponent + "-2." + target.pathExtension)
                        try FileManager.default.copyItem(at: photo, to: other)
                        try checked(photo, other)
                        if i == 0 { main = other.path }
                    } else {
                        try FileManager.default.copyItem(at: photo, to: target)
                        try checked(photo, target)
                        if i == 0 { main = target.path }
                    }
                } else if i == 0 {
                    main = target.path
                }
                // Its sidecar too.
                for sidecar in PhotoXMP.sidecars(for: photo.path) where FileManager.default.fileExists(atPath: sidecar.path) {
                    let copyName = rename ? (name as NSString).deletingPathExtension + "." + sidecar.pathExtension : sidecar.lastPathComponent
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
        return one == two
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
