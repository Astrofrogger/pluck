import Foundation

/// Shadow clone (Task 5): only what's new goes to a backup drive, a backup carries on after its
/// drive drops out, and a backup drive going in only asks; drives are folders in a temporary folder.
extension EditSelfTest {
    static func offloadBackup() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-offload-backup-\(UUID().uuidString)", isDirectory: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        await backupOnlyNew(base)
        await backupResumes(base)
        await backupAsks(base)
        // The throwaway projects, jobs and drives aren't kept.
        let center = OffloadCenter.shared
        for project in OffloadProjects.shared.projects where project.name.hasPrefix("Self Test Backup") {
            for question in center.backupQuestions where question.project == project.id { await center.answer(question, backUp: false) }
            OffloadProjects.shared.remove(project.id)
        }
        for job in center.jobs where !before.contains(job.id) { center.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Made up

    private static func backupProject(_ name: String, main: URL, backups: [URL]) -> OffloadProject {
        var project = OffloadProject(name: name)
        project.drives = [main.path]
        project.backups = backups.map(\.path)
        project.operators = [OffloadProject.Operator(name: "Operator A", letter: "A")]
        for drive in [main] + backups { try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true) }
        OffloadProjects.shared.save(project)
        return project
    }

    private static func backupFile(_ data: Data, _ path: String, in folder: URL) {
        let url = folder.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// A job once it's done (nil after 60 s).
    private static func backupDone(_ id: UUID?) async -> OffloadJob? {
        guard let id else { return nil }
        for _ in 0..<600 {
            if let job = OffloadCenter.shared.jobs.first(where: { $0.id == id }), OffloadCenter.shared.state(job) == .done { return job }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The files of a folder, by path and size.
    private static func listing(_ folder: URL) -> [String: Int64] {
        Dictionary(OffloadCenter.files(in: folder).map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Checks

    /// Two cards in the project, the first already on the backup: only the second is new.
    private static func backupOnlyNew(_ base: URL) async {
        let main = base.appendingPathComponent("Main", isDirectory: true), backup = base.appendingPathComponent("Backup", isDirectory: true)
        let made = backupProject("Self Test Backup", main: main, backups: [backup])
        let person = made.operators[0].id
        var cards: [OffloadJob] = []
        for (n, count) in [(1, 6), (2, 5)] {
            let card = base.appendingPathComponent("Card \(n)")
            for clip in 1...count {
                backupFile(Data(("card \(n) clip \(clip) " + String(repeating: "\(clip)", count: 3000 + clip * 7)).utf8),
                           String(format: "DCIM/100MEDIA/C%04d.MP4", clip), in: card)
            }
            let problem = await OffloadCenter.shared.add(card: card, project: made.id, operator: person, camera: CameraCard(brand: "Camera"))
            guard problem == nil, let job = await backupDone(OffloadCenter.shared.jobs.first?.id) else {
                return check("backup copies only what's new", false, "card \(n): \(problem ?? "didn't finish")")
            }
            cards.append(job)
        }
        // The card reports are written a moment after: waited for, so the counts don't move.
        for _ in 0..<100 where cards.contains(where: { OffloadReport.url($0) == nil }) { try? await Task.sleep(for: .milliseconds(100)) }
        guard let first = cards.first?.targets.first, let second = cards.last?.targets.first else { return }
        let relative = { (path: String) in String(path.dropFirst(main.path.count + 1)) }
        let copied = backup.appendingPathComponent(relative(first))
        try? FileManager.default.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: first), to: copied)

        let expected = listing(URL(fileURLWithPath: second))
        let pending = await Task.detached { OffloadBackup.pending(project: made, to: backup) }.value
        let started = await OffloadBackup.start(project: made, drives: [backup], parallel: false)
        let job = await backupDone(started.first?.id)
        let after = await Task.detached { OffloadBackup.pending(project: made, to: backup) }.value
        let again = await OffloadBackup.start(project: made, drives: [backup], parallel: false)
        let project = OffloadBackup.folder(made, on: main.path)
        let mainFiles = listing(project), backupFiles = listing(OffloadBackup.folder(made, on: backup.path))
        let everything = mainFiles.allSatisfy { backupFiles[$0.key] == $0.value }
        let listed = MHL.items(in: backup.appendingPathComponent(relative(second)))?.count ?? 0
        check("backup copies only what's new",
              pending.files == expected.count && pending.bytes == expected.values.reduce(0, +) && started.count == 1
                && started.first?.title == "Backup · A002" && job?.problems.isEmpty == true && job?.files.count == expected.count
                && everything && after.files == 0 && again.isEmpty && listed >= 5,
              "\(expected.count) new (card 2 only), one job, all there and checked; got pending \(pending.files)/\(pending.bytes), "
                + "\(started.count) jobs \(started.first?.title ?? ""), done \(job != nil), problems \(job?.problems.count ?? -1), "
                + "everything \(everything), after \(after.files), again \(again.count), MHL \(listed)")
        check("backup isn't a card", job?.project == nil && job?.backup == made.id && job?.cascade != true && job?.quick != true
              && OffloadWrap.stats(project: made, jobs: OffloadCenter.shared.jobs, days: nil).cards == 2,
              "not counted in the wrap; got \(OffloadWrap.stats(project: made, jobs: OffloadCenter.shared.jobs, days: nil).cards) cards")
    }

    /// Stopped halfway and its drive gone, then back: it finishes, copying only what was left.
    private static func backupResumes(_ base: URL) async {
        let main = base.appendingPathComponent("Main Resume", isDirectory: true)
        let backup = base.appendingPathComponent("Backup Resume", isDirectory: true), away = base.appendingPathComponent("Backup Resume Away")
        let made = backupProject("Self Test Backup Resume", main: main, backups: [backup])
        let folder = OffloadBackup.folder(made, on: main.path)
        let count = 40, size = 2 << 20
        for n in 1...count { backupFile(Data(repeating: UInt8(n), count: size), String(format: "A_Operator A/CLIP%03d.MOV", n), in: folder) }
        let center = OffloadCenter.shared
        let started = await OffloadBackup.start(project: made, drives: [backup], parallel: false)
        guard let id = started.first?.id else { return check("backup resumes", false, "no job") }
        func job() -> OffloadJob? { center.jobs.first { $0.id == id } }
        func done() -> Int { job()?.files.filter { !$0.done.contains(false) }.count ?? 0 }
        for _ in 0..<5000 where done() < 8 && job()?.finished == nil { try? await Task.sleep(for: .milliseconds(2)) }
        center.pause(id)
        for _ in 0..<500 where job().map(center.state) == .copying { try? await Task.sleep(for: .milliseconds(10)) }
        let atPause = done()
        guard job()?.finished == nil, atPause < count else { return check("backup resumes", false, "finished before it could be stopped") }
        // Each copy by its file number on the disk: one written again gets a new one.
        let copies = OffloadBackup.folder(made, on: backup.path).appendingPathComponent("A_Operator A")
        func numbers() -> [Int: Int] {
            var found: [Int: Int] = [:]
            for n in 1...count {
                let path = copies.appendingPathComponent(String(format: "CLIP%03d.MOV", n)).path
                if let number = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int { found[n] = number }
            }
            return found
        }
        let before = numbers()

        // The drive gone: it waits for it.
        try? FileManager.default.moveItem(at: backup, to: away)
        center.resume(id)
        var waited = false
        for _ in 0..<100 where !waited {
            if case .waiting = job().map(center.state) { waited = true } else { try? await Task.sleep(for: .milliseconds(50)) }
        }
        // Back: on from where it was.
        try? FileManager.default.moveItem(at: away, to: backup)
        center.resume(id)
        let finished = await backupDone(id)
        let after = numbers()
        let again = (1...count).filter { before[$0] == nil || before[$0] != after[$0] }.count
        let left = count - atPause
        let all = after.count == count
        check("backup resumes", waited && finished?.problems.isEmpty == true && all && again <= left && again >= left - 1 && atPause > 0
              && before.count >= atPause,
              "waited for the drive, then copied only the \(left) left (\(left * size / 1_048_576) MB); got waited \(waited), "
                + "finished \(finished != nil), all \(all), copied again \(again) of \(count), \(atPause) done at the stop")
    }

    /// A backup drive going in asks (once), and nothing starts; Not Now asks again next time.
    private static func backupAsks(_ base: URL) async {
        let main = base.appendingPathComponent("Main Ask", isDirectory: true)
        let volume = base.appendingPathComponent("Ask Volume", isDirectory: true)
        let made = backupProject("Self Test Backup Ask", main: main, backups: [volume.appendingPathComponent("Backups", isDirectory: true)])
        for n in 1...3 { backupFile(Data(repeating: UInt8(n), count: 1000 * n), "A_Operator A/CLIP00\(n).MOV", in: OffloadBackup.folder(made, on: main.path)) }
        let other = base.appendingPathComponent("Other Volume", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let center = OffloadCenter.shared
        let jobs = center.jobs.count
        func asked() -> [OffloadCenter.BackupQuestion] { center.backupQuestions.filter { $0.project == made.id } }

        await center.askToBackUp(other)
        let none = asked().isEmpty
        await center.askToBackUp(volume)
        await center.askToBackUp(volume)
        let first = asked()
        let started = center.jobs.count != jobs
        if let question = first.first { await center.answer(question, backUp: false) }
        let dismissed = asked().isEmpty && center.jobs.count == jobs
        await center.askToBackUp(volume)
        let again = asked().count
        check("backup asks, never starts by itself",
              none && first.count == 1 && first.first?.files == 3 && first.first?.bytes == 6000 && !started && dismissed && again == 1
                && center.jobs.count == jobs,
              "one question (3 files, 6 KB), no job, asked again after Not Now; got other drive \(!none), \(first.count) questions "
                + "\(first.first?.files ?? -1)/\(first.first?.bytes ?? -1), job started \(started), dismissed \(dismissed), again \(again)")
    }
}
