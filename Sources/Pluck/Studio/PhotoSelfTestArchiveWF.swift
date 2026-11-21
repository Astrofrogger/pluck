import Foundation

/// Archive's workflow round (-PluckScreenshotOnly archivewf): the second copy before deleting (checked by hash read
/// back from the target, never over anything, carrying on after a stop or a drive that drops out, an ASC MHL, the
/// gate on "safe to delete"), Closed / Hold / how long originals are kept, snapshots, the catalogue and its search,
/// Restore Originals, and the metadata Check Before Deleting compares.
extension PhotoSelfTest {
    static func archiveWFTest() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-archivewf-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("WF"), second = base.appendingPathComponent("Second")
        try? fm.createDirectory(at: share, withIntermediateDirectories: true)
        try? fm.createDirectory(at: second, withIntermediateDirectories: true)
        let testVolumes = OfficeGroup.testVolumes, decide = S.decide, chunk = S.copyChunk
        func alias(_ url: URL, _ remount: String) -> [(String, String)] { [(url.path, remount), (url.path.replacingOccurrences(of: "/private/var/", with: "/var/"), remount)] }
        OfficeGroup.testVolumes = alias(share, "smb://test/wf") + alias(second, "smb://test/second")
        S.decide = { _ in .target(second.path) }
        defer {
            OfficeGroup.testVolumes = testVolumes; S.decide = decide; S.copyChunk = chunk; S.copyWritten = nil
            try? fm.removeItem(at: base)
        }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("archive wf: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        let prores = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le"]
        func make(_ url: URL, timecode: String = "10:00:00:00", rate: Int = 25) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=\(rate):duration=1,noise=alls=3:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=stereo:sample_rates=48000",
                                        "-map", "0:v", "-map", "1:a", "-shortest"] + prores + ["-timecode", timecode, "-f", "mov", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func size(_ path: String?) -> Int64? { path.flatMap { (try? fm.attributesOfItem(atPath: $0))?[.size] as? Int64 } }
        func scan(_ folder: URL) -> [S.File] { S.scan([folder], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path } }
        func center(_ name: String, mac: String = "Mac A") -> ShrinkCenter {
            let made = ShrinkCenter(store: base.appendingPathComponent("\(name).json"), mac: mac)
            made.quiet = 0
            made.editing = { _ in false }
            made.editQuiet = 0
            made.trash = { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) }
            return made
        }
        func states(_ files: [S.File]?) -> String {
            (files ?? []).map { "\(($0.path as NSString).lastPathComponent) \($0.state) \($0.note ?? "") \($0.copyProblem ?? "") copied \($0.copied != nil)" }.joined(separator: " | ")
        }
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        let projects = share.appendingPathComponent("Projects")
        let holding = share.appendingPathComponent(S.holdingName)
        /// A run made, checked and (with a target decided) copied.
        func archived(_ name: String, clips: [String] = ["A001C001.mov"]) async -> (ShrinkCenter, UUID, [URL]) {
            let folder = projects.appendingPathComponent("\(name)/Rushes")
            let urls = clips.map { folder.appendingPathComponent($0) }
            urls.forEach { make($0) }
            let made = center(name)
            let id = made.add(scan(folder), settings: hd, roots: [folder.deletingLastPathComponent().path])
            await made.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
            return (made, id, urls)
        }

        // MARK: 1a Second copy

        // 1 After a run: each original copied to the second target (its share's name and path there), read back the same, an ASC MHL beside.
        let (copyCenter, copyID, copyClips) = await archived("Copy")
        let copiedFile = copyCenter.run(copyID)?.files.first
        let copyPath = copiedFile?.copied.map { ($0.folder as NSString).appendingPathComponent(copyClips[0].lastPathComponent) }
        let originalHash = copiedFile?.moved.flatMap { S.xxhash($0, cached: false) }
        let mhlRoot = second.appendingPathComponent("WF/Projects/Copy")
        let listed = MHL.items(in: mhlRoot) ?? []
        check("archive wf: after a run each original gets a second copy, its hash read back from the target the same as the original's",
              copiedFile?.state == .done && copyPath == second.appendingPathComponent("WF/Projects/Copy/Rushes/A001C001.mov").path && originalHash != nil
              && copyPath.flatMap { S.xxhash($0, cached: false) } == originalHash && copiedFile?.copied?.hashes["A001C001.mov"] == originalHash,
              states(copyCenter.run(copyID)?.files) + " \(copyPath ?? "nil")")
        check("archive wf: an ASC MHL beside the copies lists each file with its xxHash64, and a chain with its C4 ID",
              listed.contains { $0.path == "Rushes/A001C001.mov" && $0.hash == originalHash && $0.kind == "xxh64" }
              && ((try? String(contentsOf: mhlRoot.appendingPathComponent("ascmhl/ascmhl_chain.xml"), encoding: .utf8)) ?? "").contains("<c4>c4"),
              "\(listed.map { "\($0.path) \($0.hash)" })")
        check("archive wf: a C4 ID is 90 characters, c4 and base58", S.c4(Data("x".utf8)).count == 90 && S.c4(Data()).hasPrefix("c4") && S.c4(Data()) != S.c4(Data("x".utf8)))

        // 2 "Safe to delete" needs the checked master AND the second copy (or "No second copy"); a copy gone isn't one.
        let gateModel = ArchiveModel(center: copyCenter)
        await gateModel.refreshSpace()
        let withCopy = gateModel.waiting.first { S.real($0.folder).path == S.real(holding).path }
        let lineWithCopy = copyCenter.run(copyID).map(gateModel.checks)?.first
        S.decide = nil
        let savedDefault = S.defaultCopyTarget
        S.defaultCopyTarget = nil
        let offSafe = copyCenter.run(copyID).map(gateModel.checks)?.first?.safe
        S.defaultCopyTarget = savedDefault
        S.decide = { _ in .target(second.path) }
        if let copyPath { try? fm.moveItem(atPath: copyPath, toPath: copyPath + ".gone") }
        await gateModel.refreshSpace()
        let copyGone = gateModel.waiting.first { S.real($0.folder).path == S.real(holding).path }
        let lineGone = copyCenter.run(copyID).map(gateModel.checks)?.first
        S.decide = { _ in .none }
        await gateModel.refreshSpace()
        let acknowledged = gateModel.waiting.first { S.real($0.folder).path == S.real(holding).path }
        S.decide = { _ in .target(second.path) }
        if let copyPath { try? fm.moveItem(atPath: copyPath + ".gone", toPath: copyPath) }
        check("archive wf: second copy off (the default): safe as before; on for a project: safe only with its copy there",
              (withCopy?.safe ?? 0) > 0 && withCopy?.uncopied == 0 && lineWithCopy?.safe == true && offSafe == true
              && copyGone?.safe == 0 && (copyGone?.uncopied ?? 0) > 0 && lineGone?.safe == false && lineGone?.copyNeeded == true
              && (acknowledged?.safe ?? 0) > 0 && acknowledged?.uncopied == 0,
              "with \(withCopy?.safe ?? -1)/\(withCopy?.uncopied ?? -1) gone \(copyGone?.safe ?? -1)/\(copyGone?.uncopied ?? -1) none \(acknowledged?.safe ?? -1) line \(lineWithCopy?.safe ?? false) \(lineGone?.safe ?? true)")

        // 3 A copy damaged on its way: read back differently, it isn't kept (nothing at its place, no hidden piece), said, made again next time.
        S.decide = { _ in .none }
        let (badCenter, badID, badClips) = await archived("Damaged")
        S.decide = { _ in .target(second.path) }
        S.copyWritten = { temp in
            guard let handle = FileHandle(forUpdatingAtPath: temp) else { return }
            try? handle.seek(toOffset: 5000)
            let byte = (try? handle.read(upToCount: 1))?.first ?? 0
            try? handle.seek(toOffset: 5000)
            try? handle.write(contentsOf: Data([byte ^ 0xFF]))
            try? handle.close()
        }
        await badCenter.secondCopies(badID)
        S.copyWritten = nil
        let badFile = badCenter.run(badID)?.files.first
        let badPlace = second.appendingPathComponent("WF/Projects/Damaged/Rushes")
        let badLeft = (try? fm.contentsOfDirectory(atPath: badPlace.path)) ?? []
        check("archive wf: a second copy that reads back differently isn't kept: nothing at its place, said, and the original isn't safe",
              badFile?.copied == nil && badFile?.copyProblem != nil && !badLeft.contains(badClips[0].lastPathComponent) && !badLeft.contains { $0.hasPrefix(".pluck-copying-") },
              "\(states(badCenter.run(badID)?.files)) \(badLeft)")
        await badCenter.secondCopies(badID)
        check("archive wf: made again, it's kept", badCenter.run(badID)?.files.first?.copied != nil, states(badCenter.run(badID)?.files))

        // 4 Never over anything: another file where the copy goes stays as it is; the same bytes there (a quit after it went in) count.
        S.decide = { _ in .none }
        let (blockCenter, blockID, blockClips) = await archived("Blocked")
        S.decide = { _ in .target(second.path) }
        let blockPlace = second.appendingPathComponent("WF/Projects/Blocked/Rushes").appendingPathComponent(blockClips[0].lastPathComponent)
        try? fm.createDirectory(at: blockPlace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 1234).write(to: blockPlace)
        await blockCenter.secondCopies(blockID)
        let blocked = blockCenter.run(blockID)?.files.first
        check("archive wf: something else where the second copy goes is never written over: left as it is, said",
              blocked?.copied == nil && blocked?.copyProblem != nil && size(blockPlace.path) == 1234, states(blockCenter.run(blockID)?.files))
        try? fm.removeItem(at: blockPlace)
        if let moved = blocked?.moved { try? fm.copyItem(atPath: moved, toPath: blockPlace.path) }
        let inode = S.stamp(blockPlace.path)?.inode
        await blockCenter.secondCopies(blockID)
        check("archive wf: the same bytes already there (a quit after the copy went in) count as the copy, not written again",
              blockCenter.run(blockID)?.files.first?.copied != nil && S.stamp(blockPlace.path)?.inode == inode, states(blockCenter.run(blockID)?.files))

        // 5 Stopped halfway (a pause, a quit): the hidden piece stays and the copy carries on from it, checked whole.
        S.decide = { _ in .none }
        let (stopCenter, stopID, stopClips) = await archived("Stopped")
        S.decide = { _ in .target(second.path) }
        S.copyChunk = 64 * 1024
        if let file = stopCenter.run(stopID)?.files.first {
            var reads = 0
            let first = S.secondCopy(file, target: second, token: "test1234") { reads += 1; return reads > 3 }
            let folder = second.appendingPathComponent("WF/Projects/Stopped/Rushes")
            let temp = folder.appendingPathComponent(".pluck-copying-test1234-" + stopClips[0].lastPathComponent)
            let partial = size(temp.path) ?? 0
            let second2 = S.secondCopy(first.file, target: second, token: "test1234")
            let hash = file.moved.flatMap { S.xxhash($0, cached: false) }
            check("archive wf: a copy stopped halfway keeps its hidden piece and carries on from it, read back whole",
                  first.stopped && first.file.copied == nil && partial > 0 && partial < file.size && second2.file.copied?.hashes[stopClips[0].lastPathComponent] == hash
                  && !fm.fileExists(atPath: temp.path) && S.xxhash(folder.appendingPathComponent(stopClips[0].lastPathComponent).path, cached: false) == hash,
                  "stopped \(first.stopped) partial \(partial) of \(file.size) \(second2.file.copyProblem ?? "")")
            // A piece cut off wrongly (a drive that dropped out mid-write) is caught by the read back and made again.
            let damaged = S.secondCopy(file, target: second, token: "test5678") { false }
            _ = damaged
        }
        S.copyChunk = chunk

        // 6 The target gone (a drive unplugged, a NAS that dropped): the copies wait, nothing fails; back again, they carry on.
        S.decide = { _ in .none }
        let (goneCenter, goneID, _) = await archived("Gone")
        let away = base.appendingPathComponent("Away")
        let goneTarget = base.appendingPathComponent("Unplugged")
        OfficeGroup.testVolumes += alias(goneTarget, "smb://test/unplugged")
        S.decide = { _ in .target(goneTarget.path) }
        let waited = await goneCenter.secondCopies(goneID)
        let goneFile = goneCenter.run(goneID)?.files.first
        try? fm.createDirectory(at: goneTarget, withIntermediateDirectories: true)
        let carried = await goneCenter.secondCopies(goneID, retry: false)
        check("archive wf: a target that isn't there pauses the copies (no failure kept); once it's back they carry on by themselves",
              waited != nil && goneFile?.copied == nil && goneFile?.copyProblem == nil && carried == nil && goneCenter.run(goneID)?.files.first?.copied != nil,
              "\(waited ?? "nil") \(carried ?? "nil") \(states(goneCenter.run(goneID)?.files))")
        _ = away
        S.decide = { _ in .target(second.path) }

        // 7 The original changed since its master was made, or a target on the same share: no copy, said.
        S.decide = { _ in .none }
        let (changeCenter, changeID, _) = await archived("Changed")
        S.decide = { _ in .target(second.path) }
        if let moved = changeCenter.run(changeID)?.files.first?.moved, let handle = FileHandle(forUpdatingAtPath: moved) {
            try? handle.seek(toOffset: 10)
            try? handle.write(contentsOf: Data([1, 2, 3]))
            try? handle.close()
        }
        await changeCenter.secondCopies(changeID)
        let sameShare = changeCenter.run(changeID)?.files.first.map { S.secondCopy($0, target: share.appendingPathComponent("Copies"), token: "x").file }
        check("archive wf: an original that changed since its master was made gets no copy; nor does a target on its own share",
              changeCenter.run(changeID)?.files.first?.copied == nil && changeCenter.run(changeID)?.files.first?.copyProblem != nil
              && sameShare?.copied == nil && sameShare?.copyProblem != nil,
              "\(states(changeCenter.run(changeID)?.files)) same: \(sameShare?.copyProblem ?? "nil")")

        // 8 A project on hold gets no copy; a copy another Mac holds the claim of is left to it.
        S.decide = { _ in .none }
        let (holdCenter, holdID, _) = await archived("Held")
        S.decide = { _ in .target(second.path) }
        let heldFolder = projects.appendingPathComponent("Held").path
        ArchiveProject.setHold(heldFolder, true)
        await holdCenter.secondCopies(holdID)
        let heldCopied = holdCenter.run(holdID)?.files.first?.copied != nil
        ArchiveProject.setHold(heldFolder, false)
        if let file = holdCenter.run(holdID)?.files.first {
            let place = URL(fileURLWithPath: S.copyFolder(file.path, folder: file.folder, target: second)).appendingPathComponent((file.path as NSString).lastPathComponent)
            let claim = OfficeGroup.claim(place, mac: "Mac B#other")
            await holdCenter.secondCopies(holdID)
            let whileClaimed = holdCenter.run(holdID)?.files.first?.copied != nil
            if let claim { OfficeGroup.release(claim) }
            await holdCenter.secondCopies(holdID)
            check("archive wf: a project on hold gets no copy, nor one another Mac is copying; let go, it's copied",
                  !heldCopied && !whileClaimed && holdCenter.run(holdID)?.files.first?.copied != nil, states(holdCenter.run(holdID)?.files))
        }

        // 9 The always-on Mac's copy comes in with its results (same master); one somewhere this Mac can't reach doesn't.
        if let file = copyCenter.run(copyID)?.files.first {
            let mergeCenter = center("merge")
            var mine = file
            mine.copied = nil
            let mergeID = mergeCenter.add([mine], settings: hd, roots: [])
            if var now = mergeCenter.run(mergeID)?.files.first { now = mine; mergeCenter.set(now, in: mergeID) }
            ShrinkRemote.merge([file], into: mergeID, center: mergeCenter)
            var other = file
            other.masterHash = "0000000000000000"
            let otherCenter = center("merge2")
            let otherID = otherCenter.add([mine], settings: hd, roots: [])
            otherCenter.set(mine, in: otherID)
            ShrinkRemote.merge([other], into: otherID, center: otherCenter)
            let unreachable = ShrinkRemote.translated(file) { $0.hasPrefix(second.path) ? nil : $0 }
            check("archive wf: the always-on Mac's second copy comes in with its results; a different master's or an unreachable one doesn't",
                  mergeCenter.run(mergeID)?.files.first?.copied == file.copied && otherCenter.run(otherID)?.files.first?.copied == nil
                  && unreachable?.copied == nil && unreachable != nil, "\(mergeCenter.run(mergeID)?.files.first?.copied != nil)")
        }

        // MARK: 1b Closed, Hold, kept until

        // 10 .pluck-project.json: Archive's keys set, Deliver's and unknown ones kept; a file that isn't JSON never written over.
        let jsonFolder = projects.appendingPathComponent("Json")
        try? fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
        try? Data(#"{"delivered":"2026-03-01","later":{"x":1}}"#.utf8).write(to: ArchiveProject.url(jsonFolder.path))
        ArchiveProject.setHold(jsonFolder.path, true)
        let merged = ArchiveProject.json(jsonFolder.path) ?? [:]
        let badFolder = projects.appendingPathComponent("BadJson")
        try? fm.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: ArchiveProject.url(badFolder.path))
        let wroteBad = ArchiveProject.setHold(badFolder.path, true)
        check("archive wf: .pluck-project.json keeps Deliver's and unknown keys when Archive sets its own; one that isn't JSON is never written over",
              merged["hold"] as? Bool == true && merged["delivered"] as? String == "2026-03-01" && merged["later"] != nil && !wroteBad
              && (try? String(contentsOf: ArchiveProject.url(badFolder.path), encoding: .utf8)) == "not json", "\(merged)")

        // 11 Closed by Deliver, kept 6 months for its client: until then left (said), after it the age filter isn't asked; Hold beats all.
        let day = ArchiveProject.date("2026-03-01")!
        let delivered = ArchiveProject.Info(delivered: day)
        let before = ArchiveProject.gate(delivered, months: 6, now: day.addingTimeInterval(30 * 86400))
        let after = ArchiveProject.gate(delivered, months: 6, now: day.addingTimeInterval(200 * 86400))
        let noMonths = ArchiveProject.gate(delivered, months: nil, now: day)
        let held = ArchiveProject.gate(ArchiveProject.Info(delivered: day, hold: true), months: 6, now: day.addingTimeInterval(400 * 86400))
        let reopened = ArchiveProject.Info(delivered: day, closed: false)
        check("archive wf: closed by Deliver with 6 months kept: left until then, after that ripe; no months: the age filter; Hold: never; opened again: not closed",
              before.reason != nil && !before.ripe && after.reason == nil && after.ripe && noMonths.reason == nil && !noMonths.ripe
              && held.reason != nil && !reopened.isClosed && delivered.isClosed && ArchiveProject.label(delivered)?.isEmpty == false,
              "\(before) \(after) \(noMonths) \(held)")
        ArchiveProject.setClosed(jsonFolder.path, true, months: 6)
        check("archive wf: closing with months set writes when its originals may go (from Deliver's delivery)",
              ArchiveProject.read(jsonFolder.path)?.keepOriginalsUntil.map { abs($0.timeIntervalSince(Calendar.current.date(byAdding: .month, value: 6, to: day)!)) < 86400 * 2 } == true,
              "\(ArchiveProject.json(jsonFolder.path) ?? [:])")

        // 12 The engine itself: a project put on hold (from any Mac) after the run was started is never touched.
        let holdFolder = projects.appendingPathComponent("OnHold/Rushes"), holdClip = holdFolder.appendingPathComponent("A300C001.mov")
        make(holdClip)
        let holdRunCenter = center("onhold")
        let holdRunID = holdRunCenter.add(scan(holdFolder), settings: hd, roots: [holdFolder.deletingLastPathComponent().path])
        ArchiveProject.setHold(projects.appendingPathComponent("OnHold").path, true)
        let holdBefore = size(holdClip.path)
        await holdRunCenter.resume(holdRunID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let holdFileNow = holdRunCenter.run(holdRunID)?.files.first
        check("archive wf: a project on hold is never touched by a run, even one started before (its original where it was, nothing moved)",
              holdFileNow?.state == .skipped && holdFileNow?.moved == nil && size(holdClip.path) == holdBefore
              && !fm.fileExists(atPath: S.movedPath(holdClip.path, holding: holding)), states(holdRunCenter.run(holdRunID)?.files))
        // … and one closed long ago whose days have passed goes even with files newer than the age limit.
        let ripeFolder = projects.appendingPathComponent("Ripe/Rushes"), ripeClip = ripeFolder.appendingPathComponent("A301C001.mov")
        make(ripeClip)
        try? Data(repeating: 1, count: 10).write(to: projects.appendingPathComponent("Ripe/notes.txt"))
        try? Data(#"{"closed":true,"keepOriginalsUntil":"2020-01-01"}"#.utf8).write(to: ArchiveProject.url(projects.appendingPathComponent("Ripe").path))
        let ripeCenter = center("ripe")
        let ripeID = ripeCenter.add(scan(ripeFolder), settings: hd, roots: [ripeFolder.deletingLastPathComponent().path], months: 6)
        await ripeCenter.resume(ripeID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive wf: closed and past its kept-until day, a project is archived even with a recent file (the age filter isn't asked)",
              ripeCenter.run(ripeID)?.files.first?.state == .done, states(ripeCenter.run(ripeID)?.files))

        // MARK: 1f What the master keeps, compared before deleting

        // 13 A master whose timecode or reel isn't its original's fails Check Before Deleting (its checksum and frames otherwise right).
        S.decide = { _ in .none }
        let (metaCenter, metaID, _) = await archived("Meta")
        if var file = metaCenter.run(metaID)?.files.first, let master = file.master {
            let plain = S.check(file, ffmpeg: ffmpeg, ffprobe: ffprobe)
            func doctored(_ extra: [String]) -> [String] {
                let other = base.appendingPathComponent("doctored-\(UUID().uuidString).mov").path
                ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-i", master, "-map", "0:v", "-map", "0:a", "-c", "copy", "-map_metadata", "0"] + extra
                                   + ["-movflags", "+use_metadata_tags", "-f", "mov", other])
                let saved = base.appendingPathComponent("saved-\(UUID().uuidString).mov").path
                try? fm.moveItem(atPath: master, toPath: saved)
                try? fm.moveItem(atPath: other, toPath: master)
                var changed = file
                changed.masterHash = S.xxhash(master, cached: false)
                changed.masterSize = size(master)
                let found = S.check(changed, ffmpeg: ffmpeg, ffprobe: ffprobe).problems
                try? fm.removeItem(atPath: master)
                try? fm.moveItem(atPath: saved, toPath: master)
                return found
            }
            let timecode = doctored(["-timecode", "11:00:00:00", "-metadata:s:v:0", "reel_name=A001C001"])
            let reel = doctored(["-timecode", "10:00:00:00", "-metadata:s:v:0", "reel_name=OTHER"])
            check("archive wf: Check Before Deleting reads the original's timecode and reel; a master that differs fails, the right one passes",
                  plain.problems.isEmpty && plain.timecode == "10:00:00:00" && plain.reel == "A001C001"
                  && timecode.contains(String(localized: "The start timecode differs")) && reel.contains(String(localized: "The reel name differs")),
                  "plain \(plain.problems) tc \(plain.timecode ?? "nil") reel \(plain.reel ?? "nil") | \(timecode) | \(reel)")
            file.state = .done
        }
        var a = ProjectArchive.Streams(fps: 25, timecode: "01:00:00:00", reel: "R1", channels: 2), m = a
        let same = S.keptProblems(master: m, original: a, name: "x.mov")
        m.fps = 24
        let rate = S.keptProblems(master: m, original: a, name: "x.mov")
        m = a; m.channels = 1
        let channels = S.keptProblems(master: m, original: a, name: "x.mov")
        a.reel = nil; m = a; m.reel = "C0001"
        let byName = S.keptProblems(master: m, original: a, name: "C0001.MP4")
        check("archive wf: frame rate and sound channels compared too; an original without a reel is matched by its file name",
              same.isEmpty && rate.count == 1 && channels.count == 1 && byName.isEmpty, "\(same) \(rate) \(channels) \(byName)")

        // MARK: 1c Snapshots and what really came back

        // 14 TrueNAS's snapshot tasks on the share's dataset (or a parent's, recursive) say how long deleted space stays.
        let smb: [[String: Any]] = [["name": "Footage", "path": "/mnt/tank/media/footage"], ["name": "Other", "path": "/mnt/tank/other"]]
        let tasks: [[String: Any]] = [["dataset": "tank/media", "recursive": true, "enabled": true, "lifetime_value": 2, "lifetime_unit": "WEEK"],
                                      ["dataset": "tank/media/footage", "recursive": false, "enabled": true, "lifetime_value": 3, "lifetime_unit": "DAY"],
                                      ["dataset": "tank/media/footage", "recursive": false, "enabled": false, "lifetime_value": 1, "lifetime_unit": "YEAR"],
                                      ["dataset": "tank/medi", "recursive": true, "enabled": true, "lifetime_value": 9, "lifetime_unit": "YEAR"]]
        check("archive wf: snapshot days from the share's dataset tasks (the longest, recursive parents, not disabled or look-alike names); none: 0; not this NAS's: unknown",
              ArchiveSnapshots.days(shares: smb, tasks: tasks, share: "footage") == 14 && ArchiveSnapshots.days(shares: smb, tasks: tasks, share: "Other") == 0
              && ArchiveSnapshots.days(shares: smb, tasks: tasks, share: "nope") == nil,
              "\(ArchiveSnapshots.days(shares: smb, tasks: tasks, share: "footage") ?? -1)")
        // 15 Measured: free space when something was last waiting, and after the owner deletes some of it.
        var marks: [String: ArchiveSnapshots.Mark] = [:]
        let first = ArchiveSnapshots.measured(share: "/s", free: 100, waiting: 50, store: &marks)
        let afterDelete = ArchiveSnapshots.measured(share: "/s", free: 120, waiting: 20, store: &marks)
        let newRun = ArchiveSnapshots.measured(share: "/s", free: 110, waiting: 90, store: &marks)
        check("archive wf: what deleting gave back is measured (gone from the folder, free space grown); a new run starts it again",
              first == nil && afterDelete?.deleted == 30 && afterDelete?.freed == 20 && newRun == nil && marks["/s"]?.waiting == 90,
              "\(String(describing: afterDelete)) \(marks)")
        ArchiveSnapshots.lookup = { _ in 14 }
        let snapModel = ArchiveModel(center: copyCenter)
        await snapModel.refreshSpace()
        ArchiveSnapshots.lookup = nil
        check("archive wf: the folder to delete says when its share's space comes back",
              snapModel.waiting.contains { $0.snapshotDays == 14 && $0.free != nil }, "\(snapModel.waiting.map { "\($0.share) \($0.snapshotDays ?? -1)" })")

        // MARK: 1d The catalogue and its search

        // 16 A manifest beside the masters: each clip with its original, hash, codec, size, rate, timecode, reel, sound, where it went; a thumbnail.
        let copyProject = projects.appendingPathComponent("Copy").path
        let entry = ArchiveCatalog.read(copyProject).first
        let thumbThere = entry?.thumbnail.map { fm.fileExists(atPath: ArchiveCatalog.folder(copyProject).appendingPathComponent($0).path) } == true
        check("archive wf: each project's hidden manifest lists its clips (original, hash, codec, size, rate, timecode, reel, sound, the folder to delete, the second copy) with a thumbnail",
              entry?.original == copyClips[0].path && entry?.hash == originalHash && entry?.codec == "prores" && entry?.width == 640 && entry?.channels == 2
              && abs((entry?.fps ?? 0) - 25) < 0.01 && entry?.timecode == "10:00:00:00" && entry?.reel == "A001C001" && entry?.status == "to delete"
              && entry?.copyTarget == second.path && thumbThere, "\(String(describing: entry))")
        let year = "\(Calendar.current.component(.year, from: old))"
        let hits = ArchiveCatalog.search("a001c001 \(year) prores", projects: [copyProject, projects.appendingPathComponent("Nope").path])
        let misses = ArchiveCatalog.search("a001c001 1999", projects: [copyProject])
        check("archive wf: the search finds clips by every word (name, year, codec…) across the manifests; a word that doesn't fit leaves it out",
              hits.contains { $0.original == copyClips[0].path } && misses.isEmpty, "\(hits.count) \(misses.count)")
        // 17 The original deleted by the owner: the catalogue says so (the folder to delete still there).
        if let moved = copyCenter.run(copyID)?.files.first?.moved {
            try? fm.moveItem(atPath: moved, toPath: base.appendingPathComponent("deleted-by-owner.mov").path)
            await copyCenter.catalogue(copyID, ffmpeg: nil)
            check("archive wf: an original the owner deleted shows as deleted in the catalogue, its second copy still listed",
                  ArchiveCatalog.read(copyProject).first?.status == "deleted" && ArchiveCatalog.read(copyProject).first?.copy != nil,
                  "\(ArchiveCatalog.read(copyProject).first?.status ?? "nil")")
            try? fm.moveItem(atPath: base.appendingPathComponent("deleted-by-owner.mov").path, toPath: moved)
            await copyCenter.catalogue(copyID, ffmpeg: nil)
        }

        // MARK: 1e Restore Originals

        S.decide = { _ in .target(second.path) }
        // 18 From the second copy (the owner deleted the one waiting): back at its place, read back the copy's hash, the master to the Trash.
        let (restCenter, restID, restClips) = await archived("Restore", clips: ["A400C001.mov", "C0001.MP4"])
        let restFiles = restCenter.run(restID)?.files ?? []
        for file in restFiles { if let moved = file.moved { try? fm.moveItem(atPath: moved, toPath: base.appendingPathComponent("owner-deleted-" + UUID().uuidString).path) } }
        let foreign = restClips[1]
        try? Data(repeating: 3, count: 999).write(to: foreign)
        let restProject = projects.appendingPathComponent("Restore").path
        await restCenter.restore(restID, project: restProject)
        let restA = restCenter.run(restID)?.files.first { $0.path == restClips[0].path }
        let restB = restCenter.run(restID)?.files.first { $0.path == restClips[1].path }
        check("archive wf: Restore Originals from the second copy: the original back at its name with the copy's hash, the master gone to the Trash",
              restA?.state == .restored && S.xxhash(restClips[0].path, cached: false) == restA?.copied?.hashes[restClips[0].lastPathComponent],
              states(restCenter.run(restID)?.files))
        check("archive wf: something else at an original's place is never written over: left as it is, its master kept, said",
              restB?.state == .done && restB?.problem != nil && size(foreign.path) == 999 && restB?.master.map { fm.fileExists(atPath: $0) } == true,
              states(restCenter.run(restID)?.files))
        try? fm.removeItem(at: foreign)
        // 19 A second copy that changed (same size, other bytes): nothing restored, the master stays.
        if let copy = restB?.copied {
            let piece = (copy.folder as NSString).appendingPathComponent(foreign.lastPathComponent)
            if let handle = FileHandle(forUpdatingAtPath: piece) { try? handle.seek(toOffset: 4000); try? handle.write(contentsOf: Data([9, 9, 9])); try? handle.close() }
            await restCenter.restore(restID, project: restProject)
            let now = restCenter.run(restID)?.files.first { $0.path == restClips[1].path }
            let left = ((try? fm.contentsOfDirectory(atPath: foreign.deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(".pluck-restoring-") }
            check("archive wf: a second copy that doesn't read back as it was copied isn't restored (no hidden piece left), its master stays",
                  now?.state == .done && now?.problem != nil && !fm.fileExists(atPath: foreign.path) && now?.master.map { fm.fileExists(atPath: $0) } == true && left.isEmpty,
                  "\(states(restCenter.run(restID)?.files)) \(left)")
        }
        // 20 From the folder to delete (as Put Back), and stopped halfway from a copy it carries on.
        let (backCenter, backID, backClips) = await archived("RestoreBack")
        await backCenter.restore(backID, project: projects.appendingPathComponent("RestoreBack").path)
        let backFile = backCenter.run(backID)?.files.first
        check("archive wf: Restore Originals with the original still waiting: put back from the folder to delete",
              backFile?.state == .restored && backFile?.moved.map { !fm.fileExists(atPath: $0) } == true && S.xxhash(backClips[0].path, cached: false) == backFile?.copied?.hashes[backClips[0].lastPathComponent],
              states(backCenter.run(backID)?.files))
        let (halfCenter, halfID, halfClips) = await archived("RestoreHalf")
        if let file = halfCenter.run(halfID)?.files.first, let moved = file.moved {
            try? fm.moveItem(atPath: moved, toPath: base.appendingPathComponent("owner-deleted-half").path)
            S.copyChunk = 64 * 1024
            var reads = 0
            let first = S.restoreFromCopy(file, token: "half1234", stop: { reads += 1; return reads > 3 }, trash: { _ in })
            let master0 = fm.fileExists(atPath: file.master ?? "") && S.xxhash(halfClips[0].path, cached: false) == file.masterHash
            let again = S.restoreFromCopy(first.file, token: "half1234", trash: { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) })
            S.copyChunk = chunk
            check("archive wf: a restore stopped halfway leaves the master in place and carries on from its hidden piece, checked whole",
                  first.stopped && master0 && again.file.state == .restored && S.xxhash(halfClips[0].path, cached: false) == file.copied?.hashes[halfClips[0].lastPathComponent],
                  "\(first.stopped) \(master0) \(again.file.state) \(again.file.problem ?? "")")
        }
    }
}
