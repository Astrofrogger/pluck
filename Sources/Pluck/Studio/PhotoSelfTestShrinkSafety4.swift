import Foundation

/// Archive's fourth review (part of shrinksafety): a clip whose move stops partway keeps its checked
/// master; a file not finished is never "safe to delete"; deliveries below a rushes word stay deliveries;
/// proxies of a same-named clip that isn't checked stay; a placeholder at the master's name is no block;
/// a claim lost while asleep hands the file over.
extension PhotoSelfTest {
    static func shrinkSafety4Test() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-shrinksafe4-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("Safe4")
        let testVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = [(share.path, "smb://test/safe4"), (share.path.replacingOccurrences(of: "/private/var/", with: "/var/"), "smb://test/safe4")]
        let renameBefore = S.exclusiveRename
        defer { OfficeGroup.testVolumes = testVolumes; S.exclusiveRename = renameBefore; S.kill = nil; S.killed = false; try? fm.removeItem(at: base) }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("shrink safety 4: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        let prores = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le"]
        func make(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1,noise=alls=3:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=stereo:sample_rates=48000",
                                        "-map", "0:v", "-map", "1:a", "-shortest"] + prores + ["-timecode", "10:00:00:00", "-f", "mov", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func write(_ url: URL, _ count: Int) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 5, count: count).write(to: url)
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func scan(_ folder: URL) -> [S.File] { S.scan([folder], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path } }
        func center(_ name: String) -> ShrinkCenter {
            let made = ShrinkCenter(store: base.appendingPathComponent("\(name).json"), mac: "Mac A")
            made.quiet = 0
            made.editing = { _ in false }
            made.trash = { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) }
            return made
        }
        func failing(_ refuse: @escaping (String, String) -> Bool) {
            S.exclusiveRename = { from, to in
                if refuse(from, to) { errno = EIO; return -1 }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        func states(_ files: [S.File]?) -> String { (files ?? []).map { "\(($0.path as NSString).lastPathComponent) \($0.state) \($0.note ?? "") \($0.problem ?? "")" }.joined(separator: " | ") }
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        let projects = share.appendingPathComponent("Projects")
        let holding = share.appendingPathComponent(S.holdingName)

        // 1 A .mov (same name) whose part can't move and whose original can't go back: still to finish, checked master kept; Resume finishes it.
        let partial = projects.appendingPathComponent("Partial/Rushes"), clip = partial.appendingPathComponent("A100C001.mov"), part = partial.appendingPathComponent("A100C001.extra")
        make(clip)
        write(part, 1000)
        if var file = scan(partial).first(where: { $0.path == clip.path }) {
            file.parts = [part.path]
            file.size += 1000
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            failing { from, to in from == part.path || to == clip.path }
            let after = S.finish(prepared, settings: hd)
            S.exclusiveRename = renameBefore
            check("shrink safety 4: a part that can't move and an original that can't go back: still to finish, its checked master kept",
                  prepared.state == .working && after.state == .working && after.moved != nil && fm.fileExists(atPath: prepared.temp ?? "/nonexistent")
                  && fm.fileExists(atPath: prepared.moved ?? "/nonexistent"), "\(after.state) \(after.note ?? "") moved \(after.moved ?? "nil")")
            let again = S.finish(after, settings: hd)
            let movedFolder = ((prepared.moved ?? "/") as NSString).deletingLastPathComponent
            check("shrink safety 4: … and Resume finishes it: master at its name, the original and its part in the folder to delete",
                  again.state == .done && ProjectArchive.streams(clip.path, ffprobe: ffprobe).codec == "hevc"
                  && fm.fileExists(atPath: prepared.moved ?? "/nonexistent") && fm.fileExists(atPath: (movedFolder as NSString).appendingPathComponent(part.lastPathComponent)),
                  "\(again.state) \(again.note ?? "")")
        } else { check("shrink safety 4: partial clip made", false) }

        // 2 An .mp4 (master renamed .mov) whose part is stuck in the folder to delete: its master isn't dropped; Resume finishes it.
        let stuckFolder = projects.appendingPathComponent("Stuck/Rushes"), mp4 = stuckFolder.appendingPathComponent("C0100.MP4")
        let p1 = stuckFolder.appendingPathComponent("C0100.p1"), p2 = stuckFolder.appendingPathComponent("C0100.p2")
        make(mp4)
        write(p1, 500)
        write(p2, 700)
        if var file = scan(stuckFolder).first(where: { $0.path == mp4.path }) {
            file.parts = [p1.path, p2.path]
            file.size += 1200
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            failing { from, to in from == p2.path || to == p1.path }
            let after = S.finish(prepared, settings: hd)
            S.exclusiveRename = renameBefore
            let movedFolder = ((prepared.moved ?? "/") as NSString).deletingLastPathComponent
            check("shrink safety 4: a part stuck in the folder to delete: still to finish, the checked master kept",
                  after.state == .working && after.problem != nil && fm.fileExists(atPath: prepared.master ?? "/nonexistent")
                  && fm.fileExists(atPath: (movedFolder as NSString).appendingPathComponent(p1.lastPathComponent)),
                  "\(after.state) \(after.note ?? "")")
            let again = S.finish(after, settings: hd)
            check("shrink safety 4: … and Resume finishes it, all of the original in the folder to delete",
                  again.state == .done && fm.fileExists(atPath: prepared.moved ?? "/nonexistent")
                  && [p1, p2].allSatisfy { fm.fileExists(atPath: (movedFolder as NSString).appendingPathComponent($0.lastPathComponent)) && !fm.fileExists(atPath: $0.path) },
                  "\(again.state) \(again.note ?? "") \(again.problem ?? "")")
        } else { check("shrink safety 4: stuck clip made", false) }

        // 3 The master can't go in after the original moved: the original is back, and only then the hidden master goes.
        let backFolder = projects.appendingPathComponent("Back4/Rushes"), backClip = backFolder.appendingPathComponent("A101C001.mov")
        make(backClip)
        if let file = scan(backFolder).first {
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            failing { from, _ in from.contains("/.shrinking-") }
            let after = S.finish(prepared, settings: hd)
            S.exclusiveRename = renameBefore
            check("shrink safety 4: the master can't go in: the original is back at its name, then the hidden master is dropped",
                  after.state == .failed && ProjectArchive.streams(backClip.path, ffprobe: ffprobe).codec == "prores"
                  && !fm.fileExists(atPath: prepared.temp ?? "/nonexistent"), "\(after.state) \(after.note ?? "")")
        }

        // 4 A placeholder of Pluck's left at the master's name (a drive without an exclusive rename, Pluck quit): no block.
        let holdMp4Folder = projects.appendingPathComponent("Place/Rushes"), holdMp4 = holdMp4Folder.appendingPathComponent("C0101.MP4")
        let holdMov = holdMp4Folder.appendingPathComponent("A102C001.mov")
        make(holdMp4)
        make(holdMov)
        func placeholder(_ path: String) {
            fm.createFile(atPath: path, contents: nil)
            setxattr(path, S.placeholderMark, "1", 1, 0, 0)
        }
        if let file = scan(holdMp4Folder).first(where: { $0.path == holdMp4.path }) {
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            if let master = prepared.master { placeholder(master) }
            let after = S.finish(prepared, settings: hd)
            check("shrink safety 4: a placeholder at an .mp4's master name: removed, the master goes in",
                  after.state == .done && ProjectArchive.streams(prepared.master ?? "/nonexistent", ffprobe: ffprobe).codec == "hevc",
                  "\(after.state) \(after.note ?? "")")
        }
        if let file = scan(holdMp4Folder).first(where: { $0.path == holdMov.path }) {
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            S.kill = { name, _ in name == "original out" }
            _ = S.finish(prepared, settings: hd)
            S.kill = nil
            S.killed = false
            placeholder(holdMov.path)
            let after = S.finish(prepared, settings: hd)
            check("shrink safety 4: a placeholder at a .mov's own name after the original went out: removed, the master goes in",
                  after.state == .done && ProjectArchive.streams(holdMov.path, ffprobe: ffprobe).codec == "hevc", "\(after.state) \(after.note ?? "") \(after.problem ?? "")")
        }

        // 5 Not finished is never safe: a file stopped between "original out" and "master in", and one the other Mac has.
        let masterFile = base.appendingPathComponent("m.mov")
        write(masterFile, 100)
        var fine = S.File(path: "/v/P/fine.mov", folder: "/v", size: 10, modified: old)
        fine.state = .done
        fine.checked = .now
        fine.checkProblems = []
        fine.master = masterFile.path
        fine.masterStamp = S.stamp(masterFile.path)
        fine.client = "Client"
        fine.projectName = "P"
        var half = fine
        half.path = "/v/P/half.mov"
        half.state = .working
        half.moved = holding.appendingPathComponent("v/P/half.mov").path
        half.checked = nil
        var fineQ = fine
        fineQ.path = "/v/Q/fine.mov"
        fineQ.projectName = "Q"
        var away = fineQ
        away.path = "/v/Q/away.mov"
        away.state = .elsewhere
        away.checked = nil
        let lines = ArchiveModel(center: center("lines")).checks(S.Run(settings: hd, files: [fine, half, fineQ, away]))
        let lineP = lines.first { $0.title == "Client – P" }, lineQ = lines.first { $0.title == "Client – Q" }
        check("shrink safety 4: a project with a file not finished (here or on the other Mac) never says safe to delete",
              fine.safeNow() && half.notSafe() != nil && lines.count == 2 && lines.allSatisfy { !$0.safe }
              && lineP?.problems.isEmpty == false && lineQ?.problems.isEmpty == true && lineQ?.checked == lineQ?.masters && lineQ?.finished == false,
              "\(lines.map { "\($0.title) \($0.masters) \($0.checked) \($0.problems) \($0.finished)" })")
        var pendingR = fine
        pendingR.path = "/v/R/next.mov"
        pendingR.projectName = "R"
        pendingR.state = .pending
        let alone = ArchiveModel(center: center("lines")).checks(S.Run(settings: hd, files: [fine, pendingR]))
        let through = ArchiveModel(center: center("lines")).checks(S.Run(settings: hd, files: [fine]))
        var pendingP = fine
        pendingP.path = "/v/P/next.mov"
        pendingP.state = .pending
        let samePending = ArchiveModel(center: center("lines")).checks(S.Run(settings: hd, files: [fine, pendingP]))
        check("shrink safety 4: while a project still has a file to do it isn't called safe; another project's file to do doesn't hold it back; once through, it is",
              samePending.first { $0.title == "Client – P" }?.safe == false && alone.first { $0.title == "Client – P" }?.safe == true && through.first?.safe == true,
              "\(samePending.map { "\($0.title) \($0.safe)" }) \(alone.map { "\($0.title) \($0.safe)" })")

        // 6 Deliveries: a delivery word anywhere below the project wins; a reel name alone isn't a camera.
        let k = { S.classify($0, root: "/V/Share", tags: $1).0 }
        check("shrink safety 4: a delivery folder above a rushes word is still a delivery; a reel name alone isn't a camera",
              k("/V/Share/Job/Export/Clips/x.mov", [:]) == .deliveries && k("/V/Share/Job/Deliveries/Media/x.mov", [:]) == .deliveries
              && k("/V/Share/Job/Renders/Raw/x.mov", [:]) == .deliveries && k("/V/Share/Job/x/render.mov", ["reel_name": "A001"]) != .rushes
              && k("/V/Share/Job/Rushes/A001C001.mov", [:]) == .rushes,
              "\(k("/V/Share/Job/Export/Clips/x.mov", [:])) \(k("/V/Share/Job/Deliveries/Media/x.mov", [:])) \(k("/V/Share/Job/Renders/Raw/x.mov", [:])) \(k("/V/Share/Job/x/render.mov", ["reel_name": "A001"]))")

        // 7 Proxies: one named like a clip of another camera that isn't in the run stays; Resolve's gallery stills stay.
        let twin = projects.appendingPathComponent("Twin"), camA = twin.appendingPathComponent("Rushes/CamA/C0001.MP4"), camB = twin.appendingPathComponent("Rushes/CamB/C0001.MP4")
        make(camA)
        make(camB)
        let twinProxy = twin.appendingPathComponent("Proxy")
        write(twinProxy.appendingPathComponent("C0001.mov"), 100)
        let twinFiles = scan(camA.deletingLastPathComponent())
        let twinCenter = center("twin")
        let twinID = twinCenter.add(twinFiles, settings: hd, roots: [twin.path], proxies: [twinFiles.first?.project ?? twin.path: [twinProxy.path]])
        await twinCenter.resume(twinID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety 4: a proxy named like another camera's clip that isn't checked stays where it is",
              twinCenter.run(twinID)?.files.first?.state == .done && fm.fileExists(atPath: twinProxy.appendingPathComponent("C0001.mov").path),
              states(twinCenter.run(twinID)?.files))
        let gal = projects.appendingPathComponent("Gallery"), galClip = gal.appendingPathComponent("Rushes/A103C001.mov")
        make(galClip)
        let cache = gal.appendingPathComponent("CacheClip")
        write(cache.appendingPathComponent("Project/.gallery/still_1.1.1.dpx"), 100)
        let galFiles = scan(galClip.deletingLastPathComponent())
        let galCenter = center("gallery")
        let galID = galCenter.add(galFiles, settings: hd, roots: [gal.path], proxies: [galFiles.first?.project ?? gal.path: [cache.path]])
        await galCenter.resume(galID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety 4: Resolve's gallery stills are never moved with the caches",
              galCenter.run(galID)?.files.first?.state == .done && fm.fileExists(atPath: cache.appendingPathComponent("Project/.gallery/still_1.1.1.dpx").path),
              states(galCenter.run(galID)?.files))

        // 8 Another Mac took the claim over while this one slept: the file is the other Mac's, nothing of this Mac's left.
        let sleep = projects.appendingPathComponent("Sleep/Rushes"), sleepClip = sleep.appendingPathComponent("A104C001.mov")
        make(sleepClip)
        if let file = scan(sleep).first {
            let prepared = S.prepare(file, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            let after = S.finish(prepared, settings: hd, stillOurs: { false })
            check("shrink safety 4: a claim lost while preparing: the file goes to the other Mac, this Mac's hidden master gone, the original untouched",
                  after.state == .elsewhere && !fm.fileExists(atPath: prepared.temp ?? "/nonexistent")
                  && ProjectArchive.streams(sleepClip.path, ffprobe: ffprobe).codec == "prores", "\(after.state) \(after.note ?? "")")
        }

        // 9 The age limit looked at when the run goes: a project edited since the survey is left as it is.
        let aged = projects.appendingPathComponent("Aged"), agedClip = aged.appendingPathComponent("Rushes/A105C001.mov")
        make(agedClip)
        let agedFiles = scan(agedClip.deletingLastPathComponent())
        let cut = aged.appendingPathComponent("Edit/cut.drp")
        write(cut, 10)
        try? fm.setAttributes([.modificationDate: Date.now], ofItemAtPath: cut.path)
        let agedCenter = center("aged")
        let agedID = agedCenter.add(agedFiles, settings: hd, roots: [aged.path], months: 6)
        await agedCenter.resume(agedID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety 4: a project edited since the survey (within the age limit) is left when the run goes",
              agedFiles.count == 1 && agedCenter.run(agedID)?.files.first?.state == .skipped && ProjectArchive.streams(agedClip.path, ffprobe: ffprobe).codec == "prores",
              states(agedCenter.run(agedID)?.files))

        // 10 The always-on Mac's results: paths that aren't there any more (a moved RED clip's spans, an .mp4 now a .mov) kept, as text.
        let gone = projects.appendingPathComponent("Remote/Rushes"), redClip = gone.appendingPathComponent("A106_C001_001.R3D")
        var red = S.File(path: redClip.path, folder: gone.path, size: 10, modified: old)
        red.parts = [gone.appendingPathComponent("A106_C001_002.R3D").path]
        red.master = gone.appendingPathComponent("A106_C001_001.mov").path
        red.moved = holding.appendingPathComponent("Projects/Remote/Rushes/A106_C001_001.R3D").path
        red.state = .done
        write(URL(fileURLWithPath: red.master ?? ""), 10)
        write(URL(fileURLWithPath: red.moved ?? ""), 10)
        // (A real share: nothing found for a path that isn't there.)
        let lookup: (String) -> String? = { fm.fileExists(atPath: $0) ? ShrinkRemote.place($0) : nil }
        let sent = ShrinkRemote.translated(red) { ShrinkRemote.placeText($0, place: lookup) }
        let back = sent.flatMap(ShrinkRemote.translatedLoose)
        check("shrink safety 4: the always-on Mac's results keep paths that aren't there any more (spans, the original's old name)",
              sent?.parts.count == 1 && back?.path == red.path && back?.parts == red.parts && back?.master == red.master && back?.moved == red.moved,
              "\(String(describing: sent)) \(String(describing: back))")
    }
}
