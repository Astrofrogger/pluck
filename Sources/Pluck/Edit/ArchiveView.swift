import SwiftUI

/// Archive: folders (or a whole share) shrunk to checked masters, by default; or, from a timeline,
/// only what an edit used (Archive Project).
struct ArchiveView: View {
    @AppStorage("archiveMode") private var timeline = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text("Archive").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                StudioSegmented(options: [(false, "Folders"), (true, "Timeline")], selection: $timeline)
                    .help("Timeline: only what an edit used, with its renders and project")
                Spacer()
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, timeline ? 0 : 6)
            .frame(maxWidth: 960).frame(maxWidth: .infinity)
            if timeline { ProjectArchiveView(embedded: true) } else { ShrinkFoldersView() }
        }
        .studioPanel()
    }
}

/// Shrink Folders: pick folders → the list with what each saves → Start.
struct ShrinkFoldersView: View {
    typealias Settings = ShrinkFolders.Settings
    typealias File = ShrinkFolders.File
    enum Machine: Int { case here, office, both }

    /// Kept while another page is open.
    @MainActor private enum Kept {
        static var folders: [URL] = []
        static var files: [File] = []
    }
    @State private var folders = Kept.folders
    @State private var files = Kept.files
    @State private var scanning: Task<Void, Never>?
    @State private var found = 0
    @State private var unticked: Set<String> = []
    @State private var kinds: Set<ShrinkFolders.Kind> = [.rushes]
    @State private var overrides: [String: ShrinkFolders.Kind] = [:]
    @AppStorage("shrinkSize") private var size = Settings.Size.hd.rawValue
    @AppStorage("shrinkProRes") private var prores = false
    @AppStorage("shrinkBalanced") private var balanced = false
    @AppStorage("shrinkMonths") private var months = 6
    @State private var destination: URL?
    @State private var machine = Machine.here
    @State private var officeProblem: String? = String(localized: "Checking…")
    @AppStorage("shrinkOvernight") private var overnight = false
    @AppStorage("shrinkClearCaches") private var clearCaches = false
    @State private var caches: [(path: String, size: Int64)] = []
    @State private var confirmCaches = false
    @State private var problems: [String] = []
    @State private var following: Set<UUID> = []
    private var center: ShrinkCenter { ShrinkCenter.shared }

    private let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    private var tool: (String) -> String? { { AppDelegate.shared?.manager.tool($0) } }

    private var settings: Settings {
        prores ? Settings.master.with(size: Settings.Size(rawValue: size) ?? .hd)
            : Settings.compact.with(size: Settings.Size(rawValue: size) ?? .hd, quality: balanced ? .balanced : .high)
    }

    private func kind(_ file: File) -> ShrinkFolders.Kind { overrides[file.path] ?? file.kind }

    /// Why a file is left as it is (nil: it can be shrunk).
    private func reason(_ file: File) -> String? {
        if let skip = file.skip { return skip }
        if file.tooSmall(settings) { return String(localized: "Already small") }
        if file.tooRecent(months: months) { return String(localized: "Recent project") }
        return nil
    }

    private func chosen(_ file: File) -> Bool { reason(file) == nil && kinds.contains(kind(file)) && !unticked.contains(file.path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                foldersBox
                if !files.isEmpty {
                    settingsBox
                    summaryBox
                    listBox
                } else if scanning == nil, folders.isEmpty {
                    StudioEmptyState(symbol: "archivebox", title: "Choose folders to shrink",
                                     line: "Old footage becomes checked 1080p masters. The originals move to a folder for you to delete.",
                                     button: "Add Folder…") { addFolder() }
                        .padding(.vertical, 48)
                        .studioDropZone(targeted: false)
                }
                progressBox
                ForEach(center.runs.prefix(10)) { run in runBox(run) }
                StudioFootnote(text: "Pluck never deletes: originals go to “Pluck · Originals to delete”", symbol: "checkmark.shield")
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onChange(of: folders) { Kept.folders = folders }
        .onChange(of: files) { Kept.files = files }
        .onChange(of: overnight) { center.keepAwake = overnight }
        .task {
            center.keepAwake = overnight
            for run in center.runs where run.files.contains(where: { $0.state == .elsewhere }) { follow(run.id) }
            officeProblem = await ShrinkRemote.unavailable()
        }
        .confirmationDialog("Move these caches to the Trash?", isPresented: $confirmCaches) {
            Button("Move to Trash", role: .destructive) {
                for cache in caches { try? FileManager.default.trashItem(at: URL(fileURLWithPath: cache.path), resultingItemURL: nil) }
                caches = []
            }
        } message: {
            Text(verbatim: caches.map { "\(($0.path as NSString).abbreviatingWithTildeInPath) (\(bytes($0.size)))" }.joined(separator: "\n"))
        }
    }

    // MARK: Folders

    private var foldersBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(folders, id: \.self) { folder in
                let mine = files.filter { $0.folder == folder.standardizedFileURL.resolvingSymlinksInPath().path }
                let picked = mine.filter(chosen)
                let before = picked.reduce(Int64(0)) { $0 + $1.size }, after = picked.reduce(Int64(0)) { $0 + $1.estimate(settings) }
                line("folder", Text(verbatim: folder.lastPathComponent),
                     Text(verbatim: !FileManager.default.isWritableFile(atPath: folder.path) && destination == nil ? String(localized: "Read-only: choose a destination")
                          : picked.isEmpty ? "" : "\(picked.count) · \(bytes(before)) → \(bytes(after))"),
                     colour: FileManager.default.isWritableFile(atPath: folder.path) || destination != nil ? Design.Studio.text : Design.Studio.warn) {
                    iconButton("xmark", label: "Remove") { folders.removeAll { $0 == folder }; rescan() }
                }
                .help(folder.path)
            }
            HStack(spacing: 10) {
                StudioDashedButton(title: "Add Folder or Share", height: 32) { addFolder() }
                if let scanning {
                    PlumSpinner().frame(width: 16, height: 16)
                    Text("Looking… \(found) files").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    Button("Stop") { scanning.cancel(); self.scanning = nil }.buttonStyle(StudioFlatButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
        .disabled(center.running)
    }

    private func addFolder() {
        guard let folder = pickFolder(), !folders.contains(folder) else { return }
        folders.append(folder)
        rescan()
    }

    private func rescan() {
        scanning?.cancel()
        guard let ffprobe = tool("ffprobe"), !folders.isEmpty else { files = []; scanning = nil; return }
        let chosen = folders
        found = 0
        scanning = Task {
            let stop = StopFlag()
            let made = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    ShrinkFolders.scan(chosen, ffprobe: ffprobe, stopped: { stop.value }, found: { count in Task { @MainActor in found = count } })
                }.value
            } onCancel: { stop.value = true }
            guard !Task.isCancelled else { return }
            files = made
            scanning = nil
        }
    }

    // MARK: Settings

    private var settingsBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StudioSegmented(options: [(Settings.Size.hd.rawValue, "1080p"), (Settings.Size.k4.rawValue, "4K")], selection: $size)
                StudioSegmented(options: [(false, "HEVC 10-bit"), (true, "ProRes 422 HQ")], selection: $prores)
                if !prores { StudioSegmented(options: [(false, "High"), (true, "Balanced")], selection: $balanced) }
                Spacer()
                Menu {
                    ForEach([0, 3, 6, 12, 24], id: \.self) { value in Button(monthsLabel(value)) { months = value } }
                } label: { StudioMenuLabel(title: monthsLabel(months)) }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .help("Whole projects with a newer file are left as they are")
            }
            HStack(spacing: 8) {
                ForEach(ShrinkFolders.Kind.allCases, id: \.self) { item in
                    let count = files.filter { kind($0) == item && reason($0) == nil }.count
                    Button {
                        if kinds.contains(item) { kinds.remove(item) } else { kinds.insert(item) }
                    } label: {
                        StudioChip(text: Text(verbatim: "\(item.label) \(count)"), symbol: kinds.contains(item) ? "checkmark" : nil,
                                   colour: kinds.contains(item) ? Design.Brand.pink : Design.Studio.textQuiet, tinted: kinds.contains(item))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Menu {
                    Button("In place") { destination = nil }
                    Button("Another Folder…") { destination = pickFolder() ?? destination }
                } label: {
                    StudioMenuLabel(title: destination.map { String(localized: "To \($0.lastPathComponent)") } ?? String(localized: "In place"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("In place: each master takes its original’s name. Another folder: the same folders there, originals left as they are")
            }
            HStack(spacing: 10) {
                StudioSegmented(options: [(Machine.here, "This Mac"), (Machine.office, "Always-on Mac"), (Machine.both, "Both")], selection: $machine)
                    .disabled(officeProblem != nil)
                    .help(officeProblem ?? String(localized: "Both: the two Macs share the files"))
                    .onChange(of: machine) { if officeProblem != nil { machine = .here } }
                if let officeProblem { Text(verbatim: officeProblem).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
                Spacer()
                StudioSwitchRow(title: "Run overnight", isOn: $overnight).help("Keeps this Mac awake while it runs")
                StudioSwitchRow(title: "Clear caches", isOn: $clearCaches).help("Afterwards, offers Resolve’s caches and proxies in these folders for the Trash")
            }
            if files.contains(where: { ProjectArchive.rawMasterKinds.contains(($0.path as NSString).pathExtension.lowercased()) || $0.codec == "prores_raw" }) {
                Text("RAW: ISO and white balance are baked in as shot, in the camera’s log").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
        .disabled(center.running)
    }

    private func monthsLabel(_ value: Int) -> String {
        value == 0 ? String(localized: "Any age") : String(localized: "Older than \(value) months")
    }

    // MARK: The list

    private var summaryBox: some View {
        let picked = files.filter(chosen)
        let before = picked.reduce(Int64(0)) { $0 + $1.size }, after = picked.reduce(Int64(0)) { $0 + $1.estimate(settings) }
        return HStack(spacing: 12) {
            StudioTile(symbol: "arrow.down.right.circle")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(picked.count) files · \(bytes(before)) → \(bytes(after))").font(.system(size: 13)).foregroundStyle(Design.Studio.text)
                Text("Saves about \(bytes(max(before - after, 0)))").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .help("Estimated from each file’s length and the master’s bitrate; files that wouldn’t save 30% are left as they are")
            }
            Spacer()
            Button("Start", systemImage: "play.fill") { start(picked) }
                .buttonStyle(StudioFlatButtonStyle(prominent: true))
                .disabled(picked.isEmpty || center.running || (destination == nil && folders.contains { !FileManager.default.isWritableFile(atPath: $0.path) }))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    private var listBox: some View {
        let groups = Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }.sorted { $0.key < $1.key }
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.key) { folder, items in
                groupLine(folder, items)
                ForEach(items) { file in fileLine(file) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .studioBox()
        .disabled(center.running)
    }

    private func groupLine(_ folder: String, _ items: [File]) -> some View {
        let open = items.filter { reason($0) == nil }
        let root = items.first?.folder ?? ""
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { open.contains { !unticked.contains($0.path) } },
                                 set: { on in for file in open { if on { unticked.remove(file.path) } else { unticked.insert(file.path) } } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(open.isEmpty)
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
            Text(verbatim: folder == root ? (root as NSString).lastPathComponent
                 : (root as NSString).lastPathComponent + "/" + String(folder.dropFirst(root.count + 1)))
                .font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            kindMenu(Set(items.map(kind)).count == 1 ? kind(items[0]) : nil) { new in for file in items { overrides[file.path] = new } }
        }
        .frame(height: 28)
        .padding(.top, 6)
    }

    private func fileLine(_ file: File) -> some View {
        let why = reason(file)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !unticked.contains(file.path) && why == nil }, set: { if $0 { unticked.remove(file.path) } else { unticked.insert(file.path) } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(why != nil)
            Text(verbatim: (file.path as NSString).lastPathComponent).font(Design.Studio.body)
                .foregroundStyle(why == nil && kinds.contains(kind(file)) ? Design.Studio.text : Design.Studio.textFaint)
                .lineLimit(1).truncationMode(.middle)
            kindMenu(kind(file)) { overrides[file.path] = $0 }
                .help(overrides[file.path] == nil ? file.why : String(localized: "Set by you"))
            Spacer(minLength: 8)
            Text(verbatim: why ?? "\(bytes(file.size)) → \(bytes(file.estimate(settings)))")
                .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
        }
        .frame(height: 24)
        .padding(.leading, 24)
        .help(file.path)
    }

    private func kindMenu(_ current: ShrinkFolders.Kind?, set: @escaping (ShrinkFolders.Kind) -> Void) -> some View {
        Menu {
            ForEach(ShrinkFolders.Kind.allCases, id: \.self) { item in Button(item.label) { set(item) } }
        } label: {
            StudioChip(text: Text(verbatim: current?.label ?? "—"))
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    // MARK: Running

    private func start(_ picked: [File]) {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else { return }
        let list = picked.map { var file = $0; file.kind = kind($0); return file }
        let id = center.add(list, settings: settings, destination: destination, roots: folders.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        let machine = machine
        problems = []
        Task {
            if machine != .here, let run = center.run(id) {
                do {
                    let sent = try await ShrinkRemote.send(run, files: list, reversed: machine == .both)
                    if machine == .office {
                        for file in run.files where sent.contains(file.path) { var file = file; file.state = .elsewhere; center.set(file, in: id) }
                    }
                    if !sent.isEmpty { follow(id) }
                } catch { problems.append(ShrinkRemote.reason(error)) }
            }
            await center.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
            if clearCaches, center.run(id)?.files.contains(where: { $0.state == .failed }) == false {
                let chosen = folders
                caches = await Task.detached { ShrinkFolders.caches(in: chosen) }.value
                if !caches.isEmpty { confirmCaches = true }
            }
            rescan()
        }
    }

    private func follow(_ id: UUID) {
        guard following.insert(id).inserted else { return }
        Task { await ShrinkRemote.follow(id); following.remove(id) }
    }

    @ViewBuilder private var progressBox: some View {
        if let id = center.active, let run = center.run(id) {
            let done = run.files.filter { $0.state != .pending && $0.state != .working }.count
            HStack(spacing: 12) {
                if center.waitingForEdit { StudioTile(symbol: "pause.circle") } else { PlumSpinner().frame(width: 40, height: 40) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(center.waitingForEdit ? "Paused while you edit" : "Shrinking \(done + 1) of \(run.files.count)")
                        .font(.system(size: 13)).foregroundStyle(Design.Studio.text)
                    Text(verbatim: center.current.map { ($0 as NSString).lastPathComponent } ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let left = center.timeLeft {
                    Text("About \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
                if center.waitingForEdit { Button("Run Anyway") { center.runAnyway = true }.buttonStyle(StudioFlatButtonStyle()) }
                Button("Pause") { pause(id) }.buttonStyle(StudioFlatButtonStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .studioBox()
        }
        ForEach(problems, id: \.self) { problem in
            line("exclamationmark.triangle", Text(verbatim: problem), Text(verbatim: ""), colour: Design.Studio.warn)
        }
    }

    private func pause(_ id: UUID) {
        center.pause()
        if center.run(id)?.files.contains(where: { $0.state == .elsewhere }) == true {
            Task { _ = try? await OfficeRenderClient.shared.ask("shrinkStop", ["id": id.uuidString], timeout: 20) }
        }
    }

    private func runBox(_ run: ShrinkFolders.Run) -> some View {
        let done = run.files.filter { $0.state == .done }
        let failed = run.files.filter { $0.state == .failed }
        let saved = done.reduce(Int64(0)) { $0 + $1.size - ($1.masterSize ?? 0) }
        let elsewhere = run.files.filter { $0.state == .elsewhere }.count
        let ready = center.readyToDelete(run)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                StudioTile(symbol: failed.isEmpty ? "checkmark" : "exclamationmark.triangle", colour: failed.isEmpty ? Design.Studio.good : Design.Studio.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.date, format: .dateTime.day().month().hour().minute()).font(.system(size: 13)).foregroundStyle(Design.Studio.text)
                    Text(verbatim: [String(localized: "\(done.count) of \(run.files.count) · saved \(bytes(saved))"),
                                    elsewhere > 0 ? String(localized: "\(elsewhere) on the always-on Mac") : nil,
                                    failed.isEmpty ? nil : String(localized: "\(failed.count) failed"),
                                    ready.isEmpty ? nil : String(localized: "\(ready.count) originals ready to delete")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                }
                Spacer()
                if !center.running {
                    if center.unfinished(run), let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") {
                        Button("Resume") { Task { await center.resume(run.id, ffmpeg: ffmpeg, ffprobe: ffprobe) } }.buttonStyle(StudioFlatButtonStyle())
                    }
                    if !ready.isEmpty {
                        Button("Move Originals") { Task { problems = await center.moveOriginals(run.id) } }.buttonStyle(StudioFlatButtonStyle())
                            .help("Moves the checked originals into “Pluck · Originals to delete” on their share")
                    }
                    if center.canPutBack(run) {
                        Button("Put Originals Back") { Task { await center.putBack(run.id) } }.buttonStyle(StudioFlatButtonStyle())
                            .help(run.destination == nil ? "Masters to the Trash, originals back in their place" : "The masters of this run to the Trash")
                    }
                }
                iconButton("folder", label: "Show in Finder") {
                    let places = run.destination.map { [URL(fileURLWithPath: $0)] }
                        ?? Array(Set(done.compactMap { $0.moved.flatMap(ShrinkFolders.holdingFolder(of:)) }))
                    NSWorkspace.shared.activateFileViewerSelecting(places)
                }
                if !center.running { iconButton("xmark", label: "Remove") { center.remove(run.id) } }
            }
            ForEach(failed.prefix(20)) { file in
                Text(verbatim: "\((file.path as NSString).lastPathComponent): \(file.note ?? "")").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 52).help(file.path)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    // MARK: Pieces

    private func line<Actions: View>(_ symbol: String, _ title: Text, _ detail: Text, colour: Color = Design.Studio.text,
                                     @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(colour).frame(width: 22).accessibilityHidden(true)
            title.font(Design.Studio.body).foregroundStyle(Design.Studio.text)
            Spacer(minLength: 8)
            detail.font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            actions()
        }
        .frame(minHeight: 30)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A flag the scan reads from its own thread.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool {
        get { lock.withLock { stopped } }
        set { lock.withLock { stopped = newValue } }
    }
}
