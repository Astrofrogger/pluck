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
    @State private var items: [PhotoImporter.Item] = []
    @State private var cameraList: [PhotoImporter.Camera] = []
    @State private var samples: [String: URL] = [:]
    @State private var sampleDates: [String: Date] = [:]
    @State private var offsets: [String: TimeInterval] = [:]
    @State private var setting: String?
    @State private var settingDate = Date.now
    @State private var report: PhotoImporter.Report?
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
                    Text(items.isEmpty ? String(localized: "No photos found there.")
                         : String(localized: "^[\(items.count) photo](inflect: true), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !cameraList.isEmpty { clocks }
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
                ProgressView(value: Double(progress), total: Double(max(items.count, 1)))
                Text("Copying \(progress) of \(items.count)…").font(.caption).foregroundStyle(.secondary)
            }
            if let problem { ProblemLabel(text: problem) }
            if let report { safety(report) }
            HStack {
                Spacer()
                if report != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(copying)
                    Button(copy ? "Copy and Import" : "Import") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(items.isEmpty || copying || (copy && backupOn && backup == nil))
                }
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

    // MARK: - Camera clocks

    /// Each camera's clock: a photo of it and what time it really was, so photos of several cameras come in
    /// in the order they were taken. Only the copies' dates are shifted.
    private var clocks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera clocks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(cameraList) { cam in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: cam.label).lineLimit(1)
                        if let sample = samples[cam.key], let date = sampleDates[cam.key] {
                            Text("\(sample.lastPathComponent) · \(date.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    Menu(offsetText(offsets[cam.key] ?? 0)) {
                        Button("Clock is right") { offsets[cam.key] = nil }
                        Button("Set the Real Time…") { settingDate = sampleDates[cam.key].map { $0.addingTimeInterval(offsets[cam.key] ?? 0) } ?? .now; setting = cam.key }
                        ForEach(cameraList.filter { $0.key != cam.key }) { other in
                            Button("Same moment as \(other.label)") {
                                if let date = sampleDates[other.key], let mine = sampleDates[cam.key] {
                                    offsets[cam.key] = date.addingTimeInterval(offsets[other.key] ?? 0).timeIntervalSince(mine)
                                }
                            }
                        }
                        Divider()
                        Button("Another Photo…") { choosePhoto(of: cam) }
                    }
                    .fixedSize()
                    .help("Shifts this camera’s dates in the copies so its photos sort with the others’; the originals aren’t changed")
                    .popover(isPresented: Binding(get: { setting == cam.key }, set: { if !$0 { setting = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Real time of this photo").font(.caption).foregroundStyle(.secondary)
                            DatePicker("", selection: $settingDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                            Button("Set") {
                                if let mine = sampleDates[cam.key] {
                                    // (To the minute: the camera's own seconds stay.)
                                    let cal = Calendar.current
                                    let seconds = cal.component(.second, from: mine)
                                    let base = cal.date(bySetting: .second, value: seconds, of: settingDate) ?? settingDate
                                    offsets[cam.key] = (base.timeIntervalSince(mine)).rounded()
                                }
                                setting = nil
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .padding(Design.Spacing.sheet)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func offsetText(_ offset: TimeInterval) -> String {
        guard abs(offset) >= 1 else { return String(localized: "Clock is right") }
        let format = DateComponentsFormatter()
        format.unitsStyle = .abbreviated
        format.maximumUnitCount = 3
        return (offset < 0 ? "−" : "+") + (format.string(from: abs(offset)) ?? "")
    }

    private func setSample(_ cam: PhotoImporter.Camera, _ url: URL) {
        samples[cam.key] = url
        sampleDates[cam.key] = PhotoImporter.captureDate(url)
        offsets[cam.key] = nil
    }

    private func choosePhoto(of cam: PhotoImporter.Camera) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = samples[cam.key]?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url, cam.photos.contains(url) { setSample(cam, url) }
    }

    /// After a card's copy: safe to format only when every photo is in every copy and read back identical.
    private func safety(_ report: PhotoImporter.Report) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: report.safe ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.safe ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.safe ? "Safe to format" : "Not safe to format").font(.callout.weight(.semibold))
                if report.safe {
                    Text(report.copies == 2 ? String(localized: "^[\(report.copied) photo](inflect: true) in 2 checked copies")
                         : String(localized: "^[\(report.copied) photo](inflect: true) in 1 checked copy"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: report.failed.prefix(3).joined(separator: ", ") + (report.failed.count > 3 ? " …" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
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
            let (photos, grouped, cams) = await Task.detached(priority: .userInitiated) {
                let photos = PhotoCatalog.photos(in: list).map { URL(fileURLWithPath: $0) }
                let grouped = PhotoImporter.items(photos)
                return (photos, grouped, PhotoImporter.cameras(in: grouped.map(\.primary)))
            }.value
            guard sources == list else { return }  // (a later choice is being looked through)
            found = photos
            items = grouped
            cameraList = cams
            samples = samples.filter { key, _ in cams.contains { $0.key == key } }
            offsets = offsets.filter { key, _ in cams.contains { $0.key == key } }
            for cam in cams where samples[cam.key] == nil { setSample(cam, cam.photos[0]) }
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
        guard !items.isEmpty else { return }
        let name = album.trimmingCharacters(in: .whitespaces).isEmpty ? (sources.first?.lastPathComponent ?? "Import") : album
        guard copy else {
            let photos = items.map { (source: $0.primary, path: $0.primary.path) }
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
        let list = items, folder = self.folder, backup = self.backup, byDate = self.byDate, rename = self.rename, offsets = self.offsets
        let fromCard = sources.contains(where: cards.contains)
        Task {
            var imported: [String] = []
            var pairs: [(source: URL, path: String)] = []
            var summary = PhotoImporter.Report(total: list.count, copies: backup == nil ? 1 : 2)
            // In the order they were taken, each camera's clock shifted by its offset.
            let planned = await Task.detached(priority: .userInitiated) { PhotoImporter.plan(list, offsets: offsets) }.value
            for photo in planned {
                let result = await Task.detached(priority: .userInitiated) {
                    PhotoImporter.copy(photo, to: folder, backup: backup, byDate: byDate, rename: rename)
                }.value
                if case .failure(let error) = result { problem = error.localizedDescription }
                if let path = summary.add(result, photo.item.primary.lastPathComponent) { imported.append(path); pairs.append((photo.item.primary, path)) }
                progress += 1
            }
            await applyTemplate(pairs)
            copying = false
            if fromCard { report = summary }
            if !imported.isEmpty {
                done(imported, name)
                if problem == nil && !fromCard { dismiss() }
            }
        }
    }

    /// When it was taken (a sidecar's date, the camera's own date, or the file's date).
    nonisolated static func captureDate(_ photo: URL) -> Date { PhotoImporter.captureDate(photo) }
}
