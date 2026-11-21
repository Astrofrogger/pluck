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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Import Photos").font(Design.Studio.pageTitle)
                Spacer(minLength: 8)
                if !items.isEmpty {
                    Text(AttributedString(localized: "^[\(items.count) photo](inflect: true) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"))
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
            }
            fromSide
            if !cameraList.isEmpty { clocks }
            StudioSegmented(ground: Design.Studio.backdrop,
                            options: [(true, "Copy to a Folder"), (false, "Use Where They Are")], selection: $copy, fill: true)
            if copy { toSide }
            VStack(spacing: 0) {
                StudioField(label: "Album") {
                    if let intoAlbum {
                        Text(verbatim: intoAlbum).font(Design.Studio.body).lineLimit(1)
                    } else {
                        TextField("Album", text: $album, prompt: Text("Album").foregroundStyle(Design.Studio.textFaint))
                            .textFieldStyle(.plain)
                            .font(Design.Studio.body)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                    }
                }
                StudioField(label: "Metadata") {
                    Menu {
                        Button("None") { templateID = "" }
                        if !templates.isEmpty { Divider() }
                        ForEach(templates) { item in Button(item.name) { templateID = item.id.uuidString } }
                        Divider()
                        Button("New Template…") { editingTemplate = PhotoMetadataTemplate(name: "") }
                        if let template { Button("Edit “\(template.name)”…") { editingTemplate = template } }
                    } label: {
                        StudioMenuLabel(title: template?.name ?? String(localized: "None"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Creator, copyright, keywords and more, given to each photo as it comes in")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .studioBox()
            footer
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .foregroundStyle(Design.Studio.text)
        .background(Design.Studio.panel)
        .preferredColorScheme(.dark)
        .tint(Design.Brand.pink)
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
            // Tests: -PluckScreenshotImportEmpty YES shows the sheet before anything is chosen.
            let empty = ScreenshotMode.scene == "photo" && UserDefaults.standard.bool(forKey: "PluckScreenshotImportEmpty")
            if empty {} else if !initial.isEmpty { choose(initial) } else if let card = cards.first { choose([card]) }
            // Tests: -PluckScreenshotImportGo YES starts at once.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotImportGo") {
                try? await Task.sleep(for: .seconds(1))
                start()
            }
        }
    }

    /// A quiet small-caps name over a part of the sheet.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Design.Studio.hint.weight(.semibold)).textCase(.uppercase).foregroundStyle(Design.Studio.textQuiet)
    }

    // MARK: - From

    private var fromSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Import from")
            // A card is added or taken off the list, so photos from several cameras come in together.
            ForEach(cards, id: \.self) { card in
                ImportSourceRow(symbol: "sdcard", title: OffloadCenter.volumeName(card), detail: sources.contains(card) ? countText(card) : "",
                                on: sources.contains(card), remove: sources.contains(card) ? { toggle(card) } : nil)
                    .onTapGesture { if !sources.contains(card) { toggle(card) } }
                    .help(card.path)
            }
            ForEach(sources.filter { !cards.contains($0) }, id: \.self) { source in
                ImportSourceRow(symbol: source.hasDirectoryPath ? "folder" : "photo", title: source.lastPathComponent, detail: countText(source),
                                on: true) { choose(sources.filter { $0 != source }) }
                    .help(source.path)
            }
            StudioDashedButton(title: "Add a card or folder…") { pick() }
                .help("Folders or photos; ⌘-click to choose several")
            if !sources.isEmpty && items.isEmpty {
                OffloadNote(symbol: "exclamationmark.triangle", text: Text("No photos found there."), colour: Design.Studio.warn)
            }
        }
    }

    /// How many photos of the list come from this source (a RAW and its JPEG count once, as in the title).
    private func countText(_ source: URL) -> String {
        let prefix = source.standardizedFileURL.path + "/"
        let count = items.filter { $0.primary == source || $0.primary.standardizedFileURL.path.hasPrefix(prefix) }.count
        return String(AttributedString(localized: "^[\(count) photo](inflect: true)").characters)
    }

    // MARK: - To

    private var toSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Copy to")
            ImportFolderRow(url: folder) { folderPath = $0.path }
            if let backup {
                ImportFolderRow(url: backup, badge: "Backup", remove: { backupOn = false }) { backupPath = $0.path }
            } else {
                StudioDashedButton(title: "Add a backup…") {
                    if let picked = Self.chooseFolder() { backupPath = picked.path; backupOn = true }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                StudioSwitchRow(title: "In a folder per day", isOn: $byDate)
                StudioSwitchRow(title: "Date in the name", isOn: $rename)
            }
            .padding(.top, 4)
        }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Under way, done

    @ViewBuilder private var footer: some View {
        if copying {
            VStack(alignment: .leading, spacing: 6) {
                StudioProgress(share: Double(progress) / Double(max(items.count, 1)))
                Text("Copying \(progress) of \(items.count)…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        if let problem, report == nil { OffloadNote(symbol: "exclamationmark.triangle", text: Text(problem), colour: Design.Studio.warn) }
        if let report { safety(report) }
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if report != nil {
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(StudioFlatButtonStyle(height: 32))
                        .keyboardShortcut(.cancelAction).disabled(copying)
                    Button(action: start) {
                        Label(items.isEmpty ? String(localized: "Import") : String(localized: "Import \(items.count) Photos"),
                              systemImage: "arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || copying || (copy && backupOn && backup == nil))
                }
            }
            if copy && report == nil {
                StudioFootnote(text: "Every copy is read back and checked", symbol: "checkmark.shield")
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Camera clocks

    /// Each camera's clock: a photo of it and what time it really was, so photos of several cameras come in
    /// in the order they were taken. Only the copies' dates are shifted.
    private var clocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Camera clocks")
            ForEach(cameraList) { cam in
                HStack(spacing: 12) {
                    ImportThumb(url: samples[cam.key])
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: cam.label).font(Design.Studio.body.weight(.medium)).lineLimit(1)
                        if let sample = samples[cam.key], let date = sampleDates[cam.key] {
                            Text("\(sample.lastPathComponent) · \(date.formatted(date: .omitted, time: .standard))")
                                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Menu {
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
                    } label: {
                        clockLabel(offsets[cam.key] ?? 0)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
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
                .padding(.horizontal, 12)
                .frame(height: 52)
                .studioBox()
            }
        }
    }

    /// "Clock is right" quietly; an offset as a plum chip.
    private func clockLabel(_ offset: TimeInterval) -> some View {
        let right = abs(offset) < 1
        return HStack(spacing: 5) {
            Text(verbatim: offsetText(offset))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(Design.Studio.hint.weight(right ? .regular : .semibold))
        .foregroundStyle(right ? Design.Studio.textQuiet : Design.Brand.pink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(right ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Design.Brand.pink.opacity(0.12)), in: .capsule)
        .contentShape(.rect)
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
        let colour = report.safe ? Design.Studio.good : Design.Studio.bad
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: report.safe ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16)).foregroundStyle(colour).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.safe ? "Safe to format" : "Not safe to format").font(Design.Studio.body.weight(.semibold)).foregroundStyle(colour)
                if report.safe {
                    Text(report.copies == 2 ? AttributedString(localized: "^[\(report.copied) photo](inflect: true) in 2 checked copies")
                         : AttributedString(localized: "^[\(report.copied) photo](inflect: true) in 1 checked copy"))
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                } else {
                    Text(verbatim: report.failed.prefix(5).joined(separator: "\n") + (report.failed.count > 5 ? "\n…" : ""))
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(6).truncationMode(.middle)
                    if let problem { Text(problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(colour.opacity(0.12), in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
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
            // Tests: -PluckScreenshotImportClock YES sets the second camera's clock two hours off.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotImportClock"), cams.count > 1 { offsets[cams[1].key] = 7200 }
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
        let fromCard = sources.contains(where: cards.contains) || (ScreenshotMode.scene == "photo" && UserDefaults.standard.bool(forKey: "PluckScreenshotImportGo"))
        Task {
            var imported: [String] = []
            var pairs: [(source: URL, path: String)] = []
            var summary = PhotoImporter.Report(total: list.count, copies: backup == nil ? 1 : 2)
            // In the order they were taken, each camera's clock shifted by its offset.
            let planned = await Task.detached(priority: .userInitiated) { PhotoImporter.plan(list, offsets: offsets) }.value
            // Tests: -PluckScreenshotImportHold YES stops halfway, to picture the progress.
            let hold = ScreenshotMode.scene == "photo" && UserDefaults.standard.bool(forKey: "PluckScreenshotImportHold")
            for photo in planned {
                if hold && progress == planned.count / 2 { try? await Task.sleep(for: .seconds(600)) }
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

/// A card or folder photos come from, as Offload's From rows: plum symbol when on the list, an x on hover.
private struct ImportSourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let on: Bool
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                .foregroundStyle(on ? Design.Brand.pink : Design.Studio.textQuiet)
            Text(verbatim: title).font(Design.Studio.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
            Spacer(minLength: 8)
            if hovering, let remove {
                Button("Remove", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            } else {
                Text(verbatim: detail).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .studioBox(outline: on ? Design.rgb(0x8E4C64) : nil)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// Where copies go, as Offload's drive rows: the drive's symbol, the folder, its drive and what's free; click to change.
private struct ImportFolderRow: View {
    let url: URL
    var badge: LocalizedStringKey?
    var remove: (() -> Void)?
    let change: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        // (A folder not made yet: its drive is the nearest folder above it that is there.)
        let there = sequence(first: url) { $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? url
        let drive = OffloadCenter.driveName(there)
        HStack(spacing: 12) {
            Image(systemName: url.path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive")
                .font(.system(size: 14)).frame(width: 18).foregroundStyle(Design.Studio.textQuiet)
            HStack(spacing: 4) {
                Text(verbatim: url.lastPathComponent).font(Design.Studio.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if drive != url.lastPathComponent {
                    Text(verbatim: drive).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let badge { StudioChip(text: Text(badge)) }
            if hovering, let remove {
                Button("Remove", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            } else if let free = OffloadCenter.freeSpace(there) {
                Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .studioBox()
        .contentShape(.rect)
        .onTapGesture { if let picked = PhotoImportSheet.chooseFolder() { change(picked) } }
        .onHover { hovering = $0 }
        .help(url.path)
    }
}

/// The sample photo of a camera, small (its embedded preview, so cheap even for RAW).
private struct ImportThumb: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Design.Studio.raised }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: Design.Radius.small, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
        }
    }
}
