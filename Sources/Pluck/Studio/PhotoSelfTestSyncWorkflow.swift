import Foundation

extension PhotoSelfTest {
    /// Sync Cameras workflow (-PluckScreenshotOnly syncWorkflow): an offload opened in Sync, a sync
    /// saved and reopened with a card added later, the Resolve export pieces (bins, recorder sound
    /// first, angles, markers, report), per day/set timelines, recorder rollover, proxies after sync.
    static func syncWorkflowTest() async {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("SyncWorkflowTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        syncOffloadTest(base.appendingPathComponent("offload", isDirectory: true))
        syncSaveTest(base.appendingPathComponent("save", isDirectory: true))
        syncResolvePiecesTest()
        syncSetsTest()
        syncRolloverTest()
        await syncReopenAndProxiesTest(base.appendingPathComponent("reopen", isDirectory: true))
    }

    private static func clip(_ path: String, start: Double?, duration: Double = 60, video: Bool = true, audio: Bool = true, confidence: Double = 0.9,
                             created: Date? = nil, timecode: Double? = nil) -> SyncClip {
        var clip = SyncClip(path: path, duration: duration, fps: video ? 25 : 0, hasAudio: audio, hasVideo: video, timecode: timecode, created: created)
        clip.start = start
        clip.method = start != nil ? .audio : nil
        clip.confidence = start != nil ? confidence : 0
        return clip
    }

    /// Saved beside the media (paths relative to it), opened again with only the clips still there; a sync then holds what's placed.
    private static func syncSaveTest(_ base: URL) {
        let fm = FileManager.default
        let paths = ["Cam1/a.mov", "Cam2/b.mov", "Cam2/c.mov"].map { base.appendingPathComponent($0).standardizedFileURL.path }
        for path in paths {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data([1]))
        }
        var a = clip(paths[0], start: 0), b = clip(paths[1], start: 12.5, confidence: 0.6)
        b.locked = true
        a.proxy = paths[2]
        let cameras = [SyncCamera(name: "Cam1", key: "folder:1", clips: [a]), SyncCamera(name: "Cam2", key: "folder:2", clips: [b, clip(paths[2], start: nil)])]
        try? CameraSync.save(SyncSave(cameras: cameras, audioFirst: true, shownTimecode: nil))
        let file = base.appendingPathComponent(CameraSync.saveName)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("sync save: beside the media, paths relative to it", CameraSync.saveFolder(cameras)?.standardizedFileURL.path == base.standardizedFileURL.path
              && fm.fileExists(atPath: file.path) && !text.contains(base.path) && text.contains("Cam1"), String(text.prefix(200)))
        let loaded = CameraSync.load(base)
        check("sync save: reopens as it was", loaded?.cameras == cameras && loaded?.audioFirst == true, "\(loaded?.cameras.map(\.name) ?? [])")
        try? fm.removeItem(atPath: paths[2])
        let fewer = CameraSync.load(base)
        check("sync save: a clip that's gone is left out", fewer?.cameras.flatMap(\.clips).map(\.path) == [paths[0], paths[1]] && fewer?.cameras.first?.clips.first?.proxy == nil)
        // Clips on a camera card: nothing written there (no sync, report or proxies).
        CameraSync.testCards = [base.standardizedFileURL.path]
        let onCard = CameraSync.saveFolder(cameras) == nil && CameraSync.onCard(base.appendingPathComponent("Cam1"))
        try? fm.removeItem(at: file)
        try? CameraSync.save(SyncSave(cameras: cameras, audioFirst: true, shownTimecode: nil))
        CameraSync.testCards = []
        check("sync save: never on a camera card", onCard && !fm.fileExists(atPath: file.path))
        check("sync save: clips on two drives aren't saved", CameraSync.saveFolder([SyncCamera(name: "", key: "", clips: [clip("/Volumes/X/a.mov", start: 0), clip("/Volumes/Y/b.mov", start: 0)])]) == nil)
        // Sync after cards were added: only the new ones move.
        let c = clip(paths[2], start: nil)
        let all = [a, b, c]
        check("sync save: new clips sync against what's placed, the rest held", CameraSyncModel.held(all, only: nil, fresh: [c.id]) == [a.id]
              && CameraSyncModel.held(all, only: nil, fresh: []).isEmpty && CameraSyncModel.held(all, only: c.id, fresh: []) == [a.id])
    }

    /// Recorder sound first (camera sound below, turned off), angles, markers on clips to check, the report.
    private static func syncResolvePiecesTest() {
        let camA = SyncCamera(name: "Cam A", key: "a", clips: [clip("/m/A1.mov", start: 0), clip("/m/A2.mov", start: 70, confidence: 0.5)])
        let recorder = SyncCamera(name: "Sound", key: "sound", clips: [clip("/m/R1.wav", start: 0, duration: 200, video: false)])
        let camB = SyncCamera(name: "Cam <B>", key: "b", clips: [clip("/m/B1.mov", start: 10), clip("/m/B2.mov", start: nil)])
        let cameras = [camA, recorder, camB]
        let first = CameraSyncExport.placements(cameras, rate: 25, recorderFirst: true)
        let plain = CameraSyncExport.placements(cameras, rate: 25)
        func tracks(_ list: [CameraSyncExport.Placement]) -> String { list.map { "\($0.camera) v\($0.videoTrack ?? 0) a\($0.audioTrack ?? 0)" }.joined(separator: ", ") }
        check("sync resolve: recorder sound on top, camera sound below and turned off",
              first.first { $0.camera == "Sound" }?.audioTrack == 1 && first.first { $0.camera == "Cam A" }?.audioTrack == 2 && first.first { $0.camera == "Cam <B>" }?.audioTrack == 3
              && CameraSyncExport.muted(first) == [2, 3] && first.first { $0.camera == "Cam <B>" }?.videoTrack == 2, tracks(first))
        check("sync resolve: off, as before", plain.first { $0.camera == "Cam A" }?.audioTrack == 1 && plain.first { $0.camera == "Sound" }?.audioTrack == 2
              && CameraSyncExport.muted(CameraSyncExport.placements([camA, camB], rate: 25, recorderFirst: true)).isEmpty, tracks(plain))
        let angles = CameraSyncExport.angles(first)
        func meta(_ path: String) -> [String: String]? { angles.first { $0[0] as? String == path }?[1] as? [String: String] }
        check("sync resolve: camera and angle in each clip's metadata", meta("/m/A2.mov") == ["Camera #": "Cam A", "Angle": "1"]
              && meta("/m/B1.mov") == ["Camera #": "Cam <B>", "Angle": "2"] && meta("/m/R1.wav") == ["Camera #": "Sound"], "\(angles)")
        let markers = CameraSyncExport.markers(first)
        check("sync resolve: a marker on the clip it isn't sure of", markers.count == 1 && markers[0][0] as? Int == 70 * 25
              && (markers[0][1] as? String)?.hasSuffix("A2.mov") == true, "\(markers)")
        let report = CameraSyncExport.report(cameras, name: "Set & Show")
        check("sync resolve: report per angle with the ones not synced", report.contains("<h2>Cam A</h2>") && report.contains("Cam &lt;B&gt;") && report.contains("B2.mov")
              && report.contains(String(localized: "Not synced")) && report.contains("Set &amp; Show") && report.contains("class=\"check\""))
    }

    /// One timeline per set: a gap over 3 h; the day changing (past midnight, a camera's wrong-day clock) doesn't split.
    private static func syncSetsTest() {
        let day1 = Date(timeIntervalSince1970: 1_777_600_000), day2 = day1.addingTimeInterval(86400)
        let cameras = [SyncCamera(name: "A", key: "a", clips: [clip("/m/1.mov", start: 0, created: day1), clip("/m/2.mov", start: 30, created: day2),
                                                              clip("/m/3.mov", start: 100, created: day2), clip("/m/4.mov", start: 100 + 4 * 3600),
                                                              clip("/m/5.mov", start: nil)]),
                       SyncCamera(name: "B", key: "b", clips: [clip("/m/6.mov", start: 120, created: day2)])]
        let sets = CameraSyncExport.sets(cameras)
        let names = sets.map { $0.flatMap(\.clips).map(\.name).joined(separator: "+") }
        check("sync sets: split on a long gap only, a day change kept together", names == ["1.mov+2.mov+3.mov+6.mov", "4.mov"]
              && sets[0].map(\.name) == ["A", "B"], names.joined(separator: " | "))
        let labels = CameraSyncExport.setNames(sets)
        check("sync sets: named by day, else numbered", labels.count == 2 && labels[0].count == 10 && labels[1] == String(localized: "Set \(2)"),
              labels.joined(separator: ", "))
        // A show past midnight: clips a few minutes apart either side of it stay one set, named by its first day.
        let late = Date(timeIntervalSince1970: 1_777_679_400)  // (any time; the next clip's date is the next day)
        let night = [SyncCamera(name: "A", key: "a", clips: [clip("/m/n1.mov", start: 0, created: late), clip("/m/n2.mov", start: 300, created: late.addingTimeInterval(86400))])]
        check("sync sets: a set past midnight stays one", CameraSyncExport.sets(night).count == 1)
        check("sync sets: one set when nothing's apart", CameraSyncExport.sets([cameras[1]]).count == 1 && CameraSyncExport.sets([]).isEmpty)
    }

    /// A recorder's split files as one lane: each piece right after the one before, from the surest piece.
    private static func syncRolloverTest() {
        let pieces = [clip("/r/ZOOM0001.WAV", start: 437, video: false, confidence: 0.4, timecode: 100),
                      clip("/r/ZOOM0001_0001.WAV", start: 500, duration: 60, video: false, confidence: 0.95, timecode: 160),
                      clip("/r/ZOOM0001_0002.WAV", start: nil, duration: 30, video: false, timecode: 220),
                      clip("/r/ZOOM0002.WAV", start: 900, video: false, confidence: 0.5, timecode: 600)]
        var cameras = [SyncCamera(name: "Sound", key: "sound", clips: pieces)]
        CameraSync.joinRollovers(&cameras)
        let starts = cameras[0].clips.map { $0.start ?? -1 }
        check("sync rollover: split files joined into one lane", starts == [440, 500, 560, 900] && cameras[0].clips[2].method == .audio, "\(starts)")
        var other = SyncClip(path: "/elsewhere/ZOOM0001_0001.WAV", duration: 60, hasAudio: true, timecode: 160)
        other.start = 1
        check("sync rollover: only back to back in one folder", !CameraSync.rollsOver(pieces[0], other) && CameraSync.rollsOver(pieces[0], pieces[1]) && !CameraSync.rollsOver(pieces[2], pieces[3]))
    }

    /// A folder with a saved sync dropped again: reopened, the new card's clip added as new; then proxies for the synced clips.
    private static func syncReopenAndProxiesTest(_ base: URL) async {
        let fm = FileManager.default
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else { return check("sync reopen: ffmpeg", false) }
        let one = base.appendingPathComponent("CamA/one.mov"), two = base.appendingPathComponent("CamB/two.mov")
        for file in [one, two] {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=gray:s=64x36:r=25:d=2", "-f", "lavfi", "-i", "sine=f=440:d=2",
                                 "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest", file.path]
            try? process.run()
            process.waitUntilExit()
        }
        guard var probed = CameraSync.probe(one, root: base, ffprobe: ffprobe)?.clip else { return check("sync reopen: clips made", false) }
        probed.path = one.standardizedFileURL.path
        probed.start = 3
        probed.method = .manual
        try? CameraSync.save(SyncSave(cameras: [SyncCamera(name: "Cam A", key: "folder:" + base.appendingPathComponent("CamA").path, clips: [probed])]))
        // Saved in CamA (its only clip's folder): dropping that folder's parent finds it through the clips there.
        check("sync reopen: a first card's sync saved in its folder", fm.fileExists(atPath: base.appendingPathComponent("CamA/" + CameraSync.saveName).path))
        let model = CameraSyncModel()
        model.add([base])
        for _ in 0..<200 where model.running || model.cameras.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        let reopened = model.clips.first { $0.name == "one.mov" }, added = model.clips.first { $0.name == "two.mov" }
        check("sync reopen: the saved sync comes back, a new card's clips added to sync against it",
              reopened?.start == 3 && reopened?.method == .manual && added != nil && added?.start == nil && model.fresh == Set([added?.id].compactMap { $0 })
              && model.cameras.first?.name == "Cam A", model.clips.map { "\($0.name) \($0.start ?? -1)" }.joined(separator: ", "))
        // Proxies for the synced clips, beside them in "Proxy", the original's name.
        check("sync proxies: offered for the synced clips only", model.needProxies.map(\.name) == ["one.mov"])
        model.makeProxies(.light)
        for _ in 0..<600 where model.proxyLine != nil || model.needProxies.count == 1 && model.done?.contains("1") != true { try? await Task.sleep(for: .milliseconds(50)) }
        let proxy = base.appendingPathComponent("CamA/Proxy/one.mov")
        check("sync proxies: made with the proxy maker, used for playback", fm.fileExists(atPath: proxy.path) && model.clips.first { $0.name == "one.mov" }?.proxy == proxy.path
              && model.needProxies.isEmpty && model.proxyLine == nil, "\(model.done ?? "-") \(model.problem ?? "")")
        // A proxy written meanwhile (by Resolve, another Mac) is kept, not replaced.
        let theirs = base.appendingPathComponent("CamB/Proxy/two.mov")
        try? fm.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("theirs".utf8).write(to: theirs)
        let kept = await OfficeProxies.encode(two, to: theirs, format: .light, ffmpeg: ffmpeg, ffprobe: ffprobe, progress: { _ in })
        check("sync proxies: one already there is kept", kept && (try? Data(contentsOf: theirs)) == Data("theirs".utf8)
              && ((try? fm.contentsOfDirectory(atPath: theirs.deletingLastPathComponent().path)) ?? []) == ["two.mov"])
        let pair = CameraSync.probe(proxy, root: base, ffprobe: ffprobe).map { [reopened!, $0.clip] }
        check("sync proxies: read as a proxy of its original next time", pair.map { CameraSync.proxies($0).count } == 1)
    }

    /// Offload → Sync: only the files whose checksum passed on every drive, from the copy that's here, named after the card.
    private static func syncOffloadTest(_ base: URL) {
        let fm = FileManager.default
        let drive = base.appendingPathComponent("Drive", isDirectory: true), card = drive.appendingPathComponent("2026-05-01 A004", isDirectory: true)
        let names = ["A004C001.mov", "A004C002.mov", "A004C003.mov", "A004C004.mov", "notes.txt", "A004C005.mov", "A004_C006.RDC/A004_C006.wav"]
        try? fm.createDirectory(at: card.appendingPathComponent("CLIPS/A004_C006.RDC"), withIntermediateDirectories: true)
        for name in names { fm.createFile(atPath: card.appendingPathComponent("CLIPS/" + name).path, contents: Data([1])) }
        // C005 was given another name in the copy (another card's C005 was there).
        try? fm.moveItem(at: card.appendingPathComponent("CLIPS/A004C005.mov"), to: card.appendingPathComponent("CLIPS/A004C005 2.mov"))
        func file(_ name: String, done: [Bool], problem: String? = nil) -> OffloadFile {
            OffloadFile(path: "CLIPS/" + name, size: 1, modified: .now, hash: "00", done: done, problem: problem)
        }
        var job = OffloadJob(name: "2026-05-01 A004", source: "/Volumes/A004", sourceVolume: "A004",
                             roots: ["/Volumes/Gone-\(UUID().uuidString)", drive.path], rootVolumes: ["Gone", "Drive"],
                             files: [file("A004C001.mov", done: [true, true]), file("A004C002.mov", done: [true, false]),
                                     file("A004C003.mov", done: [true, true], problem: "Checksum didn’t match"), file("A004C004.mov", done: [true, true]),
                                     file("notes.txt", done: [true, true]), file("A004C005.mov", done: [true, true]),
                                     // A RED take's own sound: not a sound recorder.
                                     file("A004_C006.RDC/A004_C006.wav", done: [true, true])])
        job.renames = ["CLIPS/A004C005.mov": "A004C005 2.mov"]
        job.card = "A004"
        let (items, cards) = CameraSync.offloadItems(job)
        check("sync offload: only checked clips, from the copy that's here, renames followed",
              items.map(\.file.lastPathComponent) == ["A004C001.mov", "A004C004.mov", "A004C005 2.mov"]
              && items.allSatisfy { $0.root.standardizedFileURL.path == drive.standardizedFileURL.path } && cards[card.standardizedFileURL.path] == "A004",
              items.map(\.file.path).joined(separator: ", ") + " \(cards)")
        // The card's camera takes the card's name; one found by serial keeps its own.
        var cameras = [SyncCamera(name: "2026-05-01 A004", key: "folder:" + card.path, clips: items.map { SyncClip(path: $0.file.standardizedFileURL.path) }),
                       SyncCamera(name: "Sony FX3", key: "serial:1", clips: [SyncClip(path: card.standardizedFileURL.path + "/CLIPS/X.mov")])]
        CameraSync.name(&cameras, cards: cards)
        check("sync offload: cameras named after their cards", cameras.map(\.name) == ["A004", "Sony FX3"], cameras.map(\.name).joined(separator: ", "))
        job.roots = ["/Volumes/Gone-\(UUID().uuidString)"]
        check("sync offload: no copy here, nothing", CameraSync.offloadItems(job).items.isEmpty)
    }
}
