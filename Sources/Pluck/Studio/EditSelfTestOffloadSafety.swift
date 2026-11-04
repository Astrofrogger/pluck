import Foundation

/// The copy engine itself: xxHash64 against known values, a copy cut short carrying on, nothing
/// written over, and never "safe" when it isn't (a folder that can't be read, a file already
/// there not read, a card freed with a file that failed). On folders in a temporary folder.
extension EditSelfTest {
    static func offloadSafety() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-offload-safety-\(UUID().uuidString)", isDirectory: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        xxh64Vectors()
        await resumesAndWritesNothingOver(base)
        await alreadyThereIsRead(base)
        await unreadableFolderRefuses(base)
        await cascadeWithFailureKeepsCard(base)
        for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    private static func safetyFile(_ data: Data, _ path: String, in folder: URL) {
        let url = folder.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func xxh64(_ data: Data) -> String {
        var hasher = XXH64()
        data.withUnsafeBytes { hasher.update($0) }
        return String(format: "%016llx", hasher.digest())
    }

    /// The newest job, once it's done or stopped (nil after 60 s).
    private static func settledJob(_ id: UUID?) async -> OffloadJob? {
        guard let id else { return nil }
        for _ in 0..<1200 {
            if let job = OffloadCenter.shared.jobs.first(where: { $0.id == id }) {
                switch OffloadCenter.shared.state(job) {
                case .done, .stopped: return job
                default: break
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Known values, worked out with the reference algorithm in xxHash's spec
    /// (doc/xxhash_spec.md, seed 0): "" and "abc" are the spec's own; 0…99 fed in two uneven pieces.
    private static func xxh64Vectors() {
        let empty = xxh64(Data()), abc = xxh64(Data("abc".utf8))
        var pieces = XXH64()
        let bytes = Data((0..<100).map { UInt8($0) })
        bytes.prefix(7).withUnsafeBytes { pieces.update($0) }
        bytes.dropFirst(7).withUnsafeBytes { pieces.update($0) }
        let hundred = String(format: "%016llx", pieces.digest())
        check("xxhash64 known values", empty == "ef46db3751d8e999" && abc == "44bc2cf5ad770999" && hundred == "6ac1e58032166597"
              && xxh64(bytes) == hundred,
              "empty \(empty), abc \(abc), 0…99 \(hundred)")
    }

    /// Two drives; on the first a copy cut short mid-file (a .pluckpart), on the second a file
    /// that's already there and the same, and one with the same name that's different. The cut
    /// copy carries on in its own file, every hash matches, and nothing on a drive is written over.
    private static func resumesAndWritesNothingOver(_ base: URL) async {
        let fm = FileManager.default
        let card = base.appendingPathComponent("Card Resume", isDirectory: true)
        let one = base.appendingPathComponent("Drive One", isDirectory: true), two = base.appendingPathComponent("Drive Two", isDirectory: true)
        for folder in [one, two] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let big = Data((0..<(24 << 20) + 3).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let same = Data("the same on the card and the drive".utf8), different = Data("the card's own".utf8)
        safetyFile(big, "CLIP/BIG.MOV", in: card)
        safetyFile(same, "CLIP/SAME.MOV", in: card)
        safetyFile(different, "CLIP/OTHER.MOV", in: card)
        let name = "Resume"
        // Cut short at 20 MB, on the first drive.
        let part = one.appendingPathComponent("\(name)/CLIP/.BIG.MOV.pluckpart")
        safetyFile(big.prefix(20 << 20), "\(name)/CLIP/.BIG.MOV.pluckpart", in: one)
        let partNumber = (try? fm.attributesOfItem(atPath: part.path))?[.systemFileNumber] as? Int
        // Already on the second drive: one the same, one not.
        safetyFile(same, "\(name)/CLIP/SAME.MOV", in: two)
        let theirs = Data("a different file, kept".utf8)
        safetyFile(theirs, "\(name)/CLIP/OTHER.MOV", in: two)
        let sameNumber = (try? fm.attributesOfItem(atPath: two.appendingPathComponent("\(name)/CLIP/SAME.MOV").path))?[.systemFileNumber] as? Int

        let problem = await OffloadCenter.shared.add(source: card, roots: [one, two], name: name)
        let job = problem == nil ? await settledJob(OffloadCenter.shared.jobs.first?.id) : nil
        func data(_ drive: URL, _ path: String) -> Data? { try? Data(contentsOf: drive.appendingPathComponent("\(name)/\(path)")) }
        func number(_ drive: URL, _ path: String) -> Int? {
            (try? fm.attributesOfItem(atPath: drive.appendingPathComponent("\(name)/\(path)").path))?[.systemFileNumber] as? Int
        }
        let file = { (path: String) in job?.files.first { $0.path == path } }
        let resumed = data(one, "CLIP/BIG.MOV") == big && data(two, "CLIP/BIG.MOV") == big && partNumber != nil
            && number(one, "CLIP/BIG.MOV") == partNumber && !fm.fileExists(atPath: part.path)
        let hashes = file("CLIP/BIG.MOV")?.hash == xxh64(big) && file("CLIP/SAME.MOV")?.hash == xxh64(same)
            && file("CLIP/BIG.MOV")?.done == [true, true] && file("CLIP/SAME.MOV")?.done == [true, true]
        let kept = data(two, "CLIP/OTHER.MOV") == theirs && file("CLIP/OTHER.MOV")?.problem != nil && file("CLIP/OTHER.MOV")?.done == [true, false]
            && number(two, "CLIP/SAME.MOV") == sameNumber
        check("a cut copy carries on, nothing written over", problem == nil && resumed && hashes && kept,
              "problem \(problem ?? "none"), resumed in its own file \(resumed), hashes \(hashes), other drive's files kept \(kept)")
    }

    /// Files already on every drive (same name, size and date) are still read on both sides,
    /// hashed and listed in the MHL; one changed on the drive is found, not passed.
    private static func alreadyThereIsRead(_ base: URL) async {
        let fm = FileManager.default
        let card = base.appendingPathComponent("Card There", isDirectory: true), drive = base.appendingPathComponent("Drive There", isDirectory: true)
        let files = (1...3).map { Data("clip \($0) ".utf8) + Data(repeating: UInt8($0), count: 50_000) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (n, content) in files.enumerated() {
            for (folder, path) in [(card, "C\(n).MP4"), (drive, "There/C\(n).MP4")] {
                safetyFile(content, path, in: folder)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent(path).path)
            }
        }
        // The third is damaged on the drive: same size and date, different bytes.
        var damaged = files[2]
        damaged[10] ^= 0xFF
        try? damaged.write(to: drive.appendingPathComponent("There/C2.MP4"))
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: drive.appendingPathComponent("There/C2.MP4").path)

        let problem = await OffloadCenter.shared.add(source: card, roots: [drive], name: "There")
        let job = problem == nil ? await settledJob(OffloadCenter.shared.jobs.first?.id) : nil
        let listed = MHL.items(in: drive.appendingPathComponent("There")) ?? []
        let hashed = (0...1).allSatisfy { n in
            job?.files.first { $0.path == "C\(n).MP4" }?.hash == xxh64(files[n]) && listed.contains { $0.path == "C\(n).MP4" && $0.hash == xxh64(files[n]) }
        }
        let found = job?.files.first { $0.path == "C2.MP4" }?.problem != nil && !listed.contains { $0.path == "C2.MP4" }
        check("files already there are read and hashed", problem == nil && job?.skipped == 3 && hashed && found && job?.cardIsFree == false,
              "problem \(problem ?? "none"), skipped \(job?.skipped ?? -1), hashed and in the MHL \(hashed), damaged one found \(found)")
    }

    /// A folder on the card that can't be read: nothing starts (for a plain offload, a card into
    /// a project, and a project's backup), and the message names it.
    private static func unreadableFolderRefuses(_ base: URL) async {
        let fm = FileManager.default
        let card = base.appendingPathComponent("Card Locked", isDirectory: true), drive = base.appendingPathComponent("Drive Locked", isDirectory: true)
        let locked = card.appendingPathComponent("DCIM/101LOCK", isDirectory: true)
        safetyFile(Data("open".utf8), "DCIM/100OPEN/C0001.MP4", in: card)
        safetyFile(Data("locked".utf8), "DCIM/101LOCK/C0002.MP4", in: card)
        try? fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let center = OffloadCenter.shared
        let jobs = center.jobs.count
        let plain = await center.add(source: card, roots: [drive], name: "Locked")

        var project = OffloadProject(name: "Self Test Locked")
        project.drives = [drive.path]
        project.operators = [OffloadProject.Operator(name: "Operator A", letter: "A")]
        OffloadProjects.shared.save(project)
        defer { OffloadProjects.shared.remove(project.id) }
        let into = await center.add(card: card, project: project.id, operator: project.operators[0].id, camera: CameraCard(brand: "Camera"))

        // A project's main drive with a folder that can't be read: no backup.
        let main = base.appendingPathComponent("Main Locked", isDirectory: true), backup = base.appendingPathComponent("Backup Locked", isDirectory: true)
        var backed = OffloadProject(name: "Self Test Locked Backup")
        backed.drives = [main.path]
        backed.backups = [backup.path]
        let lockedPart = OffloadBackup.folder(backed, on: main.path).appendingPathComponent("B_Locked", isDirectory: true)
        safetyFile(Data("a".utf8), "A001/C0001.MP4", in: OffloadBackup.folder(backed, on: main.path))
        safetyFile(Data("b".utf8), "B_Locked/C0002.MP4", in: OffloadBackup.folder(backed, on: main.path))
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedPart.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedPart.path) }
        let pending = await Task.detached { OffloadBackup.pending(project: backed, to: backup) }.value
        let started = await OffloadBackup.start(project: backed, drives: [backup], parallel: false)

        let named = [plain, into].allSatisfy { $0?.contains("101LOCK") == true }
        check("a folder that can't be read stops the offload", named && center.jobs.count == jobs && pending.unreadable?.contains("B_Locked") == true
              && pending.files == 0 && started.isEmpty,
              "plain \(plain ?? "started"), project \(into ?? "started"), backup \(pending.unreadable ?? "no problem") \(started.count) jobs")
    }

    /// A card that cascades with a file that fails isn't freed (or ejected); only its video isn't either.
    private static func cascadeWithFailureKeepsCard(_ base: URL) async {
        let fm = FileManager.default
        let card = base.appendingPathComponent("Card Cascade", isDirectory: true)
        let one = base.appendingPathComponent("Cascade One", isDirectory: true), two = base.appendingPathComponent("Cascade Two", isDirectory: true)
        for folder in [one, two] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for n in 1...3 { safetyFile(Data(repeating: UInt8(n), count: 10_000), "C000\(n).MP4", in: card) }
        safetyFile(Data("photo".utf8), "IMG_0001.JPG", in: card)
        let unreadable = card.appendingPathComponent("C0002.MP4")
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let problem = await OffloadCenter.shared.add(source: card, roots: [one, two], name: "Cascade", cascade: true)
        let failed = problem == nil ? await settledJob(OffloadCenter.shared.jobs.first?.id) : nil
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        let partial = await OffloadCenter.shared.add(source: card, roots: [one, two], name: "Cascade Video", cascade: true, onlyVideo: true)
        let video = partial == nil ? await settledJob(OffloadCenter.shared.jobs.first?.id) : nil
        check("a card with a failed file isn't freed", failed?.problems.count == 1 && failed?.cardDone == nil && failed?.finished != nil
              && video?.problems.isEmpty == true && video?.files.count == 3 && video?.cardDone == nil,
              "failed: \(failed?.problems.count ?? -1) problems, freed \(failed?.cardDone != nil); only video: \(video?.files.count ?? -1) files, freed \(video?.cardDone != nil)")
    }
}
