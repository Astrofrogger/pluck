import SwiftUI

/// Shadow clone: the whole project, from its main drive, onto its backup drives. Only what isn't
/// there yet goes, as ordinary offload jobs (one per card folder), so the copying, checking,
/// resuming after a drive drops out and the MHL are the runner's own.
enum OffloadBackup {
    /// A file of the project on the main drive.
    struct Entry: Sendable {
        /// Relative to its part's folder.
        var path: String
        var size: Int64
        var modified: Date
        /// The xxHash64 the offload's MHL has for it (nil when there's none).
        var hash: String?
    }

    /// What's copied as one job: a card's folder (where an offload left its MHL) or, without
    /// one, a folder at the top of the project ("one folder per person" copied by hand).
    struct Part: Sendable {
        /// Relative to the project's folder ("" for the files at its top).
        var folder: String
        var files: [Entry]
    }

    /// The project's folder on a drive.
    static func folder(_ project: OffloadProject, on drive: String) -> URL {
        URL(fileURLWithPath: drive, isDirectory: true).appendingPathComponent(FolderTemplate.safe(project.name), isDirectory: true)
    }

    /// The project on its main drive, by card folder; nil when the main drive isn't connected.
    /// Reads the folder listing and the MHLs, never the files themselves. `skipping`: folders
    /// still being offloaded into (they're backed up once they're done).
    static func parts(of project: OffloadProject, skipping: [String] = []) -> [Part]? {
        guard let main = project.drives.first, FileManager.default.fileExists(atPath: main) else { return nil }
        let root = folder(project, on: main)
        let base = root.standardizedFileURL.path
        let skipped = skipping.compactMap { $0.hasPrefix(base + "/") ? String($0.dropFirst(base.count + 1)) : nil }
        let all = OffloadCenter.files(in: root).filter { file in !skipped.contains { file.path == $0 || file.path.hasPrefix($0 + "/") } }

        // Where offloads left an MHL (beside the files, or in an ascmhl folder): each a card's folder.
        var lists: Set<String> = []
        for file in all where (file.path as NSString).pathExtension.lowercased() == "mhl" {
            var place = (file.path as NSString).deletingLastPathComponent
            if (place as NSString).lastPathComponent == "ascmhl" { place = (place as NSString).deletingLastPathComponent }
            lists.insert(place)
        }
        let hashes = known(in: root, lists: lists)

        var byFolder: [String: [Entry]] = [:]
        for file in all {
            let parts = file.path.split(separator: "/").map(String.init)
            // The outermost folder with an MHL, else the top folder it's in.
            var unit: String?
            for depth in 0..<parts.count where unit == nil {
                let candidate = parts.prefix(depth).joined(separator: "/")
                if lists.contains(candidate) { unit = candidate }
            }
            let folder = unit ?? (parts.count > 1 ? parts[0] : "")
            let path = folder.isEmpty ? file.path : String(file.path.dropFirst(folder.count + 1))
            byFolder[folder, default: []].append(Entry(path: path, size: file.size, modified: file.modified, hash: hashes[file.path]))
        }
        return byFolder.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Part(folder: $0, files: byFolder[$0]!) }
    }

    /// The xxHash64s the MHLs in these folders list, by path in the project.
    private static func known(in root: URL, lists: Set<String>) -> [String: String] {
        var hashes: [String: String] = [:]
        for list in lists {
            for item in MHL.items(in: list.isEmpty ? root : root.appendingPathComponent(list, isDirectory: true)) ?? []
            where ["xxhash64be", "xxh64"].contains(item.kind) && item.hash.count == 16 {
                hashes[list.isEmpty ? item.path : list + "/" + item.path] = item.hash
            }
        }
        return hashes
    }

    /// For each file of each part, whether it's already on the backup: the same size and, where
    /// both MHLs say, the same xxHash64 (else the same date, as offloads skip files).
    private static func there(_ parts: [Part], project: OffloadProject, on drive: URL) -> [[Bool]] {
        let root = folder(project, on: drive.path)
        guard FileManager.default.fileExists(atPath: root.path) else { return parts.map { $0.files.map { _ in false } } }
        let theirs = known(in: root, lists: Set(parts.map(\.folder)))
        return parts.map { part in
            let place = part.folder.isEmpty ? root : root.appendingPathComponent(part.folder, isDirectory: true)
            return part.files.map { file in
                let url = place.appendingPathComponent(file.path)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      Int64(values.fileSize ?? -1) == file.size else { return false }
                if let ours = file.hash, let copy = theirs[part.folder.isEmpty ? file.path : part.folder + "/" + file.path] { return ours == copy }
                guard let date = values.contentModificationDate else { return false }
                return abs(date.timeIntervalSince(file.modified)) < 2
            }
        }
    }

    /// What isn't on the backup yet (nothing when the main drive isn't connected).
    static func pending(project: OffloadProject, to drive: URL, skipping: [String] = []) -> (files: Int, bytes: Int64) {
        guard let parts = parts(of: project, skipping: skipping) else { return (0, 0) }
        var files = 0, bytes: Int64 = 0
        for (part, present) in zip(parts, there(parts, project: project, on: drive)) {
            for (file, here) in zip(part.files, present) where !here {
                files += 1
                bytes += file.size
            }
        }
        return (files, bytes)
    }

    /// The jobs a backup needs, not yet started: a job per card folder with something new,
    /// to every drive at once (`parallel`) or a drive at a time, the first drive's jobs first.
    static func jobs(project: OffloadProject, drives: [URL], parallel: Bool, skipping: [String] = []) -> [OffloadJob] {
        guard let main = project.drives.first, let parts = parts(of: project, skipping: skipping) else { return [] }
        let present = drives.map { there(parts, project: project, on: $0) }
        let source = folder(project, on: main)
        let mainName = OffloadCenter.volumeName(URL(fileURLWithPath: main, isDirectory: true))
        func job(_ index: Int, to chosen: [Int]) -> OffloadJob? {
            let part = parts[index]
            var files: [OffloadFile] = []
            var already = 0
            for (n, file) in part.files.enumerated() {
                let done = chosen.map { present[$0][index][n] }
                if !done.contains(false) { already += 1; continue }
                // The MHL's hash: the copy is checked against what came off the card, not only the main drive.
                files.append(OffloadFile(path: file.path, size: file.size, modified: file.modified, hash: file.hash, done: done))
            }
            guard !files.isEmpty else { return nil }
            let name = FolderTemplate.safe(project.name) + (part.folder.isEmpty ? "" : "/" + part.folder)
            var made = OffloadJob(name: name, source: part.folder.isEmpty ? source.path : source.appendingPathComponent(part.folder).path,
                                  sourceVolume: mainName, roots: chosen.map { drives[$0].path },
                                  rootVolumes: chosen.map { OffloadCenter.volumeName(drives[$0]) }, files: files)
            made.title = String(localized: "Backup · \(part.folder.isEmpty ? project.name : (part.folder as NSString).lastPathComponent)")
            made.backup = project.id
            made.skipped = already > 0 ? already : nil
            return made
        }
        if parallel { return parts.indices.compactMap { job($0, to: Array(drives.indices)) } }
        return drives.indices.flatMap { drive in parts.indices.compactMap { job($0, to: [drive]) } }
    }

    /// Backs the project up onto these drives: only what's new, a job per card folder. A backup
    /// of the same folder to the same drive that's already there carries on instead of starting
    /// twice. Returns the jobs added.
    @MainActor
    static func start(project: OffloadProject, drives: [URL], parallel: Bool) async -> [OffloadJob] {
        let center = OffloadCenter.shared
        guard let main = project.drives.first else { return [] }
        let source = folder(project, on: main)
        let chosen = drives.filter { drive in
            FileManager.default.fileExists(atPath: drive.path) && OffloadCenter.problem(source: source, roots: [drive]) == nil
                && !project.drives.contains(drive.path)
        }
        guard !chosen.isEmpty else { return [] }
        let skipping = center.offloading(into: project.id)
        let planned = await Task.detached(priority: .userInitiated) {
            jobs(project: project, drives: chosen, parallel: parallel, skipping: skipping)
        }.value
        var added: [OffloadJob] = []
        for job in planned {
            let earlier = center.jobs.filter { $0.backup == project.id && $0.finished == nil && $0.source == job.source }
            let covered = Set(earlier.flatMap(\.roots))
            for other in earlier where other.roots.contains(where: job.roots.contains) { center.resume(other.id) }
            guard let kept = job.keeping(job.roots.indices.filter { !covered.contains(job.roots[$0]) }) else { continue }
            center.enqueue(kept)
            added.append(kept)
        }
        return added
    }
}

extension OffloadJob {
    /// The job to only some of its drives (nil when nothing is left to copy there).
    func keeping(_ drives: [Int]) -> OffloadJob? {
        guard !drives.isEmpty else { return nil }
        if drives == Array(roots.indices) { return self }
        var job = self
        job.roots = drives.map { roots[$0] }
        job.rootVolumes = drives.map { rootVolumes[$0] }
        job.files = files.compactMap { file in
            var file = file
            file.done = drives.map { file.done[$0] }
            return file.done.contains(false) ? file : nil
        }
        return job.files.isEmpty ? nil : job
    }
}

// MARK: - Asking

extension OffloadCenter {
    /// "Back up <project> to <drive>?", asked when one of a project's backup drives goes in.
    struct BackupQuestion: Identifiable, Equatable {
        let id = UUID()
        let project: UUID
        let drive: URL
        let files: Int
        let bytes: Int64
    }

    /// Folders still being offloaded into in this project (backed up once they're done).
    func offloading(into project: UUID) -> [String] {
        jobs.filter { $0.project == project && $0.finished == nil }.flatMap(\.targets)
    }

    /// A drive went in: for each project it's a backup drive of, with something new, Pluck asks
    /// (never starts by itself). Asked again the next time it goes in.
    func askToBackUp(_ volume: URL) async {
        let place = volume.standardizedFileURL.path
        for project in OffloadProjects.shared.projects {
            for backup in project.backups where backup == place || backup.hasPrefix(place + "/") {
                // Not while it's already being backed up there.
                let busy = jobs.contains { job in
                    guard job.backup == project.id, job.finished == nil, job.roots.contains(backup) else { return false }
                    switch state(job) {
                    case .queued, .copying, .waiting: return true
                    default: return false
                    }
                }
                guard FileManager.default.fileExists(atPath: backup), !busy,
                      !backupQuestions.contains(where: { $0.project == project.id && $0.drive.path == backup }) else { continue }
                let drive = URL(fileURLWithPath: backup, isDirectory: true)
                let skipping = offloading(into: project.id)
                let new = await Task.detached(priority: .utility) { OffloadBackup.pending(project: project, to: drive, skipping: skipping) }.value
                guard new.files > 0, !backupQuestions.contains(where: { $0.project == project.id && $0.drive.path == backup }) else { continue }
                backupQuestions.append(BackupQuestion(project: project.id, drive: drive, files: new.files, bytes: new.bytes))
                AppDelegate.shared?.manager.notify(title: String(localized: "Back up \(project.name)?"),
                                                   body: String(localized: "\(Self.volumeName(drive)) is waiting in Offload."))
            }
        }
    }

    /// "Back Up": the project onto that drive. "Not Now": asked again when it next goes in.
    func answer(_ question: BackupQuestion, backUp: Bool) async {
        backupQuestions.removeAll { $0.id == question.id }
        guard backUp, let project = OffloadProjects.shared.project(question.project) else { return }
        _ = await OffloadBackup.start(project: project, drives: [question.drive], parallel: false)
    }

    /// A drive went out: nothing is asked about it any more.
    func forgetBackupQuestions(on volume: URL) {
        let place = volume.standardizedFileURL.path
        backupQuestions.removeAll { $0.drive.path == place || $0.drive.path.hasPrefix(place + "/") }
    }

    /// One of a project's backup drives (not a camera card, never offloaded).
    static func isBackupDrive(_ volume: URL) -> Bool {
        let place = volume.standardizedFileURL.path
        return OffloadProjects.shared.projects.contains { $0.backups.contains { $0 == place || $0.hasPrefix(place + "/") } }
    }
}

// MARK: - The page

/// "Back up <project> to <drive>?" with Back Up and Not Now.
struct OffloadBackupQuestionCard: View {
    let question: OffloadCenter.BackupQuestion
    @State private var center = OffloadCenter.shared

    var body: some View {
        let name = OffloadProjects.shared.project(question.project)?.name ?? ""
        Card {
            CardHeader(symbol: "externaldrive.badge.timemachine",
                       title: Text("Back up \(name) to \(OffloadCenter.volumeName(question.drive))?"),
                       subtitle: Text("\(ByteCountFormatter.string(fromByteCount: question.bytes, countStyle: .file)) new")) {
                HStack(spacing: Design.Spacing.controls) {
                    Button("Not Now") { Task { await center.answer(question, backUp: false) } }
                        .buttonStyle(.bordered)
                    Button("Back Up") { Task { await center.answer(question, backUp: true) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// "Back Up Project": the project's backup drives to choose from, with what's new on each, one
/// after another or all at once.
struct OffloadBackupButton: View {
    let project: OffloadProject
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Label("Back Up Project", systemImage: "externaldrive.badge.timemachine") }
            .buttonStyle(.borderless)
            .help("Copies the whole project to backup drives: only what isn’t there yet, every file checked")
            .popover(isPresented: $showing, arrowEdge: .bottom) { OffloadBackupChooser(project: project) { showing = false } }
    }
}

private struct OffloadBackupChooser: View {
    let project: OffloadProject
    let close: () -> Void
    @State private var chosen: Set<String> = []
    @State private var parallel = false
    /// What's new on each connected drive (missing while it's worked out).
    @State private var pending: [String: (files: Int, bytes: Int64)] = [:]
    @State private var starting = false

    private var drives: [String] { OffloadProjects.shared.project(project.id)?.backups ?? project.backups }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.controls) {
            Text("Back Up Project").font(.headline)
            ForEach(drives, id: \.self) { path in
                let connected = FileManager.default.fileExists(atPath: path)
                let new = pending[path]
                Toggle(isOn: Binding(get: { chosen.contains(path) }, set: { if $0 { chosen.insert(path) } else { chosen.remove(path) } })) {
                    HStack {
                        Label(OffloadCenter.volumeName(URL(fileURLWithPath: path)), systemImage: "externaldrive")
                        Spacer()
                        Group {
                            if !connected { Text("Not connected") }
                            else if let new { Text(new.files == 0 ? String(localized: "Up to date")
                                                   : String(localized: "\(ByteCountFormatter.string(fromByteCount: new.bytes, countStyle: .file)) new")) }
                            else { ProgressView().controlSize(.small) }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!connected || new?.files == 0)
                .help(path)
            }
            Button("Add a Backup Drive…", systemImage: "plus", action: addDrive)
                .buttonStyle(.borderless)
            if chosen.count > 1 {
                Picker("", selection: $parallel) {
                    Text("One by One").tag(false)
                    Text("All at Once").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Back Up") {
                    starting = true
                    Task {
                        let latest = OffloadProjects.shared.project(project.id) ?? project
                        _ = await OffloadBackup.start(project: latest, drives: drives.filter(chosen.contains).map { URL(fileURLWithPath: $0, isDirectory: true) }, parallel: parallel)
                        close()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || starting)
            }
        }
        .font(.callout)
        .padding(Design.Spacing.inset)
        .frame(width: 320)
        .task(id: drives) { await work() }
    }

    /// What's new on each connected drive; those with something new are chosen.
    private func work() async {
        let latest = OffloadProjects.shared.project(project.id) ?? project
        let skipping = OffloadCenter.shared.offloading(into: project.id)
        for path in drives where FileManager.default.fileExists(atPath: path) && pending[path] == nil {
            let drive = URL(fileURLWithPath: path, isDirectory: true)
            let new = await Task.detached(priority: .userInitiated) { OffloadBackup.pending(project: latest, to: drive, skipping: skipping) }.value
            pending[path] = new
            if new.files > 0 { chosen.insert(path) }
        }
    }

    /// Another drive, kept as one of the project's backups.
    private func addDrive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url, !drives.contains(url.path), !project.drives.contains(url.path) else { return }
        OffloadProjects.shared.change(project.id) { $0.backups.append(url.path) }
    }
}
