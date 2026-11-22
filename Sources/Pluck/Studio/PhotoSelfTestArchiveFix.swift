import Foundation

/// The 4.0.7 Archive review round (run first by -PluckScreenshotOnly archivewf): a project file that can't be read holds
/// the project (and Deliver never writes over it), Hold looked at right before anything moves, a copy whose original's
/// folder is gone doesn't stop the others, a manifest that can't be read isn't written over, no "checked" second copy
/// on an rclone/FUSE mount, snapshot days for a share below its dataset, measured space after everything's deleted,
/// kept-until days in UTC, no restore temps left, nothing moved while copies run, the run's own second-copy targets,
/// RAW originals this Mac can't read said so, and the MHL's "verified".
extension PhotoSelfTest {
    static func archiveFixTest() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-archivefix-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("FX"), second = base.appendingPathComponent("FXSecond")
        try? fm.createDirectory(at: share, withIntermediateDirectories: true)
        try? fm.createDirectory(at: second, withIntermediateDirectories: true)
        let testVolumes = OfficeGroup.testVolumes, decide = S.decide, fileSystem = S.fileSystem, zone = NSTimeZone.default
        func alias(_ url: URL, _ remount: String) -> [(String, String)] { [(url.path, remount), (url.path.replacingOccurrences(of: "/private/var/", with: "/var/"), remount)] }
        OfficeGroup.testVolumes = alias(share, "smb://test/fx") + alias(second, "smb://test/fxsecond")
        S.decide = { _ in .none }
        defer {
            OfficeGroup.testVolumes = testVolumes; S.decide = decide; S.fileSystem = fileSystem; NSTimeZone.default = zone
            try? fm.removeItem(at: base)
        }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("archive fix: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        func make(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1,noise=alls=3:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=stereo:sample_rates=48000",
                                        "-map", "0:v", "-map", "1:a", "-shortest", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                                        "-c:a", "pcm_s24le", "-timecode", "10:00:00:00", "-f", "mov", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func size(_ path: String?) -> Int64? { path.flatMap { (try? fm.attributesOfItem(atPath: $0))?[.size] as? Int64 } }
        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func scan(_ folder: URL) -> [S.File] { S.scan([folder], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path } }
        func center(_ name: String) -> ShrinkCenter {
            let made = ShrinkCenter(store: base.appendingPathComponent("\(name).json"), mac: "Mac A")
            made.quiet = 0
            made.editing = { _ in false }
            made.editQuiet = 0
            made.trash = { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) }
            return made
        }
        func states(_ files: [S.File]?) -> String {
            (files ?? []).map { "\(($0.path as NSString).lastPathComponent) \($0.state) \($0.note ?? "") \($0.copyProblem ?? "") \($0.problem ?? "") copied \($0.copied != nil)" }.joined(separator: " | ")
        }
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        let projects = share.appendingPathComponent("Projects")
        let holding = share.appendingPathComponent(S.holdingName)
        let cantRead = String(localized: "Project file can’t be read")
        /// A run of a project's clips (made, checked and, with a target decided, copied), or only added (`go` false).
        func archived(_ name: String, clips: [String] = ["A001C001.mov"], destination: URL? = nil, go: Bool = true) async -> (ShrinkCenter, UUID, [URL]) {
            let folder = projects.appendingPathComponent("\(name)/Rushes")
            let urls = clips.map { folder.appendingPathComponent($0) }
            urls.forEach { make($0) }
            let made = center(name)
            let id = made.add(scan(folder), settings: hd, destination: destination, roots: [folder.deletingLastPathComponent().path])
            if go { await made.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe) }
            return (made, id, urls)
        }

        // MARK: 1 A project file that can't be read holds the project

        let badFolder = projects.appendingPathComponent("BadFile"), noRead = projects.appendingPathComponent("NoRead"), noFile = projects.appendingPathComponent("NoFile")
        [badFolder, noRead, noFile].forEach { try? fm.createDirectory(at: $0, withIntermediateDirectories: true) }
        let badText = #"{"hold": tr"#
        try? Data(badText.utf8).write(to: ArchiveProject.url(badFolder.path))
        try? Data(#"{"hold":true}"#.utf8).write(to: ArchiveProject.url(noRead.path))
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: ArchiveProject.url(noRead.path).path)
        let badGate = ArchiveProject.gate(ArchiveProject.read(badFolder.path), months: nil)
        let noReadGate = ArchiveProject.gate(ArchiveProject.read(noRead.path), months: nil)
        let noFileGate = ArchiveProject.gate(ArchiveProject.read(noFile.path), months: nil)
        check("archive fix: a project file that isn't JSON or can't be read holds its project (\"Project file can’t be read\"); none at all holds nothing",
              badGate.reason == cantRead && noReadGate.reason == cantRead && noFileGate.reason == nil && !badGate.ripe,
              "\(badGate) \(noReadGate) \(noFileGate)")
        // Deliver's dates never written over a file that can't be read (its Hold would be gone).
        let wroteBad = DeliverProjectFile.merge(["delivered": "2026-11-01T00:00:00Z"], into: badFolder)
        let wroteNoRead = DeliverProjectFile.merge(["delivered": "2026-11-01T00:00:00Z"], into: noRead)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ArchiveProject.url(noRead.path).path)
        let okFolder = projects.appendingPathComponent("DeliverOK")
        try? fm.createDirectory(at: okFolder, withIntermediateDirectories: true)
        try? Data(#"{"hold":true,"later":1}"#.utf8).write(to: ArchiveProject.url(okFolder.path))
        let wroteOK = DeliverProjectFile.merge(["delivered": "2026-11-01T00:00:00Z"], into: okFolder)
        let okJSON = ArchiveProject.json(okFolder.path) ?? [:]
        check("archive fix: Deliver never writes over a project file it can't read (Hold kept); a good one gets its date, every other key kept",
              !wroteBad && !wroteNoRead && text(ArchiveProject.url(badFolder.path)) == badText && text(ArchiveProject.url(noRead.path)) == #"{"hold":true}"#
              && wroteOK && okJSON["delivered"] as? String == "2026-11-01T00:00:00Z" && okJSON["hold"] as? Bool == true && okJSON["later"] != nil,
              "\(wroteBad) \(wroteNoRead) \(text(ArchiveProject.url(noRead.path)) ?? "nil") \(okJSON)")
        // A run never touches a project whose file can't be read.
        let (badCenter, badID, badClips) = await archived("BadFile")
        let badRunFile = badCenter.run(badID)?.files.first
        check("archive fix: a run leaves a project whose file can't be read as it is (skipped, said, its original where it was)",
              badRunFile?.state == .skipped && badRunFile?.note == cantRead && badRunFile?.moved == nil && fm.fileExists(atPath: badClips[0].path)
              && !fm.fileExists(atPath: S.movedPath(badClips[0].path, holding: holding)), states(badCenter.run(badID)?.files))
        // … nor gives it a second copy.
        let (laterCenter, laterID, _) = await archived("LaterBad")
        try? Data("garbage".utf8).write(to: ArchiveProject.url(projects.appendingPathComponent("LaterBad").path))
        S.decide = { _ in .target(second.path) }
        await laterCenter.secondCopies(laterID)
        S.decide = { _ in .none }
        check("archive fix: no second copy for a project whose file can't be read", laterCenter.run(laterID)?.files.first.map { $0.state == .done && $0.copied == nil } == true,
              states(laterCenter.run(laterID)?.files))

        // MARK: 2 Hold looked at right before anything moves

        let midProject = projects.appendingPathComponent("HoldMid")
        let (midCenter, midID, midClips) = await archived("HoldMid", go: false)
        let midSize = size(midClips[0].path)
        // (Put on hold from another Mac while this one works on it: after the go began, before the original moves.)
        midCenter.editing = { folder in
            if folder.hasPrefix(midProject.path) { ArchiveProject.setHold(midProject.path, true) }
            return false
        }
        await midCenter.resume(midID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let midFile = midCenter.run(midID)?.files.first
        let midLeft = ((try? fm.contentsOfDirectory(atPath: midClips[0].deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(".shrinking-") }
        check("archive fix: put on hold while its master is made, the original isn't moved (skipped, nothing hidden left)",
              midFile?.state == .skipped && midFile?.moved == nil && size(midClips[0].path) == midSize
              && !fm.fileExists(atPath: S.movedPath(midClips[0].path, holding: holding)) && midLeft.isEmpty,
              "\(states(midCenter.run(midID)?.files)) \(midLeft)")
        // A run into another folder: Move Originals and "ready to delete" leave a project on hold.
        let destProject = projects.appendingPathComponent("HoldDest")
        let (destCenter, destID, destClips) = await archived("HoldDest", destination: base.appendingPathComponent("Masters"))
        let readyBefore = destCenter.run(destID).map { destCenter.readyToDelete($0).count } ?? -1
        ArchiveProject.setHold(destProject.path, true)
        let readyHeld = destCenter.run(destID).map { destCenter.readyToDelete($0).count } ?? -1
        _ = await destCenter.moveOriginals(destID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive fix: Move Originals and \"ready to delete\" leave a project on hold (its original where it was)",
              readyBefore == 1 && readyHeld == 0 && destCenter.run(destID)?.files.first?.moved == nil && fm.fileExists(atPath: destClips[0].path),
              "\(readyBefore) \(readyHeld) \(states(destCenter.run(destID)?.files))")
        ArchiveProject.setHold(destProject.path, false)

        // MARK: 10 Nothing moved or checked while copies or a restore run; no restore temps left

        destCenter.copying = destID
        let checkedBefore = destCenter.run(destID)?.files.first?.checked
        _ = await destCenter.moveOriginals(destID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let movedWhileCopying = destCenter.run(destID)?.files.first?.moved != nil
        await destCenter.check(destID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let checkedWhileCopying = destCenter.run(destID)?.files.first?.checked != checkedBefore
        await destCenter.putBack(destID)
        let putBackWhileCopying = destCenter.run(destID)?.files.first?.state != .done
        destCenter.copying = nil
        _ = await destCenter.moveOriginals(destID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive fix: while a second copy or a restore runs, Move Originals, Check and Put Back wait; after it, Move Originals works",
              !movedWhileCopying && !checkedWhileCopying && !putBackWhileCopying && destCenter.run(destID)?.files.first?.moved != nil,
              "\(movedWhileCopying) \(checkedWhileCopying) \(putBackWhileCopying) \(states(destCenter.run(destID)?.files))")

        S.decide = { _ in .target(second.path) }
        let (tempCenter, tempID, tempClips) = await archived("RestoreTemp")
        if let file = tempCenter.run(tempID)?.files.first, let moved = file.moved, let master = file.master, file.copied != nil {
            try? fm.moveItem(atPath: moved, toPath: base.appendingPathComponent("owner-deleted-temp").path)
            if let handle = FileHandle(forUpdatingAtPath: master) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data([1, 2, 3])); try? handle.close() }
            let result = S.restoreFromCopy(file, token: "temp1234", trash: { _ in })
            let left = ((try? fm.contentsOfDirectory(atPath: tempClips[0].deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(".pluck-restoring-") }
            check("archive fix: a restore that can't go in leaves none of its own hidden pieces behind (the file at the master's name left as it is)",
                  result.file.problem != nil && result.file.state == .done && left.isEmpty && size(master) == (file.masterSize ?? 0) + 3, "\(result.file.problem ?? "nil") \(left)")
        } else {
            check("archive fix: restore temps (set up)", false, states(tempCenter.run(tempID)?.files))
        }
        S.decide = { _ in .none }

        // MARK: 6 An original's folder gone (its share mounted) doesn't stop the others' copies

        let sixRushes = projects.appendingPathComponent("Six/Rushes")
        make(sixRushes.appendingPathComponent("A/A001.mov"))
        make(sixRushes.appendingPathComponent("B/B001.mov"))
        let sixCenter = center("six")
        let sixID = sixCenter.add(scan(sixRushes), settings: hd, roots: [sixRushes.deletingLastPathComponent().path])
        await sixCenter.resume(sixID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let sixA = sixCenter.run(sixID)?.files.first { $0.path.hasSuffix("A001.mov") }
        if let moved = sixA?.moved { try? fm.removeItem(atPath: (moved as NSString).deletingLastPathComponent) }
        S.decide = { _ in .target(second.path) }
        await sixCenter.secondCopies(sixID)
        S.decide = { _ in .none }
        let sixAfterA = sixCenter.run(sixID)?.files.first { $0.path.hasSuffix("A001.mov") }
        let sixAfterB = sixCenter.run(sixID)?.files.first { $0.path.hasSuffix("B001.mov") }
        check("archive fix: an original whose folder the owner deleted fails its copy (said); the next original is still copied",
              sixAfterA?.copied == nil && sixAfterA?.copyProblem != nil && sixAfterB?.copied != nil, states(sixCenter.run(sixID)?.files))

        // MARK: 5 A manifest that can't be read is never written over

        let sixManifest = ArchiveCatalog.manifest(projects.appendingPathComponent("Six").path)
        try? Data("[{broken".utf8).write(to: sixManifest)
        await sixCenter.catalogue(sixID, ffmpeg: nil)
        check("archive fix: a catalogue manifest that can't be read is left as it is (not written anew with only this run)",
              text(sixManifest) == "[{broken", text(sixManifest) ?? "nil")

        // MARK: 3 No "checked" second copy on an rclone / FUSE mount

        let (fuseCenter, fuseID, _) = await archived("Fuse")
        var fuseResults: [String] = []
        for stand in [("macfuse", "rclone-remote:"), ("nfs", "fuse-t:/rclone"), ("nfs", "localhost:/rclone")] {
            S.fileSystem = { $0.hasPrefix(second.path) ? (type: stand.0, from: stand.1) : fileSystem($0) }
            if let file = fuseCenter.run(fuseID)?.files.first {
                let result = S.secondCopy(file, target: second, token: "fuse\(fuseResults.count)")
                fuseResults.append("\(stand.0) \(result.file.copied == nil ? "refused" : "copied") \(result.file.copyProblem ?? "")")
            }
        }
        S.fileSystem = fileSystem
        let fuseLeft = (fm.enumerator(atPath: second.appendingPathComponent("FX/Projects/Fuse").path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mov") || $0.contains(".pluck-copying-") }
        check("archive fix: a second copy is never counted as checked on an rclone or FUSE mount (refused, said, nothing written)",
              fuseResults.count == 3 && fuseResults.allSatisfy { $0.contains("refused") && $0.count > 20 } && fuseLeft.isEmpty, "\(fuseResults) \(fuseLeft)")

        // MARK: 7 Snapshot days for a share below its dataset

        let subShares: [[String: Any]] = [["name": "Sub", "path": "/mnt/tank/media/footage/sub"]]
        let subTasks: [[String: Any]] = [["dataset": "tank/media/footage", "recursive": false, "enabled": true, "lifetime_value": 3, "lifetime_unit": "DAY"]]
        check("archive fix: a share that's a folder below its dataset gets the dataset's snapshot days",
              ArchiveSnapshots.days(shares: subShares, tasks: subTasks, share: "sub") == 3, "\(ArchiveSnapshots.days(shares: subShares, tasks: subTasks, share: "sub") ?? -1)")

        // MARK: 8 Measured: all deleted, then a smaller new run starts a new measure

        var marks: [String: ArchiveSnapshots.Mark] = [:]
        _ = ArchiveSnapshots.measured(share: "/z", free: 100, waiting: 50, store: &marks)
        let allGone = ArchiveSnapshots.measured(share: "/z", free: 150, waiting: 0, store: &marks)
        let smaller = ArchiveSnapshots.measured(share: "/z", free: 140, waiting: 10, store: &marks)
        check("archive fix: everything deleted is measured; a new run smaller than before starts a new measure (not counted as deleted)",
              allGone?.deleted == 50 && allGone?.freed == 50 && smaller == nil, "\(String(describing: allGone)) \(String(describing: smaller))")

        // MARK: 9 Kept-until days in UTC, whatever this Mac's time zone

        NSTimeZone.default = TimeZone(identifier: "Europe/Brussels") ?? .current
        let utcFolder = projects.appendingPathComponent("Utc")
        try? fm.createDirectory(at: utcFolder, withIntermediateDirectories: true)
        try? Data(#"{"delivered":"2026-03-01"}"#.utf8).write(to: ArchiveProject.url(utcFolder.path))
        ArchiveProject.setClosed(utcFolder.path, true, months: 6)
        let keptText = ArchiveProject.json(utcFolder.path)?["keepOriginalsUntil"] as? String
        let keptDay = ArchiveProject.keptUntil(ArchiveProject.Info(delivered: ArchiveProject.date("2026-03-01")), months: 6).map(ArchiveProject.dayText)
        NSTimeZone.default = zone
        check("archive fix: delivered 1 March, kept 6 months: until 1 September (UTC days, not this Mac's summer time)",
              keptText == "2026-09-01" && keptDay == "2026-09-01", "\(keptText ?? "nil") \(keptDay ?? "nil")")

        // MARK: 11 "Safe" with the run's own second-copy targets; a RAW original this Mac can't read

        let (ownCenter, ownID, _) = await archived("OwnTargets")
        let ownProject = projects.appendingPathComponent("OwnTargets").path
        // (The always-on Mac's run said: no second copy for this project. This Mac's settings would want one.)
        ownCenter.update(ownID) { $0.copyTargets = [ownProject: ""] }
        S.decide = { _ in .target(second.path) }
        let ownModel = ArchiveModel(center: ownCenter)
        await ownModel.refreshSpace()
        let ownLine = ownCenter.run(ownID).map(ownModel.checks)?.first
        let ownWaiting = ownModel.waiting.first { S.real($0.folder).path == S.real(holding).path }
        S.decide = { _ in .none }
        check("archive fix: \"safe to delete\" goes by the run's own second-copy choice (the same on every Mac)",
              ownLine?.copyNeeded == false && ownLine?.safe == true && ownWaiting?.uncopied == 0 && (ownWaiting?.safe ?? 0) > 0,
              "\(ownLine?.copyNeeded ?? true) \(ownLine?.safe ?? false) \(ownWaiting?.uncopied ?? -1) \(ownWaiting?.safe ?? -1)")
        if var file = ownCenter.run(ownID)?.files.first, let moved = file.moved {
            let raw = (moved as NSString).deletingPathExtension + ".r3d"
            try? fm.copyItem(atPath: moved, toPath: raw)
            file.moved = raw
            let found = S.check(file, ffmpeg: ffmpeg, ffprobe: ffprobe, open: { _ in throw CocoaError(.fileReadUnknown) })
            let rawLine = String(localized: "This Mac can’t read the RAW original: check on a Mac with RAW support")
            check("archive fix: a RAW original this Mac can't read isn't safe, and says to check on a Mac with RAW support",
                  found.problems.contains(rawLine) && !found.problems.contains(String(localized: "The original can’t be read")), "\(found.problems)")
            try? fm.removeItem(atPath: raw)
        }

        // MARK: MHL: a piece already there (same bytes) is "verified"

        let (mhlCenter, mhlID, mhlClips) = await archived("Verified")
        if let moved = mhlCenter.run(mhlID)?.files.first?.moved {
            let place = second.appendingPathComponent("FX/Projects/Verified/Rushes").appendingPathComponent(mhlClips[0].lastPathComponent)
            try? fm.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(atPath: moved, toPath: place.path)
        }
        S.decide = { _ in .target(second.path) }
        await mhlCenter.secondCopies(mhlID)
        S.decide = { _ in .none }
        let mhlFolder = second.appendingPathComponent("FX/Projects/Verified/ascmhl")
        let mhl = ((try? fm.contentsOfDirectory(atPath: mhlFolder.path)) ?? []).filter { $0.hasSuffix(".mhl") }.sorted().last.flatMap { text(mhlFolder.appendingPathComponent($0)) } ?? ""
        check("archive fix: the ASC MHL says \"verified\" for a copy that was already there with the same bytes",
              mhlCenter.run(mhlID)?.files.first?.copied != nil && mhl.contains(#"action="verified""#) && !mhl.contains(#"action="original""#), mhl)
    }
}
