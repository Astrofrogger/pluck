import AppKit
import Foundation

/// What Archive's dashboard and New Archive show and do, apart from how they look: the shares and
/// their space, what can be freed and where, clients → projects with their space by kind and what
/// they'd save, the choices, the run going on this Mac and the always-on Mac, and the files left
/// alone. The engine is ShrinkFolders / ShrinkCenter; this only gathers and starts.
@MainActor
@Observable
final class ArchiveModel {
    static let shared = ArchiveModel()
    typealias Settings = ShrinkFolders.Settings
    typealias File = ShrinkFolders.File
    typealias Project = ShrinkFolders.Project
    enum Machine: Int, Sendable { case here, office, both }
    enum Order: Int, Sendable { case saving, size, name }
    /// Where the page is: the dashboard, a step of New Archive, or a list from the dashboard.
    enum Screen: Int, Sendable { case dashboard, folders, projects, settings, untouched, history }

    struct Share: Identifiable {
        var id: String { path }
        var path: String
        var name: String
        /// Bytes found in the chosen folders on it, and what the chosen files would free.
        var used: Int64
        var saving: Int64
        var free: Int64?
        var capacity: Int64?
        /// Share full now and after (0…1; nil: the drive doesn't say).
        var now: Double? { capacity.flatMap { total in free.map { Double(total - $0) / Double(max(total, 1)) } } }
        var after: Double? { capacity.flatMap { total in now.map { max($0 - Double(saving) / Double(max(total, 1)), 0) } } }
    }
    struct ProjectRow: Identifiable {
        var id: String { project.folder }
        var project: Project
        var saving: Int64
        /// Files it would shrink.
        var files: Int
        var newest: Date
        var selected: Bool
        /// Masters made of it so far (all runs), and files still to do in the run going.
        var done: Int
        var waiting: Int
        /// Why nothing in it would be shrunk ("recent", "small"; nil: something would).
        var dim: String?
    }
    struct Client: Identifiable { var id: String { name }; var name: String; var projects: [ProjectRow] }
    struct Untouched: Identifiable { var id: String { path }; var path: String; var size: Int64; var project: String; var reason: String }
    struct Progress { var machine: String; var done: Int; var total: Int; var current: String?; var left: Double?; var waitingForEdit: Bool }
    /// A share's folder to delete: what's in it, and a recycle bin there that keeps deleted files' space; what of
    /// it a checked master accounts for (safe to delete) and what not (not checked, or not safe), by file.
    struct Waiting: Identifiable, Sendable {
        var id: String { folder.path }
        var share: String
        var folder: URL
        var bytes: Int64
        var recycle: String?
        var safe: Int64 = 0
        /// Not checked yet (or the check is over a week old), and not safe (a check found a problem, or the master changed since).
        var unsafe: Int64 = 0
        var notSafe: Int64 = 0
        var safeFiles: [URL] = []
        /// Everything that isn't safe (for "Don't delete yet"), and the not-safe ones with why.
        var unsafeFiles: [String] = []
        var notSafeFiles: [String] = []
    }
    /// Check Before Deleting's result for one project of a run.
    struct ProjectCheck: Identifiable {
        var id: String { title }; var title: String; var masters: Int; var checked: Int; var problems: [String]
        /// Its run is through (here and on the other Mac).
        var finished = true
        /// "Safe to delete": every master checked and passed, nothing of it left to do.
        var safe: Bool { problems.isEmpty && finished && masters > 0 && checked == masters }
    }
    typealias Choice = ShrinkFolders.Rules.Choice
    /// What a run's history row shows that needs the drive (looked at off the main thread, kept).
    struct RunInfo: Sendable { var canPutBack = false; var ready: [File] = []; var relinkBack = false }
    private(set) var history: [UUID: RunInfo] = [:]

    // MARK: State

    var screen = Screen.dashboard
    private(set) var folders: [URL] = []
    /// (Settable for the self-test.)
    var survey: ShrinkFolders.Survey? { didSet { refreshChoices() } }
    /// Each project's own size (Keep 4K, Skip), by project folder (from the rules kept per share).
    private(set) var choices: [String: Choice] = [:]
    /// Waiting in the folders to delete, and what's really gone from them (measured, never deleted by Pluck).
    private(set) var waiting: [Waiting] = []
    private(set) var freedSoFar: Int64 = 0
    private(set) var scanning = false
    private(set) var found = 0
    private(set) var problems: [String] = []
    private(set) var officeProblem: String? = String(localized: "Checking…")
    var off: Set<String> = []
    var unticked: Set<String> = []
    var overrides: [String: ShrinkFolders.Kind] = [:]
    var size = Settings.Size.hd { didSet { save() } }
    var prores = false { didSet { save() } }
    var balanced = false { didSet { save() } }
    var months = 6 { didSet { save() } }
    var order = Order.saving
    /// Also videos that aren't clearly rushes (deliveries never).
    var other = false
    var destination: URL?
    var machine = Machine.here
    var overnight = false { didSet { center.keepAwake = overnight; save() } }
    /// Proxies and caches of an archived project go to the folder to delete too.
    var moveProxies = true { didSet { save() } }

    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var following: Set<UUID> = []
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loading = true
    let center: ShrinkCenter

    init(center: ShrinkCenter = .shared) {
        self.center = center
        size = Settings.Size(rawValue: defaults.integer(forKey: "shrinkSize")).flatMap { $0 == .native ? nil : $0 } ?? .hd
        prores = defaults.bool(forKey: "shrinkProRes")
        balanced = defaults.bool(forKey: "shrinkBalanced")
        months = defaults.object(forKey: "shrinkMonths") as? Int ?? 6
        overnight = defaults.bool(forKey: "shrinkOvernight")
        moveProxies = !defaults.bool(forKey: "shrinkKeepProxies")
        loading = false
        // The last folders looked at, and that look (the dashboard opens on it).
        folders = (defaults.stringArray(forKey: "shrinkFolders") ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !folders.isEmpty { survey = ShrinkFolders.savedSurvey(folders.map { ShrinkFolders.real($0).path }) }
        refreshChoices()
    }

    private func refreshChoices() {
        let sizes = ShrinkFolders.Rules.load().sizes ?? [:]
        guard !sizes.isEmpty else { choices = [:]; return }
        choices = (survey?.projects.values ?? [:].values).reduce(into: [:]) { found, project in
            if let choice = sizes[ShrinkFolders.Rules.key(project.folder, share: project.share)] { found[project.folder] = choice }
        }
    }

    private func save() {
        guard !loading else { return }
        defaults.set(size.rawValue, forKey: "shrinkSize")
        defaults.set(prores, forKey: "shrinkProRes")
        defaults.set(balanced, forKey: "shrinkBalanced")
        defaults.set(months, forKey: "shrinkMonths")
        defaults.set(overnight, forKey: "shrinkOvernight")
        defaults.set(!moveProxies, forKey: "shrinkKeepProxies")
    }

    private func keepFolders() { defaults.set(folders.map(\.path), forKey: "shrinkFolders") }

    var settings: Settings {
        prores ? Settings.master.with(size: size) : Settings.compact.with(size: size, quality: balanced ? .balanced : .high)
    }

    /// The settings in one quiet line ("1080p HEVC · older than 6 months").
    var summary: String {
        [size == .hd ? "1080p" : "4K", prores ? "ProRes 422 HQ" : (balanced ? String(localized: "HEVC Balanced") : "HEVC"),
         months == 0 ? String(localized: "any age") : String(localized: "older than \(months) months"),
         destination.map { String(localized: "to \($0.lastPathComponent)") }].compactMap { $0 }.joined(separator: " · ")
    }

    /// The files found, each with its project's own size (Keep 4K).
    var files: [File] {
        let k4 = settings.size == .k4 ? nil : settings.with(size: .k4)
        // (Originals whose master a run made in another folder: nothing more to free by shrinking them.)
        let mastered = Set(center.runs.filter { $0.destination != nil }.flatMap(\.files).filter { $0.state == .done && $0.moved == nil }.map(\.path))
        return (survey?.files ?? []).map { file in
            var file = file
            if mastered.contains(file.path) { file.skip = String(localized: "Master made") }
            file.projectSettings = choices[file.project] == .k4 ? k4 : nil
            return file
        }
    }

    func kind(_ file: File) -> ShrinkFolders.Kind { overrides[file.path] ?? file.kind }

    /// Why a file is left as it is (nil: it can be shrunk).
    func reason(_ file: File) -> String? {
        if choices[file.project] == .skip { return String(localized: "Skipped") }
        if kind(file) == .deliveries { return String(localized: "Delivery") }
        if let skip = file.skip { return skip }
        if file.tooSmall(settings) { return String(localized: "Already small") }
        if file.tooRecent(months: months) { return String(localized: "Recent project") }
        if kind(file) == .other, !other { return String(localized: "Not sure it’s rushes") }
        return nil
    }

    func chosen(_ file: File) -> Bool { reason(file) == nil && !off.contains(file.project) && !unticked.contains(file.path) }
    var picked: [File] { files.filter(chosen) }

    // MARK: What's shown

    /// The shares the chosen folders are on: what's used and free.
    var shares: [Share] {
        let projects = Array(survey?.projects.values ?? [:].values)
        return Set(projects.map(\.share)).sorted().map { root in
            let used = projects.filter { $0.share == root }.reduce(Int64(0)) { $0 + $1.total }
            let mine = picked.filter { file in survey?.projects[file.project]?.share == root }
            let saving = mine.reduce(Int64(0)) { $0 + $1.size - $1.estimate(settings) } + proxyBytes(of: mine)
            let capacity = (try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
            return Share(path: root, name: (root as NSString).lastPathComponent, used: used, saving: saving,
                         free: OffloadCenter.freeSpace(URL(fileURLWithPath: root)), capacity: capacity)
        }
    }

    /// The proxy and cache folders that go to the to-delete folder with these files' projects (when that's on): part of what's freed.
    func proxyBytes(of files: [File]) -> Int64 {
        guard moveProxies else { return 0 }
        return Set(files.map(\.project)).reduce(Int64(0)) { $0 + (survey?.projects[$1]?.proxies ?? 0) }
    }

    /// Footage found, what the chosen files would save, what earlier runs saved.
    var totals: (footage: Int64, saving: Int64, saved: Int64) {
        let footage = (survey?.projects.values ?? [:].values).reduce(Int64(0)) { $0 + $1.rushes }
        let saving = picked.reduce(Int64(0)) { $0 + $1.size - $1.estimate(settings) } + proxyBytes(of: picked)
        let saved = center.runs.flatMap(\.files).filter { $0.state == .done }.reduce(Int64(0)) { $0 + $1.size - ($1.masterSize ?? 0) }
        return (footage, saving, saved)
    }

    /// Everything that could be shrunk in the last look (whatever's chosen), and the footage found.
    var freeable: (saving: Int64, footage: Int64) {
        let open = files.filter { reason($0) == nil }
        let saving = open.reduce(Int64(0)) { $0 + $1.size - $1.estimate(settings) } + proxyBytes(of: open)
        return (saving, (survey?.projects.values ?? [:].values).reduce(Int64(0)) { $0 + $1.rushes })
    }

    var clients: [Client] {
        let doneFiles = center.runs.flatMap(\.files).filter { $0.state == .done }
        let active = center.active.flatMap(center.run)
        var byProject: [String: [File]] = [:]
        for file in files { byProject[file.project, default: []].append(file) }
        let rows = (survey?.projects.values ?? [:].values).map { project -> ProjectRow in
            let mine = byProject[project.folder] ?? []
            let open = mine.filter { reason($0) == nil }
            let dim: String? = !open.isEmpty ? nil
                : choices[project.folder] == .skip ? String(localized: "skipped")
                : mine.contains { $0.tooRecent(months: months) && kind($0) == .rushes } ? String(localized: "recent")
                : mine.contains { kind($0) == .rushes } ? String(localized: "small") : String(localized: "no rushes")
            return ProjectRow(project: project, saving: open.reduce(Int64(0)) { $0 + $1.size - $1.estimate(settings) } + proxyBytes(of: open), files: open.count,
                              newest: project.newest, selected: !off.contains(project.folder),
                              done: doneFiles.filter { $0.project == project.folder }.count,
                              waiting: active?.files.filter { $0.project == project.folder && ($0.state == .pending || $0.state == .working) }.count ?? 0,
                              dim: dim)
        }
        let sorted: [ProjectRow] = switch order {
        case .saving: rows.sorted { ($0.saving, $0.project.total) > ($1.saving, $1.project.total) }
        case .size: rows.sorted { $0.project.total > $1.project.total }
        case .name: rows.sorted { $0.project.title.localizedStandardCompare($1.project.title) == .orderedAscending }
        }
        var names: [String] = [], groups: [String: [ProjectRow]] = [:]
        for row in sorted {
            if groups[row.project.client] == nil { names.append(row.project.client) }
            groups[row.project.client, default: []].append(row)
        }
        return names.map { Client(name: $0, projects: groups[$0] ?? []) }
    }

    /// Per share: what could be freed, and its projects that would free the most.
    var whereItSits: [(share: String, saving: Int64, projects: [(title: String, saving: Int64)])] {
        var byShare: [String: [(String, Int64)]] = [:]
        for client in clients {
            for row in client.projects where row.saving > 0 { byShare[row.project.share, default: []].append((row.project.title, row.saving)) }
        }
        return byShare.map { share, list in
            ((share as NSString).lastPathComponent, list.reduce(Int64(0)) { $0 + $1.1 }, Array(list.sorted { $0.1 > $1.1 }.prefix(3)))
        }.sorted { $0.saving > $1.saving }
    }

    /// The biggest files that stay as they are, and why (videos left alone, big files that aren't video).
    var untouched: [Untouched] {
        let names = (survey?.projects ?? [:]).mapValues(\.title)
        let videos = files.compactMap { file in reason(file).map { Untouched(path: file.path, size: file.size, project: names[file.project] ?? "", reason: $0) } }
            .filter { $0.size >= ShrinkFolders.bigSize }
        let more = (survey?.big ?? []).map { Untouched(path: $0.path, size: $0.size, project: names[$0.project] ?? "", reason: $0.reason) }
        // (Each file as its newest run left it: skipped once and archived later, it isn't listed.)
        var newest = Set<String>()
        let failed = center.runs.flatMap(\.files).filter { newest.insert($0.path).inserted && ($0.state == .failed || $0.state == .skipped) }
            .map { Untouched(path: $0.path, size: $0.size, project: names[$0.project] ?? "", reason: $0.note ?? "") }
        var seen = Set<String>()
        return (failed + videos + more).filter { seen.insert($0.path).inserted }.sorted { $0.size > $1.size }
    }

    /// The run going: this Mac's part and the always-on Mac's.
    var progress: [Progress] {
        guard let id = center.active, let run = center.run(id) else { return [] }
        let here = run.files.filter { $0.state != .elsewhere }
        var list = [Progress(machine: String(localized: "This Mac"), done: here.filter { $0.state != .pending && $0.state != .working }.count, total: here.count,
                             current: center.current, left: center.timeLeft, waitingForEdit: center.waitingForEdit)]
        let there = run.files.filter { $0.state == .elsewhere }.count
        if there > 0 || following.contains(id) {
            list.append(Progress(machine: String(localized: "Always-on Mac"), done: 0, total: there, current: nil, left: nil, waitingForEdit: false))
        }
        return list
    }

    /// The run going (or paused): its projects, bytes freed of what it should free, per machine.
    var archivingNow: (title: String, freed: Int64, total: Int64, parts: [Progress])? {
        guard let id = center.active ?? center.runs.first(where: center.unfinished)?.id, let run = center.run(id) else { return nil }
        let titles = Array(Set(run.files.map { ShrinkFolders.title(client: $0.client, project: $0.projectName) })).sorted()
        let freed = run.files.filter { $0.state == .done }.reduce(Int64(0)) { $0 + $1.size - ($1.masterSize ?? $1.size) }
        let total = run.files.filter { $0.state != .skipped && $0.state != .failed }.reduce(Int64(0)) { $0 + $1.size - $1.estimate(run.settings) }
        let title = titles.count > 1 ? String(localized: "\(titles[0]) and \(titles.count - 1) more") : (titles.first ?? "")
        return (title, freed, max(total, freed), progress)
    }

    // MARK: Doing

    func appeared() async {
        center.keepAwake = overnight
        for run in center.runs where run.files.contains(where: { $0.state == .elsewhere }) { follow(run.id) }
        officeProblem = await ShrinkRemote.unavailable()
        await refreshSpace()
        // Checks over a week old (or whose master changed) done again before anything shows as safe.
        if !center.running, center.checking == nil, let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") {
            for run in center.runs where run.files.contains(where: { $0.state == .done && $0.checked != nil && !$0.safeNow() && $0.notSafe() == nil }) {
                await center.check(run.id, onlyNew: true, ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
            await refreshSpace()
        }
    }

    /// New Archive: from its first step.
    func newArchive() { screen = .folders }

    /// The next step (looking at the folders first, from the last look when there is one).
    func next() {
        switch screen {
        case .folders: rescan(cached: true); screen = .projects
        case .projects: screen = .settings
        case .settings: start(); screen = .dashboard
        default: screen = .dashboard
        }
    }

    func back() {
        switch screen {
        case .projects: screen = .folders
        case .settings: screen = .projects
        default: screen = .dashboard
        }
    }

    func add(_ folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        keepFolders()
    }

    func remove(_ folder: URL) {
        folders.removeAll { $0 == folder }
        keepFolders()
    }

    /// Reads the folders (`cached`: the last look at these folders, when there is one).
    func rescan(cached: Bool) {
        scan?.cancel()
        scanning = false
        guard let ffprobe = AppDelegate.shared?.manager.tool("ffprobe"), !folders.isEmpty else { survey = nil; return }
        let chosen = folders
        if cached, let saved = ShrinkFolders.savedSurvey(chosen.map { ShrinkFolders.real($0).path }) { survey = saved; return }
        found = 0
        scanning = true
        scan = Task {
            let stop = StopFlag()
            let made = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    ShrinkFolders.survey(chosen, ffprobe: ffprobe, stopped: { stop.value }, found: { count in Task { @MainActor in ArchiveModel.shared.found = count } })
                }.value
            } onCancel: { stop.value = true }
            guard !Task.isCancelled else { return }
            survey = made
            scanning = false
            Task.detached { ShrinkFolders.save(made) }
        }
    }

    func stopScan() { scan?.cancel(); scanning = false }

    /// The owner's correction of a project, kept, and the list sorted anew without reading the share again.
    func correct(_ folder: String, share: String, _ change: (inout ShrinkFolders.Rules, String) -> Void) {
        var rules = ShrinkFolders.Rules.load()
        change(&rules, ShrinkFolders.Rules.key(folder, share: share))
        rules.save()
        if let survey {
            let made = ShrinkFolders.regroup(survey, rules: rules)
            self.survey = made
            ShrinkFolders.save(made)
        }
    }

    func rename(_ project: Project, to name: String) { correct(project.folder, share: project.share) { $0.names[$1] = name.isEmpty ? nil : name } }
    func partOfParent(_ project: Project) { correct(project.folder, share: project.share) { $0.marks[$1] = .part } }
    func isProject(_ folder: String, share: String) { correct(folder, share: share) { $0.marks[$1] = .project } }
    func detectAgain(_ project: Project) { correct(project.folder, share: project.share) { $0.marks[$1] = nil; $0.names[$1] = nil } }

    func select(_ projects: [Project], _ on: Bool) { for project in projects { if on { off.remove(project.folder) } else { off.insert(project.folder) } } }
    func selectAll(_ on: Bool) { off = on ? [] : Set(survey?.projects.keys ?? [:].keys) }

    /// In place, a share with less free space than the run's masters need (×1.2 and headroom): why another folder is better.
    var spaceShort: String? {
        guard destination == nil else { return nil }
        let byShare = Dictionary(grouping: picked) { survey?.projects[$0.project]?.share ?? ShrinkFolders.shareRoot(of: URL(fileURLWithPath: $0.folder)) }
        for (share, list) in byShare.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: share)
            guard let free = OffloadCenter.freeSpace(url) else { continue }
            let need = Int64(Double(list.reduce(Int64(0)) { $0 + $1.estimate(settings) }) * 1.2) + ShrinkFolders.headroom(ShrinkFolders.capacity(url))
            if free < need {
                let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return String(localized: "\((share as NSString).lastPathComponent) has \(bytes(free)) free and the masters need about \(bytes(need)) until you delete the originals: archive to another folder or NAS")
            }
        }
        return nil
    }

    /// Measures the folders to delete on each share (and a recycle bin there) and what's been deleted from them.
    /// Safe to delete: an original (its parts, its sidecars' copies) whose master passed Check Before Deleting, and
    /// a project's proxies once all its masters did; anything else in the folder is not safe (yet).
    func refreshSpace() async {
        let shares = Set((survey?.projects.values ?? [:].values).map(\.share))
        let runs = center.runs
        let moved = runs.flatMap(\.files).filter { ($0.state == .done || $0.state == .working) && $0.moved != nil }
        let holdings = Set(moved.compactMap { $0.moved.flatMap(ShrinkFolders.holdingFolder(of:)) })
        let center = center
        let result = await Task.detached(priority: .utility) { () -> ([Waiting], Int64, [UUID: RunInfo]) in
            var folders = holdings
            for share in shares { folders.insert(ShrinkFolders.holding(for: URL(fileURLWithPath: share))) }
            // Paths below their folder to delete (the folder by its real path).
            func key(_ path: String) -> (String, String)? {
                guard let holding = ShrinkFolders.holdingFolder(of: path) else { return nil }
                return (ShrinkFolders.real(holding).path, String(path.dropFirst(holding.path.count + 1)))
            }
            // (Looked at now: a master deleted, moved or replaced since its check makes its original not safe.)
            var safe: [String: Set<String>] = [:], notSafe: [String: [String: String]] = [:], safeFolders: [String: [String]] = [:], originals: [String: Set<String>] = [:]
            func size(_ path: String) -> Int64? { (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 }
            for file in runs.flatMap(\.files) { if let original = file.moved, let (root, below) = key(original) { originals[root, default: []].insert(below) } }
            for file in moved {
                guard let original = file.moved else { continue }
                let folder0 = (original as NSString).deletingLastPathComponent
                // (Safe also needs the original whole where it waits.)
                let whole = ([original] + file.parts.map { (folder0 as NSString).appendingPathComponent(($0 as NSString).lastPathComponent) }).map(size)
                let intact = !whole.contains { $0 == nil } && whole.reduce(Int64(0)) { $0 + ($1 ?? 0) } == file.size
                var why = file.notSafe(), good = file.safeNow()
                if good, !intact { good = false; why = String(localized: "The original changed") }
                guard good || why != nil else { continue }
                let folder = (original as NSString).deletingLastPathComponent
                for path in [original] + (file.parts + (file.sidecars ?? [])).map({ (folder as NSString).appendingPathComponent(($0 as NSString).lastPathComponent) }) {
                    guard let (root, below) = key(path) else { continue }
                    if good { safe[root, default: []].insert(below) } else { notSafe[root, default: [:]][below] = why }
                }
            }
            for run in runs {
                for (project, proxies) in run.proxyFolders {
                    let masters = run.files.filter { $0.project == project && $0.state == .done }
                    guard !masters.isEmpty, masters.allSatisfy({ $0.safeNow() }) else { continue }
                    for folder in proxies { if let to = run.movedFolders[folder], let (root, below) = key(to) { safeFolders[root, default: []].append(below + "/") } }
                }
            }
            let waiting = folders.sorted { $0.path < $1.path }.compactMap { folder -> Waiting? in
                guard FileManager.default.fileExists(atPath: folder.path), let walk = FileManager.default.enumerator(atPath: folder.path) else { return nil }
                let share = folder.deletingLastPathComponent().path, root = ShrinkFolders.real(folder).path
                var place = Waiting(share: (share as NSString).lastPathComponent, folder: folder, bytes: 0, recycle: ShrinkFolders.recycleBin(share))
                while let below = walk.nextObject() as? String {
                    guard walk.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                    let size = (walk.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                    place.bytes += size
                    // (Finder's and SMB's own: counted, never a reason not to delete.)
                    let last = (below as NSString).lastPathComponent
                    if last == ".DS_Store" || last.hasPrefix("._") { continue }
                    // (Pluck's own lists at its top: neither.)
                    // (Pluck's own lists at its top: neither; never an original that's some run's.)
                    if !below.contains("/"), below == "Inventory.csv" || ShrinkFolders.report(below), originals[root]?.contains(below) != true { continue }
                    if notSafe[root]?[below] == nil, safe[root]?.contains(below) == true || safeFolders[root]?.contains(where: { below.hasPrefix($0) }) == true {
                        place.safe += size
                        if place.safeFiles.count < 500 { place.safeFiles.append(folder.appendingPathComponent(below)) }
                    } else {
                        if let why = notSafe[root]?[below] {
                            place.notSafe += size
                            if place.notSafeFiles.count < 50 { place.notSafeFiles.append("\((below as NSString).lastPathComponent): \(why)") }
                        } else {
                            place.unsafe += size
                        }
                        if place.unsafeFiles.count < 50 { place.unsafeFiles.append(below) }
                    }
                }
                return place
            }
            // shortcut: proxy folders moved and deleted aren't counted (no size kept for them); keep their size in the run if wanted.
            // (Gone from a folder to delete that's there: a share not mounted frees nothing.)
            let freed = moved.filter { file in
                !FileManager.default.fileExists(atPath: file.moved ?? "") && file.moved.flatMap(ShrinkFolders.holdingFolder(of:)).map { FileManager.default.fileExists(atPath: $0.path) } == true
            }.reduce(Int64(0)) { $0 + max($1.size - ($1.masterSize ?? 0), 0) }
            // What the history rows show from the drive (the last 30 runs).
            let history = Dictionary(uniqueKeysWithValues: runs.prefix(30).map { run in
                (run.id, RunInfo(canPutBack: center.canPutBack(run), ready: center.readyToDelete(run), relinkBack: !ShrinkRelink.map([run], back: true).isEmpty))
            })
            return (waiting, freed, history)
        }.value
        (waiting, freedSoFar, history) = result
    }

    /// The files of a folder to delete that are safe right now (looked at again first), for Show in Finder.
    func safeToReveal(_ place: Waiting) async -> [URL] {
        await refreshSpace()
        return waiting.first { $0.id == place.id }?.safeFiles ?? []
    }

    /// Check Before Deleting's results for a run, by project.
    /// (Looked at now; a file whose original waits without its master is not safe too.)
    /// (A file not finished, here or on the other Mac, is a problem of its project; a run not through is never safe.)
    func checks(_ run: ShrinkFolders.Run) -> [ProjectCheck] {
        let mine = run.files.filter { $0.state == .done || ($0.state == .working && ($0.problem != nil || $0.moved != nil)) }
        func title(_ file: File) -> String { file.client.isEmpty ? (file.folder as NSString).lastPathComponent : ShrinkFolders.title(client: file.client, project: file.projectName) }
        // (Per project: one with a file still to do, here or on the other Mac, isn't through; another project's doesn't hold it back.)
        let open = Set(run.files.filter { $0.state == .pending || $0.state == .working || $0.state == .elsewhere }.map(title))
        return Dictionary(grouping: mine, by: title)
            .map { title, files in
                let finished = !open.contains(title)
                let done = files.filter { $0.state == .done }
                return ProjectCheck(title: title, masters: done.count, checked: done.filter { $0.safeNow() || $0.notSafe() != nil }.count,
                                    problems: files.compactMap { file in file.notSafe().map { "\((file.path as NSString).lastPathComponent): \($0)" } },
                                    finished: finished)
            }
            .sorted { $0.title < $1.title }
    }

    /// Check Before Deleting, for a run or for what waits in one share's folder to delete.
    func check(_ run: ShrinkFolders.Run) {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else { return }
        Task {
            if let why = await center.check(run.id, ffmpeg: ffmpeg, ffprobe: ffprobe) { problems.append(why) }
            await refreshSpace()
        }
    }

    func check(_ place: Waiting) {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else { return }
        Task {
            if let why = await center.check(holding: place.folder, ffmpeg: ffmpeg, ffprobe: ffprobe) { problems.append(why) }
            await refreshSpace()
        }
    }

    /// A project's own size (nil: the run's), kept per share like a rename.
    func choose(_ projects: [Project], _ choice: Choice?) {
        var rules = ShrinkFolders.Rules.load()
        var sizes = rules.sizes ?? [:]
        for project in projects { sizes[ShrinkFolders.Rules.key(project.folder, share: project.share)] = choice }
        rules.sizes = sizes.isEmpty ? nil : sizes
        rules.save()
        refreshChoices()
    }

    var canStart: Bool {
        !picked.isEmpty && !center.running && (destination != nil || folders.allSatisfy { FileManager.default.isWritableFile(atPath: $0.path) })
    }

    func start() {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe"), canStart else { return }
        let list = picked.map { var file = $0; file.kind = kind($0); return file }
        let proxies = moveProxies ? Dictionary(uniqueKeysWithValues: Set(list.map(\.project)).map { ($0, survey?.projects[$0]?.proxyFolders ?? []) }) : [:]
        let id = center.add(list, settings: settings, destination: destination, roots: folders.map { ShrinkFolders.real($0).path }, proxies: proxies,
                        months: months)
        let machine = officeProblem == nil ? machine : .here
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
            rescan(cached: false)
            await refreshSpace()
        }
    }

    private func follow(_ id: UUID) {
        guard following.insert(id).inserted else { return }
        Task { await ShrinkRemote.follow(id); following.remove(id) }
    }

    func pause() {
        guard let id = center.active else { return }
        center.pause()
        if center.run(id)?.files.contains(where: { $0.state == .elsewhere }) == true {
            Task { _ = try? await OfficeRenderClient.shared.ask("shrinkStop", ["id": id.uuidString], timeout: 20) }
        }
    }

    func runAnyway() { center.runAnyway = true }

    /// Resume: the always-on Mac's results brought in first; what it hasn't finished is this Mac's again (claims stop double work).
    func resume(_ run: ShrinkFolders.Run) {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else { return }
        Task {
            if run.files.contains(where: { $0.state == .elsewhere }) { _ = await ShrinkRemote.poll(run.id, center: center) }
            center.reclaim(run.id)
            await center.resume(run.id, ffmpeg: ffmpeg, ffprobe: ffprobe)
            await refreshSpace()
        }
    }

    func putBack(_ run: ShrinkFolders.Run) { Task { await center.putBack(run.id); await refreshSpace() } }
    func moveOriginals(_ run: ShrinkFolders.Run) {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else { return }
        Task { problems = await center.moveOriginals(run.id, ffmpeg: ffmpeg, ffprobe: ffprobe); await refreshSpace() }
    }

    /// The folders a run's originals (or masters, in a destination) are in.
    func places(_ run: ShrinkFolders.Run) -> [URL] {
        run.destination.map { [URL(fileURLWithPath: $0)] }
            ?? Array(Set(run.files.filter { $0.state == .done }.compactMap { $0.moved.flatMap(ShrinkFolders.holdingFolder(of:)) }))
    }

    /// The files left alone, as CSV.
    func untouchedCSV() -> String {
        let cell = ShrinkFolders.cell
        return "path,bytes,project,reason\n" + untouched.map { "\(cell($0.path)),\($0.size),\(cell($0.project)),\(cell($0.reason))" }.joined(separator: "\n") + "\n"
    }
}

/// A flag the scan reads from its own thread.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool {
        get { lock.withLock { stopped } }
        set { lock.withLock { stopped = newValue } }
    }
}
