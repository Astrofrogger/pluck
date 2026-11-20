import Foundation

/// Archive's data safety (-PluckScreenshotOnly shrinksafety, and at the end of shrink): under an
/// original's name there's always the original or a checked master; the folder to delete only gets
/// originals whose master is in place and checked; nothing is lost when a step fails, Pluck quits
/// halfway, a file is in the way, runs.json is old or damaged, another Mac's claim goes stale, or a
/// clip has tracks a master can't keep.
extension PhotoSelfTest {
    static func shrinkSafetyTest() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-shrinksafe-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("Safe")
        let testVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = [(share.path, "smb://test/safe"), (share.path.replacingOccurrences(of: "/private/var/", with: "/var/"), "smb://test/safe")]
        defer { OfficeGroup.testVolumes = testVolumes; try? fm.removeItem(at: base) }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("shrink safety: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        let prores = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le"]
        func make(_ url: URL, inputs: [String] = [], maps: [String] = ["-map", "0:v", "-map", "1:a"], _ codec: [String] = prores) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1,noise=alls=3:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=stereo:sample_rates=48000"]
                               + inputs + maps + ["-shortest"] + codec + ["-timecode", "10:00:00:00", "-f", "mov", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func scan(_ folder: URL) -> [S.File] { S.scan([folder], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path } }
        func center(_ name: String, mac: String = "Mac A") -> ShrinkCenter {
            let made = ShrinkCenter(store: base.appendingPathComponent("\(name).json"), mac: mac)
            made.quiet = 0
            made.editing = { _ in false }
            made.trash = { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) }
            return made
        }
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        let projects = share.appendingPathComponent("Projects")

        // 1 A file in the master's way after the original would move: the original stays at its name.
        let blockedFolder = projects.appendingPathComponent("Blocked/Rushes"), blocked = blockedFolder.appendingPathComponent("C0002.MP4")
        make(blocked)
        if let file = scan(blockedFolder).first {
            let prepared = S.prepare(file, settings: hd, holding: S.holding(for: blockedFolder), ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            if let master = prepared.master { try? fm.createDirectory(atPath: master, withIntermediateDirectories: true) }
            let finished = S.finish(prepared, settings: hd)
            check("shrink safety: a folder in the master's way: the original stays at its name, nothing in the folder to delete",
                  prepared.state == .working && fm.fileExists(atPath: blocked.path) && !fm.fileExists(atPath: prepared.moved ?? "/nonexistent")
                  && finished.state != .done, "\(prepared.state) \(finished.state) \(finished.note ?? "")")
        } else { check("shrink safety: blocked clip made", false) }

        // 2 runs.json: an older file with keys missing loads; a damaged one is kept aside; a bad run doesn't wipe the good one.
        let sample = S.Run(settings: hd, files: [S.File(path: "/x/a.mov", folder: "/x", size: 5, modified: old)])
        if var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode([sample]))) as? [[String: Any]] {
            for key in ["roots", "proxyFolders", "movedFolders"] { json[0][key] = nil }
            if var files = json[0]["files"] as? [[String: Any]] {
                for key in ["parts", "seconds", "kind", "why", "client", "state"] { files[0][key] = nil }
                json[0]["files"] = files
            }
            let store = base.appendingPathComponent("old-runs.json")
            try? JSONSerialization.data(withJSONObject: json).write(to: store)
            check("shrink safety: an older runs.json with keys missing loads", ShrinkCenter(store: store).runs.first?.files.first?.path == "/x/a.mov")
            var bad = json[0]
            bad["id"] = UUID().uuidString
            if var files = bad["files"] as? [[String: Any]] { files[0]["state"] = "exploded"; files[0]["path"] = 7; bad["files"] = files }
            bad["settings"] = "nonsense"
            let mixed = base.appendingPathComponent("mixed-runs.json")
            try? JSONSerialization.data(withJSONObject: [json[0], bad]).write(to: mixed)
            let mixedCenter = ShrinkCenter(store: mixed)
            mixedCenter.add([], settings: hd, roots: [])
            let kept = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix("mixed-runs.json.unreadable-") }
            check("shrink safety: one bad run in runs.json: the good one kept, the file kept aside before saving",
                  mixedCenter.runs.contains { $0.files.first?.path == "/x/a.mov" } && kept.count == 1, "\(mixedCenter.runs.count) \(kept)")
        }
        let damaged = base.appendingPathComponent("damaged-runs.json")
        try? Data("{ not json".utf8).write(to: damaged)
        let damagedCenter = ShrinkCenter(store: damaged)
        damagedCenter.add([], settings: hd, roots: [])
        let aside = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).first { $0.hasPrefix("damaged-runs.json.unreadable-") }
        check("shrink safety: an unreadable runs.json is kept aside, never overwritten",
              aside.flatMap { try? String(contentsOf: base.appendingPathComponent($0), encoding: .utf8) } == "{ not json", "\(String(describing: aside))")
        let rulesJSON = #"{"marks":{"a":"project","b":"weird"},"names":{"a":"A"},"sizes":{"a":"k4","b":"k9"}}"#
        let rules = try? JSONDecoder().decode(S.Rules.self, from: Data(rulesJSON.utf8))
        check("shrink safety: a project rule Pluck doesn't know doesn't lose the others", rules?.marks["a"] == .project && rules?.names["a"] == "A"
              && rules?.sizes?["a"] == .k4)

        // 3/4 A destination run: an original is only moved once its master is there and checked.
        let destRoot = projects.appendingPathComponent("DestSafe"), destClip = destRoot.appendingPathComponent("Rushes/A001C001.mov")
        let destClip2 = destRoot.appendingPathComponent("Rushes/A001C002.mov")
        make(destClip)
        make(destClip2)
        let destCenter = center("dest")
        let destID = await destCenter.start(scan(destRoot), settings: hd, destination: base.appendingPathComponent("DestOut"), roots: [destRoot.path],
                                            ffmpeg: ffmpeg, ffprobe: ffprobe)
        let destFiles = destCenter.run(destID)?.files ?? []
        if destFiles.count == 2, destFiles.allSatisfy({ $0.state == .done }), let m1 = destFiles[0].master, let m2 = destFiles[1].master {
            try? fm.removeItem(atPath: m1)
            if let handle = FileHandle(forWritingAtPath: m2) { try? handle.truncate(atOffset: 1000); try? handle.close() }
            _ = await destCenter.moveOriginals(destID, ffmpeg: ffmpeg, ffprobe: ffprobe)
            check("shrink safety: destination master missing or cut short: its original stays where it is",
                  fm.fileExists(atPath: destClip.path) && fm.fileExists(atPath: destClip2.path)
                  && destCenter.run(destID)?.files.allSatisfy { $0.moved == nil } == true,
                  "\(destCenter.run(destID)?.files.map { "\($0.moved ?? "-") \($0.note ?? "")" } ?? [])")
        } else { check("shrink safety: destination run made", false, "\(destFiles.map { "\($0.state) \($0.note ?? "")" })") }

        // 5 Put Back with the original's name taken: the master goes back to its name; a master never goes into the folder to delete.
        let backFolder = projects.appendingPathComponent("Back/Rushes"), backClip = backFolder.appendingPathComponent("C0003.MP4")
        let backMov = backFolder.appendingPathComponent("A003C001.mov")
        make(backClip)
        make(backMov)
        let backCenter = center("back")
        let backID = await backCenter.start(scan(backFolder), settings: hd, roots: [backFolder.path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        let holding = share.appendingPathComponent(S.holdingName)
        if let mp4 = backCenter.run(backID)?.files.first(where: { $0.path == backClip.path }), mp4.state == .done, let master = mp4.master,
           backCenter.run(backID)?.files.first(where: { $0.path == backMov.path })?.state == .done {
            try? fm.createDirectory(at: backClip, withIntermediateDirectories: true)
            backCenter.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
            await backCenter.putBack(backID)
            let after = backCenter.run(backID)?.files ?? []
            let mastersInHolding = (fm.enumerator(atPath: holding.path)?.allObjects as? [String] ?? []).filter { $0.contains("Master · ") }
            check("shrink safety: Put Back with the original's name taken: the master is back at its name, the original kept",
                  fm.fileExists(atPath: master) && fm.fileExists(atPath: mp4.moved ?? "/nonexistent")
                  && after.first { $0.path == backClip.path }?.state == .done, "\(after.map { "\($0.state) \($0.note ?? "")" })")
            check("shrink safety: Put Back without a Trash: the master is set aside hidden next to it, never into the folder to delete",
                  mastersInHolding.isEmpty && after.first { $0.path == backMov.path }?.state == .restored
                  && fm.fileExists(atPath: backFolder.appendingPathComponent(".pluck-removed-A003C001.mov").path)
                  && ProjectArchive.streams(backMov.path, ffprobe: ffprobe).codec == "prores", "\(mastersInHolding) \(after.map { "\($0.state) \($0.note ?? "")" })")
            try? fm.removeItem(at: backClip)
        } else { check("shrink safety: put-back run made", false, "\(backCenter.run(backID)?.files.map { "\($0.state) \($0.note ?? "")" } ?? [])") }

        // 6 Claims: another Mac's leftover is never deleted; stale is by the claim file's date on the share, not the writer's clock.
        let staleFolder = projects.appendingPathComponent("Stale/Rushes"), staleClip = staleFolder.appendingPathComponent("A004C001.mov")
        make(staleClip)
        let claimFile = OfficeGroup.claimURL(staleClip), theirs = staleFolder.appendingPathComponent(".shrinking-A004C001.mov")
        try? Data("Mac Z\n\(Date.now.addingTimeInterval(-3600).timeIntervalSince1970)\nTOKENZ\n".utf8).write(to: claimFile)
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: claimFile.path)
        try? Data(repeating: 7, count: 1000).write(to: theirs)
        let staleCenter = center("stale")
        let staleFiles = scan(staleFolder)
        _ = await staleCenter.start(staleFiles, settings: hd, roots: [staleFolder.path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety: a stale claim taken over: the other Mac's half-made master isn't deleted",
              (try? Data(contentsOf: theirs))?.count == 1000, "\(staleCenter.runs.first?.files.map { "\($0.state) \($0.note ?? "")" } ?? [])")
        let clock = base.appendingPathComponent("Clock")
        try? fm.createDirectory(at: clock, withIntermediateDirectories: true)
        let ahead = clock.appendingPathComponent("ahead.mov"), behind = clock.appendingPathComponent("behind.mov")
        try? Data("Mac Y\n\(Date.now.timeIntervalSince1970)\nTOKENY\n".utf8).write(to: OfficeGroup.claimURL(ahead))
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: OfficeGroup.claimURL(ahead).path)
        try? Data("Mac X\n\(Date.now.addingTimeInterval(-3600).timeIntervalSince1970)\nTOKENX\n".utf8).write(to: OfficeGroup.claimURL(behind))
        check("shrink safety: a claim is stale by its file's date on the share (the writer's clock doesn't count)",
              OfficeGroup.claim(ahead, mac: "Mac A") != nil && OfficeGroup.claim(behind, mac: "Mac A") == nil)

        // 7 Tracks: a subtitle track is kept; a second video track can't be, so the clip is left alone.
        let tracks = projects.appendingPathComponent("Tracks/Rushes"), subbed = tracks.appendingPathComponent("A005C001.mov"), twice = tracks.appendingPathComponent("A005C002.mov")
        let srt = base.appendingPathComponent("subs.srt")
        try? "1\n00:00:00,000 --> 00:00:00,800\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        make(subbed, inputs: ["-i", srt.path], maps: ["-map", "0:v", "-map", "1:a", "-map", "2:s"], prores + ["-c:s", "mov_text"])
        make(twice, inputs: ["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25:duration=1"], maps: ["-map", "0:v", "-map", "2:v", "-map", "1:a"])
        let trackCenter = center("tracks")
        let trackID = await trackCenter.start(scan(tracks), settings: hd, roots: [tracks.path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        let trackFiles = trackCenter.run(trackID)?.files ?? []
        let subtitles = ProjectArchive.run(ffprobe, ["-v", "error", "-select_streams", "s", "-show_entries", "stream=codec_name", "-of", "csv=p=0", subbed.path]).output
        check("shrink safety: a subtitle track is kept on the master", trackFiles.first { $0.path == subbed.path }?.state == .done && subtitles.contains("mov_text"),
              "\(trackFiles.map { "\($0.state) \($0.note ?? "")" }) \(subtitles)")
        let second = trackFiles.first { $0.path == twice.path }
        check("shrink safety: a second video track: left as it is, with why", second?.state == .skipped
              && ProjectArchive.streams(twice.path, ffprobe: ffprobe).codec == "prores", "\(String(describing: second?.state)) \(second?.note ?? "")")

        // 8 Archive Project's masters (and its folders) are never shrunk again.
        let archSource = projects.appendingPathComponent("ArchSrc/Rushes/A006C001.mov"), staging = projects.appendingPathComponent("ArchOut/Media")
        make(archSource)
        let item = ProjectArchive.Item(root: archSource.deletingLastPathComponent().path, relative: archSource.lastPathComponent, into: "Media",
                                       size: Int64((try? fm.attributesOfItem(atPath: archSource.path)[.size] as? Int64) ?? 0), modified: old, kind: .media,
                                       original: archSource.path)
        let mastered = ProjectArchive.makeMasters([item], settings: [archSource.path: hd], into: staging, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let loose = projects.appendingPathComponent("Loose/Rushes/A006C001.mov")
        try? fm.createDirectory(at: loose.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let master = mastered.items.first?.source, master != archSource.path { try? fm.copyItem(atPath: master, toPath: loose.path) }
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: loose.path)
        let looseFile = scan(loose.deletingLastPathComponent()).first
        check("shrink safety: an Archive Project master is never shrunk again", looseFile?.skip == String(localized: "Already a master"),
              "\(String(describing: looseFile?.skip)) \(mastered.notes)")
        check("shrink safety: Archive Project's output folder isn't looked in", scan(projects.appendingPathComponent("ArchOut")).isEmpty)

        // 9 A RED clip's span that can't move: the whole clip stays together where it was.
        let red = projects.appendingPathComponent("Red/Rushes")
        try? fm.createDirectory(at: red, withIntermediateDirectories: true)
        let span1 = red.appendingPathComponent("A007_C001_0101AB_001.R3D"), span2 = red.appendingPathComponent("A007_C001_0101AB_002.R3D")
        for url in [span1, span2] { try? Data(repeating: 1, count: 1000).write(to: url) }
        var unit = S.File(path: span1.path, folder: red.path, size: 2000, modified: old)
        unit.parts = [span2.path]
        let target = S.movedPath(span1.path, holding: holding)
        try? fm.createDirectory(atPath: ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent(span2.lastPathComponent),
                                withIntermediateDirectories: true)
        let why = S.moveOriginal(&unit, to: target)
        check("shrink safety: a span that can't move: the clip's files all stay where they were", why != nil && fm.fileExists(atPath: span1.path)
              && fm.fileExists(atPath: span2.path) && !fm.fileExists(atPath: target) && unit.moved == nil, "\(why ?? "moved")")

        // 10 The always-on Mac: its done wins over this Mac's "gone"; sidecars go with a file's paths; its files count as unfinished.
        let remoteCenter = center("remote")
        var gone = S.File(path: "/v/a.mov", folder: "/v", size: 10, modified: old)
        gone.sidecars = ["/v/a.xml"]
        let remoteID = remoteCenter.add([gone, S.File(path: "/v/b.mov", folder: "/v", size: 10, modified: old)], settings: hd, roots: ["/v"])
        gone.state = .skipped
        gone.note = String(localized: "Gone")
        remoteCenter.set(gone, in: remoteID)
        var there = gone
        there.state = .done
        there.master = "/v/a.mov"
        there.masterSize = 5
        there.moved = "/h/a.mov"
        ShrinkRemote.merge([there], into: remoteID, center: remoteCenter)
        var elsewhere = S.File(path: "/v/b.mov", folder: "/v", size: 10, modified: old)
        elsewhere.state = .elsewhere
        remoteCenter.set(elsewhere, in: remoteID)
        let mapped = ShrinkRemote.translated(gone) { "/mnt" + $0 }
        check("shrink safety: the always-on Mac's done counts over this Mac's \"gone\"; sidecars translated; its files keep the run unfinished",
              remoteCenter.run(remoteID)?.files.first?.state == .done && mapped?.sidecars == ["/mnt/v/a.xml"]
              && remoteCenter.run(remoteID).map(remoteCenter.unfinished) == true,
              "\(remoteCenter.run(remoteID)?.files.map { "\($0.state)" } ?? []) \(String(describing: mapped?.sidecars))")

        // 3 Check Before Deleting: run at the end of every run; a master changed by a byte or an original gone is NOT safe.
        let checkFolder = projects.appendingPathComponent("Check/Rushes")
        let c1 = checkFolder.appendingPathComponent("A008C001.mov"), c2 = checkFolder.appendingPathComponent("A008C002.mov"), c3 = checkFolder.appendingPathComponent("A008C003.mov")
        for url in [c1, c2, c3] { make(url) }
        let checkCenter = center("check")
        let checkID = await checkCenter.start(scan(checkFolder), settings: hd, roots: [checkFolder.path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        let checkedFiles = checkCenter.run(checkID)?.files ?? []
        let inventoryJSON = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasPrefix("Shrink ") && $0.hasSuffix(".json") }
            .compactMap { try? Data(contentsOf: holding.appendingPathComponent($0)) }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            .flatMap { $0 }.filter { ($0["original"] as? String)?.hasPrefix(checkFolder.path) == true }
        check("shrink safety: every run ends with Check Before Deleting: each master safe, its checksum, frames and check in the inventory",
              checkedFiles.count == 3 && checkedFiles.allSatisfy { $0.safeToDelete && $0.masterHash != nil && $0.frames == 25 && $0.originalHead != nil }
              && inventoryJSON.count == 3 && inventoryJSON.allSatisfy { $0["safe_to_delete"] as? Bool == true && ($0["master_xxhash64"] as? String)?.isEmpty == false
                  && $0["frames"] as? Int == 25 && $0["checked"] != nil },
              "\(checkedFiles.map { "\($0.state) \($0.note ?? "") \($0.checkProblems ?? ["unchecked"])" }) \(inventoryJSON.count)")
        if checkedFiles.count == 3, let m2 = checkedFiles.first(where: { $0.path == c2.path })?.master, let o3 = checkedFiles.first(where: { $0.path == c3.path })?.moved {
            if let handle = FileHandle(forUpdatingAtPath: m2) {
                try? handle.seek(toOffset: 5000)
                let byte = (try? handle.read(upToCount: 1))?.first ?? 0
                try? handle.seek(toOffset: 5000)
                try? handle.write(contentsOf: Data([byte ^ 0xFF]))
                try? handle.close()
            }
            let stray = holding.appendingPathComponent("Projects/Check/Rushes/stray.mov")
            try? Data(repeating: 9, count: 4000).write(to: stray)
            let o3aside = base.appendingPathComponent("o3-aside.mov")
            try? fm.moveItem(atPath: o3, toPath: o3aside.path)
            await checkCenter.check(checkID, ffmpeg: ffmpeg, ffprobe: ffprobe)
            let after = checkCenter.run(checkID)?.files ?? []
            func problems(_ url: URL) -> [String] { after.first { $0.path == url.path }?.checkProblems ?? ["unchecked"] }
            check("shrink safety: Check Before Deleting finds a master changed by one byte and an original gone; the right one stays safe",
                  after.first { $0.path == c1.path }?.safeToDelete == true && problems(c2).contains(String(localized: "The master’s checksum differs"))
                  && problems(c3).contains(String(localized: "The original isn’t all there")) && after.filter(\.safeToDelete).count == 1,
                  "\(after.map { "\(($0.path as NSString).lastPathComponent) \($0.checkProblems ?? [])" })")
            try? fm.moveItem(atPath: o3aside.path, toPath: o3)
            let model = ArchiveModel(center: checkCenter)
            await model.refreshSpace()
            let place = model.waiting.first { S.real($0.folder).path == S.real(holding).path }
            let safeNames = Set(place?.safeFiles.map(\.lastPathComponent) ?? []), unsafeNames = Set(place?.unsafeFiles.map { ($0 as NSString).lastPathComponent } ?? [])
            check("shrink safety: waiting to delete says safe for checked originals only; anything else (a changed master's original, a stray file) not safe",
                  safeNames.contains("A008C001.mov") && !safeNames.contains("A008C002.mov") && unsafeNames.contains("A008C002.mov") && unsafeNames.contains("stray.mov")
                  && !safeNames.contains("stray.mov") && (place?.safe ?? 0) > 0 && (place?.unsafe ?? 0) > 0, "\(safeNames) \(unsafeNames)")
            try? fm.removeItem(at: stray)
        }

        // 6 A claim taken over before the master goes in: nothing is touched.
        let lostFolder = projects.appendingPathComponent("Lost/Rushes"), lostClip = lostFolder.appendingPathComponent("A009C001.mov")
        make(lostClip)
        if let file = scan(lostFolder).first {
            let prepared = S.prepare(file, settings: hd, holding: holding, temp: S.temporary(lostClip.path, token: "11112222"), ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0)
            let after = S.finish(prepared, settings: hd, stillOurs: { false })
            check("shrink safety: the claim isn't this Mac's any more: the original and the hidden master are left as they are",
                  prepared.state == .working && after.state == .working && ProjectArchive.streams(lostClip.path, ffprobe: ffprobe).codec == "prores"
                  && fm.fileExists(atPath: prepared.temp ?? "/nonexistent") && !fm.fileExists(atPath: prepared.moved ?? "/nonexistent"), "\(after.state) \(after.note ?? "")")
            try? fm.removeItem(atPath: prepared.temp ?? "/nonexistent")
        }

        // 5 Put Back after Relink in Resolve: the way back points Resolve at the originals again.
        let relinkFolder = base.appendingPathComponent("RelinkBack")
        try? fm.createDirectory(at: relinkFolder, withIntermediateDirectories: true)
        let backOriginal = relinkFolder.appendingPathComponent("C0009.MP4")
        try? Data(repeating: 1, count: 10).write(to: backOriginal)
        let relinkCenter = center("relink")
        var restored = S.File(path: backOriginal.path, folder: relinkFolder.path, size: 10, modified: old)
        let relinkID = relinkCenter.add([restored], settings: hd, roots: [relinkFolder.path])
        restored.state = .restored
        restored.master = relinkFolder.appendingPathComponent("C0009.mov").path
        relinkCenter.set(restored, in: relinkID)
        relinkCenter.markRelinked(relinkID)
        let bridgeBefore = ShrinkRelink.bridge
        final class Sent { var map: [String: String] = [:] }
        let sent = Sent()
        ShrinkRelink.bridge = { instruction in
            sent.map = instruction["map"] as? [String: String] ?? [:]
            return ["results": [["project": "Alpha", "replaced": 1, "failed": [String]()]]]
        }
        _ = try? await ShrinkRelink.relink([relinkCenter.run(relinkID)].compactMap { $0 }, projects: ["Alpha"], drp: [], back: true)
        ShrinkRelink.bridge = bridgeBefore
        check("shrink safety: Relink to Originals maps each removed master back to its original", sent.map == [restored.master ?? "": backOriginal.path]
              && relinkCenter.run(relinkID)?.relinked != nil, "\(sent.map)")
        check("shrink safety: runs.json keeps the one before as runs.json.bak", fm.fileExists(atPath: base.appendingPathComponent("relink.json.bak").path))

        // Crash tests: Pluck killed at each step of making, checking and swapping; after Resume the master is in under
        // the original's name, the original whole in the folder to delete, and the check passes. Nothing lost at any point.
        for kind in ["mov", "mp4"] {
            for step in ["encoded", "verified", "master in", "moving", "original out"] {
                let folder = projects.appendingPathComponent("Crash/Rushes/\(kind) \(step.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "master", with: "m"))")
                let clip = folder.appendingPathComponent(kind == "mov" ? "A010C001.mov" : "C0010.MP4")
                make(clip)
                let rmd = folder.appendingPathComponent(clip.deletingPathExtension().lastPathComponent + ".RMD")
                try? Data(repeating: 5, count: 1000).write(to: rmd)
                try? fm.setAttributes([.modificationDate: old], ofItemAtPath: rmd.path)
                guard var file = scan(folder).first(where: { $0.path == clip.path }) else { check("shrink safety: crash \(kind) \(step) clip", false); continue }
                // (A part that moves with it, so a kill can land between the original and its part.)
                file.parts = [rmd.path]
                file.sidecars = nil
                file.size += 1000
                let store = "crash-\(kind)-\(step)".replacingOccurrences(of: " ", with: "-")
                let first = center(store)
                let id = first.add([file], settings: hd, roots: [folder.path])
                S.kill = { name, killed in
                    guard name == step, killed.path == clip.path else { return false }
                    if name == "encoded", let temp = killed.temp, let handle = FileHandle(forWritingAtPath: temp) { try? handle.truncate(atOffset: 100); try? handle.close() }
                    return true
                }
                await first.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
                S.kill = nil
                let wasKilled = S.killed
                let moved = S.movedPath(clip.path, holding: holding)
                let nothingLost = (fm.fileExists(atPath: clip.path) && ProjectArchive.streams(clip.path, ffprobe: ffprobe).codec == "prores") || fm.fileExists(atPath: moved)
                let again = center(store)
                await again.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
                let result = again.run(id)?.files.first
                let master = result?.master ?? "/nonexistent"
                let leftovers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".shrinking-") }
                check("shrink safety: killed at \(step) (\(kind)): nothing lost; after Resume the checked master is in and the original whole in the folder to delete",
                      wasKilled && nothingLost && result?.state == .done && result?.safeToDelete == true && ProjectArchive.streams(master, ffprobe: ffprobe).codec == "hevc"
                      && fm.fileExists(atPath: moved) && fm.fileExists(atPath: (moved as NSString).deletingLastPathComponent + "/" + rmd.lastPathComponent)
                      && !fm.fileExists(atPath: rmd.path) && leftovers.isEmpty,
                      "killed \(wasKilled) lost \(!nothingLost) \(String(describing: result?.state)) \(result?.note ?? "") \(result?.checkProblems ?? []) \(leftovers)")
            }
        }
    }
}
