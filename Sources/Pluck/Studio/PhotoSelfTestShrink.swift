import Foundation
import os

/// Archive (-PluckScreenshotOnly shrink), on generated clips in test "shares": sorting into rushes
/// and deliveries, the small-codec and age rules, the scan and its estimates, a real shrink of a 4K
/// ProRes clip to 1080p HEVC 10-bit High (checked, original and the project's proxies moved to the
/// share's folder to delete at the same path, inventories), putting it back, carrying on after a
/// stop, a file changed in between, masters to another folder for two roots, the free space looked
/// at there, two Macs on one run never making the same master, RAW, the always-on Mac's action,
/// waiting while someone edits, deliveries never touched, and clients and projects found on shares
/// laid out every which way.
extension PhotoSelfTest {
    static func shrinkTest() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-shrink-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("Share")
        let testVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = ["Share", "Share2", "Clout", "Wide Open"].map { (base.appendingPathComponent($0).path, "smb://test/" + $0.lowercased()) }
        // (OfficeGroup.place reads a path as /var/…, the temporary folder's other name.)
        OfficeGroup.testVolumes += OfficeGroup.testVolumes.map { ($0.prefix.replacingOccurrences(of: "/private/var/", with: "/var/"), $0.remount) }
        defer { OfficeGroup.testVolumes = testVolumes; try? fm.removeItem(at: base) }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("shrink: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        func make(_ url: URL, _ video: String, _ seconds: Double, _ codec: [String]) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "\(video):rate=25:duration=\(seconds),noise=alls=14:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=\(seconds),aformat=channel_layouts=4.0:sample_rates=48000",
                                        "-map", "0:v", "-map", "1:a", "-shortest"] + codec + ["-timecode", "10:00:00:00", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let prores = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67",
                      "-colorspace", "bt2020nc", "-c:a", "pcm_s24le"]
        let trash = base.appendingPathComponent("Trash")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let toTrash: @Sendable (URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent(UUID().uuidString + $0.lastPathComponent)) }

        // Rushes or deliveries.
        let k = { S.classify($0, root: "/V/Share", tags: $1).0 }
        check("shrink: rushes and deliveries by folder, file name and tags",
              k("/V/Share/Job/Rushes/x.mov", [:]) == .rushes && k("/V/Share/Job/Exports/x.mov", [:]) == .deliveries
              && k("/V/Share/Job/Levering/x.mp4", [:]) == .deliveries && k("/V/Share/Job/A-cam/x.mov", [:]) == .rushes
              && k("/V/Share/Job/Day 1/A001C003_220101.mov", [:]) == .rushes && k("/V/Share/Job/x/DJI_0042.MP4", [:]) == .rushes
              && k("/V/Share/Job/x/C0001.MP4", [:]) == .rushes && k("/V/Share/Job/x/cut.mov", ["encoder": "DaVinci Resolve Studio"]) == .deliveries
              && k("/V/Share/Job/Rushes/cut.mov", ["com.apple.proapps.studio.metadataDeliveryType": "x"]) == .deliveries
              && k("/V/Share/Job/x/clip.mov", ["com.apple.quicktime.model": "Test Cam"]) == .rushes && k("/V/Share/Job/x/clip.mov", [:]) == .other
              && S.classify("/V/Share/Job/Final/x.mov", root: "/V/Share", tags: [:]).1.contains("Final"))

        // The small-codec rule and the age rule.
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        var small = S.File(path: "/x/a.mp4", folder: "/x", size: 3_000_000_000, modified: old, seconds: 600, fps: 25, width: 1920, height: 1080, channels: 2, sampleRate: 48000)
        small.codec = "h264"
        var big = small, uhd = small
        big.codec = "prores"
        uhd.width = 3840; uhd.height = 2160
        var recent = big
        recent.projectChanged = .now.addingTimeInterval(-86400)
        check("shrink: 1080p H.264 left alone, 1080p ProRes and 4K H.264 shrunk", small.tooSmall(hd) && !big.tooSmall(hd) && !uhd.tooSmall(hd))
        check("shrink: a project with a recent file is left (age filter)", recent.tooRecent(months: 6) && !big.tooRecent(months: 6) && !recent.tooRecent(months: 0))

        // The test media: a share with a job of rushes (and its proxies), a recent job and an export.
        let job = share.appendingPathComponent("Projects/Job")
        let pro4k = job.appendingPathComponent("Rushes/A001C001.mov"), avc4k = job.appendingPathComponent("Rushes/clip.mp4")
        let tiny = job.appendingPathComponent("Rushes/tiny.mov"), avcHD = job.appendingPathComponent("Rushes/phone.mp4")
        let export = job.appendingPathComponent("Exports/Final.mov"), fresh = share.appendingPathComponent("Projects/New Job/Rushes/A002C001.mov")
        let proxy = job.appendingPathComponent("Rushes/Proxy/A001C001.mov")
        make(pro4k, "testsrc2=size=3840x2160", 2, prores)
        make(avc4k, "testsrc2=size=3840x2160", 2, ["-c:v", "libx264", "-preset", "ultrafast", "-b:v", "120M", "-c:a", "aac"])
        make(tiny, "testsrc2=size=64x36", 0.2, prores)
        make(avcHD, "testsrc2=size=1920x1080", 2, ["-c:v", "libx264", "-preset", "veryfast", "-b:v", "3M", "-c:a", "aac"])
        make(export, "testsrc2=size=640x360", 1, prores)
        make(fresh, "testsrc2=size=640x360", 1, prores)
        make(proxy, "testsrc2=size=160x90", 0.5, prores)
        try? Data("notes".utf8).write(to: fresh.deletingLastPathComponent().appendingPathComponent("notes.txt"))
        guard [pro4k, avc4k, tiny, avcHD, export, fresh, proxy].allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return check("shrink: test media made", false) }

        let looked = S.survey([share.appendingPathComponent("Projects")], ffprobe: ffprobe, minimum: 200_000, quiet: 0, rules: S.Rules())
        let scanned = looked.files
        check("shrink: proxies counted apart, not shrunk", looked.projects[job.path]?.proxyFolders == [proxy.deletingLastPathComponent().path]
              && !scanned.contains { $0.path == proxy.path } && (looked.projects[job.path]?.proxies ?? 0) > 0, "\(looked.projects[job.path].map { "\($0)" } ?? "none")")
        func file(_ url: URL) -> S.File? { scanned.first { $0.path == url.path } }
        let found = scanned.map { ($0.path as NSString).lastPathComponent }.sorted()
        check("shrink: scan finds the videos", found == ["A001C001.mov", "A002C001.mov", "Final.mov", "clip.mp4", "phone.mp4", "tiny.mov"], "\(found)")
        let estimate = file(pro4k)?.estimate(hd) ?? 0
        check("shrink: ProRes 4K and H.264 4K to shrink, with estimates",
              file(pro4k).map { $0.skip == nil && !$0.tooSmall(hd) && $0.kind == .rushes && $0.width == 3840 && $0.channels == 4 } == true
              && file(avc4k).map { $0.skip == nil && !$0.tooSmall(hd) } == true && estimate > 0 && estimate < (file(pro4k)?.size ?? 0) / 3,
              "\(String(describing: file(pro4k))) \(estimate)")
        check("shrink: a small file and an already-small one skipped",
              file(tiny)?.skip == String(localized: "Small") && file(avcHD).map { $0.skip == nil && $0.tooSmall(hd) } == true,
              "\(String(describing: file(tiny)?.skip)) \(String(describing: file(avcHD)))")
        check("shrink: export is a delivery, the new job is too recent",
              file(export)?.kind == .deliveries && file(fresh).map { $0.tooRecent(months: 6) } == true && file(pro4k).map { !$0.tooRecent(months: 6) } == true)

        // A real shrink, in place.
        let center = ShrinkCenter(store: base.appendingPathComponent("runs.json"), mac: "Test A")
        center.quiet = 0
        center.editing = { _ in false }
        center.trash = toTrash
        let original = ProjectArchive.streams(pro4k.path, ffprobe: ffprobe)
        let picked = [file(pro4k), file(avc4k)].compactMap { $0 }
        let id = center.add(picked, settings: hd, roots: [share.appendingPathComponent("Projects").path], proxies: [job.path: looked.projects[job.path]?.proxyFolders ?? []])
        await center.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let run = center.run(id)
        let done = run?.files.first { $0.path == pro4k.path }
        let holding = share.appendingPathComponent(S.holdingName)
        let moved = holding.appendingPathComponent("Projects/Job/Rushes/A001C001.mov")
        let master = ProjectArchive.streams(pro4k.path, ffprobe: ffprobe)
        let tagged = ProjectArchive.run(ffprobe, ["-v", "error", "-show_entries", "format_tags=pluck", "-of", "default=nw=1:nk=1", pro4k.path]).output
        check("shrink: master checked and in the original's place (frames, timecode, 4 channels, 1920×1080, 10-bit, colour tags)",
              done?.state == .done && master.frames == original.frames && master.timecode == "10:00:00:00" && master.channels == 4
              && master.width == 1920 && master.height == 1080 && master.pixelFormat.contains("10") && master.colour == original.colour
              && master.codec == "hevc" && tagged.contains("shrink"),
              "\(String(describing: done)) \(master) vs \(original)")
        let originalBytes = done?.size ?? 0, masterBytes = done?.masterSize ?? 0
        check("shrink: measured \(originalBytes) → \(masterBytes) bytes, \(String(format: "%.1f", Double(masterBytes) * 8 / 2 / 1_000_000)) Mb/s at 1080p High",
              masterBytes > 0 && masterBytes < originalBytes / 3)
        check("shrink: original moved to the folder to delete at its share path", fm.fileExists(atPath: moved.path)
              && ProjectArchive.streams(moved.path, ffprobe: ffprobe).width == 3840)
        let avcDone = run?.files.first { $0.path == avc4k.path }
        check("shrink: an .mp4's master keeps its name as .mov", avcDone?.state == .done && avcDone?.master == job.appendingPathComponent("Rushes/clip.mov").path
              && !fm.fileExists(atPath: avc4k.path) && fm.fileExists(atPath: holding.appendingPathComponent("Projects/Job/Rushes/clip.mp4").path),
              "\(String(describing: avcDone))")
        check("shrink: the project's proxies moved to the folder to delete", fm.fileExists(atPath: holding.appendingPathComponent("Projects/Job/Rushes/Proxy/A001C001.mov").path)
              && !fm.fileExists(atPath: proxy.path))
        let inventory = (try? String(contentsOf: holding.appendingPathComponent("Inventory.csv"), encoding: .utf8)) ?? ""
        let report = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).first { $0.hasPrefix("Shrink ") && $0.hasSuffix(".csv") }
            .flatMap { try? String(contentsOf: holding.appendingPathComponent($0), encoding: .utf8) } ?? ""
        check("shrink: inventory and the run's report with its projects", inventory.contains(pro4k.path) && inventory.contains("verified")
              && report.contains("project,files,bytes_before") && report.contains("\"Projects – Job\",2,"), report)
        // The path list, waiting to delete, freed so far, a recycle bin, Relink in Resolve (a fake bridge).
        let relinkCSV = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).first { $0.hasPrefix("Relink ") && $0.hasSuffix(".csv") }
            .flatMap { try? String(contentsOf: holding.appendingPathComponent($0), encoding: .utf8) } ?? ""
        let relinkJSON = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).first { $0.hasPrefix("Relink ") && $0.hasSuffix(".json") }
            .flatMap { try? Data(contentsOf: holding.appendingPathComponent($0)) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        check("shrink: old path → new path list written (CSV and JSON)", relinkCSV.contains("\"\(avc4k.path)\",\"\(job.appendingPathComponent("Rushes/clip.mov").path)\"")
              && relinkJSON.contains { $0["old"] == avc4k.path && $0["new"] == job.appendingPathComponent("Rushes/clip.mov").path } && relinkJSON.count == 2, relinkCSV)
        try? fm.createDirectory(at: share.appendingPathComponent("#recycle"), withIntermediateDirectories: true)
        let spaceModel = ArchiveModel(center: center)
        await spaceModel.refreshSpace()
        let waitingHere = spaceModel.waiting.first { $0.folder.path == holding.path }
        let movedMP4 = holding.appendingPathComponent("Projects/Job/Rushes/clip.mp4"), aside = base.appendingPathComponent("aside.mp4")
        check("shrink: waiting to delete is what's in the folder to delete; a recycle bin is said; nothing freed yet",
              waitingHere.map { $0.bytes == S.bytes(in: holding) && $0.bytes >= originalBytes + (avcDone?.size ?? 0) && $0.recycle == "#recycle" } == true
              && spaceModel.freedSoFar == 0, "\(spaceModel.waiting) \(spaceModel.freedSoFar)")
        try? fm.moveItem(at: movedMP4, to: aside)
        await spaceModel.refreshSpace()
        check("shrink: freed so far counts only what's gone from the folder to delete",
              spaceModel.freedSoFar == (avcDone.map { $0.size - ($0.masterSize ?? 0) } ?? -1), "\(spaceModel.freedSoFar)")
        try? fm.moveItem(at: aside, to: movedMP4)
        try? fm.removeItem(at: share.appendingPathComponent("#recycle"))
        final class Asked { var items: [[String: Any]] = [] }
        let bridged = Asked()
        let bridgeBefore = ShrinkRelink.bridge
        ShrinkRelink.bridge = { instruction in
            bridged.items.append(instruction)
            if instruction["action"] as? String == "projects" { return ["projects": ["Alpha", "Beta", "Gamma"]] }
            let map = instruction["map"] as? [String: String] ?? [:]
            return ["results": (instruction["projects"] as? [String] ?? []).map { ["project": $0, "replaced": map.count, "failed": [String]()] }]
        }
        let listed = (try? await ShrinkRelink.projects()) ?? []
        let relinked = (try? await ShrinkRelink.relink([center.run(id)].compactMap { $0 }, projects: ["Alpha", "Gamma"], drp: [])) ?? []
        let none = (try? await ShrinkRelink.relink([center.run(id)].compactMap { $0 }, projects: [], drp: [])) ?? [ShrinkRelink.Result(project: "x", replaced: 0, failed: [])]
        ShrinkRelink.bridge = bridgeBefore
        let sentMap = bridged.items.last?["map"] as? [String: String] ?? [:]
        check("shrink: Relink in Resolve (fake bridge) opens only the chosen projects and maps each archived file to its master",
              listed == ["Alpha", "Beta", "Gamma"] && bridged.items.count == 2 && bridged.items.last?["projects"] as? [String] == ["Alpha", "Gamma"]
              && sentMap == [pro4k.path: pro4k.path, avc4k.path: job.appendingPathComponent("Rushes/clip.mov").path]
              && relinked.map(\.project) == ["Alpha", "Gamma"] && relinked.allSatisfy { $0.replaced == 2 } && none.isEmpty, "\(sentMap) \(relinked)")
        let rescan = S.scan([share.appendingPathComponent("Projects")], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        check("shrink: masters aren't shrunk again, the folder to delete isn't looked in",
              rescan.first { $0.path == pro4k.path }?.skip == String(localized: "Already shrunk") && !rescan.contains { $0.path.contains(S.holdingName) })
        await center.putBack(id)
        check("shrink: Put Originals Back", center.run(id)?.files.allSatisfy { $0.state == .restored } == true
              && ProjectArchive.streams(pro4k.path, ffprobe: ffprobe).width == 3840 && fm.fileExists(atPath: avc4k.path)
              && !fm.fileExists(atPath: job.appendingPathComponent("Rushes/clip.mov").path) && !fm.fileExists(atPath: moved.path) && fm.fileExists(atPath: proxy.path))

        // Carrying on after a stop: one master made but not yet in place, one half written.
        let r1 = share.appendingPathComponent("Projects/Old/Rushes/A003C001.mov"), r2 = share.appendingPathComponent("Projects/Old/Rushes/A003C002.mov")
        let changed = share.appendingPathComponent("Projects/Old/Rushes/A003C003.mov")
        for url in [r1, r2, changed] { make(url, "testsrc2=size=640x360", 1, prores) }
        let old3 = S.scan([share.appendingPathComponent("Projects/Old")], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path }
        if old3.count == 3 {
            let store = base.appendingPathComponent("resume.json")
            let first = ShrinkCenter(store: store)
            let resumeID = first.add(old3, settings: hd, roots: [share.appendingPathComponent("Projects/Old").path])
            first.set(S.prepare(old3[0], settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0), in: resumeID)
            try? Data(repeating: 1, count: 1000).write(to: URL(fileURLWithPath: S.temporary(r2.path)))
            let handle = try? FileHandle(forWritingTo: changed)
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data(repeating: 0, count: 10))
            try? handle?.close()
            let wasWorking = first.run(resumeID)?.files.first?.state == .working
            let again = ShrinkCenter(store: store)
            again.quiet = 0
            again.editing = { _ in false }
            await again.resume(resumeID, ffmpeg: ffmpeg, ffprobe: ffprobe)
            let states = again.run(resumeID)?.files.map(\.state) ?? []
            check("shrink: carries on after a stop (master put in place, half-written one made again)", wasWorking && states.prefix(2) == [.done, .done]
                  && ProjectArchive.streams(r1.path, ffprobe: ffprobe).codec == "hevc" && ProjectArchive.streams(r2.path, ffprobe: ffprobe).codec == "hevc"
                  && !fm.fileExists(atPath: S.temporary(r2.path)), "\(states)")
            check("shrink: a file changed in between is skipped", states.last == .skipped
                  && again.run(resumeID)?.files.last?.note == String(localized: "Changed since it was found") && fm.fileExists(atPath: changed.path))
        } else {
            check("shrink: carries on after a stop", false, "\(old3.count) clips")
        }

        // Masters to another folder, two roots: the same folders under each root's name; originals stay.
        let rootA = share.appendingPathComponent("Projects/Dest A"), rootB = base.appendingPathComponent("Share2/Footage")
        let a1 = rootA.appendingPathComponent("Day 1/Card 1/C0001.MP4"), b1 = rootB.appendingPathComponent("Shoot/A001C009.mov")
        make(a1, "testsrc2=size=640x360", 1, prores + ["-f", "mov"])
        make(b1, "testsrc2=size=640x360", 1, prores)
        let dest = base.appendingPathComponent("Dest")
        let two = S.scan([rootA, rootB], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        let destCenter = ShrinkCenter(store: base.appendingPathComponent("dest.json"))
        destCenter.quiet = 0
        destCenter.editing = { _ in false }
        destCenter.trash = toTrash
        let destID = await destCenter.start(two, settings: hd, destination: dest, roots: [rootA.path, rootB.path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        let mA = dest.appendingPathComponent("Dest A/Day 1/Card 1/C0001.mov"), mB = dest.appendingPathComponent("Footage/Shoot/A001C009.mov")
        check("shrink: destination keeps each root's folders and names, originals stay",
              destCenter.run(destID)?.files.allSatisfy { $0.state == .done && $0.moved == nil } == true && two.count == 2
              && ProjectArchive.streams(mA.path, ffprobe: ffprobe).codec == "hevc" && ProjectArchive.streams(mB.path, ffprobe: ffprobe).codec == "hevc"
              && fm.fileExists(atPath: a1.path) && fm.fileExists(atPath: b1.path) && fm.fileExists(atPath: dest.appendingPathComponent("Inventory.csv").path),
              "\(destCenter.run(destID)?.files.map { "\($0.state) \($0.master ?? "") \($0.note ?? "")" } ?? [])")
        check("shrink: originals ready to delete listed", destCenter.run(destID).map { destCenter.readyToDelete($0).count } == 2)
        await destCenter.putBack(destID)
        check("shrink: undo in a destination removes that run's masters", !fm.fileExists(atPath: mA.path) && !fm.fileExists(atPath: mB.path)
              && fm.fileExists(atPath: a1.path))
        let spaceCenter = ShrinkCenter(store: base.appendingPathComponent("space.json"))
        spaceCenter.quiet = 0
        spaceCenter.editing = { _ in false }
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let freeBytes = OSAllocatedUnfairLock<Int64>(initialState: 0)
        try? fm.createDirectory(at: base.appendingPathComponent("Full"), withIntermediateDirectories: true)
        spaceCenter.freeSpace = { url in asked.withLock { $0.append(url.path) }; return freeBytes.withLock { $0 } }
        spaceCenter.capacity = { _ in 100_000_000_000 }
        let spaceID = await spaceCenter.start(Array(two), settings: hd, destination: base.appendingPathComponent("Full"), roots: [rootA.path, rootB.path],
                                              ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink: a nearly full drive pauses the run with why (files stay to do, none failed), looked at in the destination",
              spaceCenter.run(spaceID)?.files.allSatisfy { $0.state == .pending } == true && spaceCenter.run(spaceID)?.paused?.contains("Full") == true
              && asked.withLock { $0 }.allSatisfy { $0.hasPrefix(base.appendingPathComponent("Full").path) } && !asked.withLock { $0 }.isEmpty,
              "\(asked.withLock { $0 }) \(spaceCenter.run(spaceID)?.paused ?? "none")")
        // Room for each master but not for all: the one whose original is largest next to its master goes first.
        let estimates = two.map { $0.estimate(hd) }
        freeBytes.withLock { $0 = S.headroom(100_000_000_000) + Int64(Double(estimates.max() ?? 0) * 1.2) + 1 }
        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        spaceCenter.onFile = { [weak spaceCenter] id in
            MainActor.assumeIsolated {
                for file in spaceCenter?.run(id)?.files ?? [] where file.state == .done && !order.withLock({ $0.contains(file.path) }) { order.withLock { $0.append(file.path) } }
            }
        }
        await spaceCenter.resume(spaceID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let ratio = two.max { Double($0.size) / Double(max($0.estimate(hd), 1)) < Double($1.size) / Double(max($1.estimate(hd), 1)) }?.path
        check("shrink: resumed once there's room; nearly full, the best saving first", spaceCenter.run(spaceID)?.files.allSatisfy { $0.state == .done } == true
              && spaceCenter.run(spaceID)?.paused == nil && order.withLock { $0.first } == ratio && order.withLock { $0.count } == 2,
              "\(order.withLock { $0 }) best \(ratio ?? "") \(spaceCenter.run(spaceID)?.files.map { "\($0.state) \($0.note ?? "")" } ?? [])")

        // Two Macs on one run: each file made once.
        let shared = share.appendingPathComponent("Projects/Both")
        for index in 1...4 { make(shared.appendingPathComponent("A00\(index)C001.mov"), "testsrc2=size=640x360", 1, prores) }
        let four = S.scan([shared], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        let macA = ShrinkCenter(store: base.appendingPathComponent("a.json"), mac: "Mac A"), macB = ShrinkCenter(store: base.appendingPathComponent("b.json"), mac: "Mac B")
        for mac in [macA, macB] { mac.quiet = 0; mac.editing = { _ in false } }
        let both = base.appendingPathComponent("Both"), runID = UUID()
        macA.add(four, settings: hd, destination: both, roots: [shared.path], id: runID)
        macB.add(four.reversed(), settings: hd, destination: both, roots: [shared.path], id: runID)
        async let first: Void = macA.resume(runID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        async let second: Void = macB.resume(runID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        _ = await (first, second)
        let doneA = Set(macA.run(runID)?.files.filter { $0.state == .done }.map(\.path) ?? []), doneB = Set(macB.run(runID)?.files.filter { $0.state == .done }.map(\.path) ?? [])
        check("shrink: two Macs never make the same master (claims)", doneA.isDisjoint(with: doneB) && doneA.count + doneB.count == 4
              && !doneA.isEmpty && !doneB.isEmpty, "A \(doneA.count) B \(doneB.count) \(macB.run(runID)?.files.map { "\($0.state) \($0.note ?? "")" } ?? [])")

        // RAW: listed and ticked as rushes with a decoder; said why without one.
        let rawFolder = share.appendingPathComponent("Projects/Raw/Rushes")
        try? fm.createDirectory(at: rawFolder, withIntermediateDirectories: true)
        let stub = base.appendingPathComponent("pluck-raw"), clip = rawFolder.appendingPathComponent("A001_C002_0101AB_001.R3D")
        try? Data(repeating: 3, count: 400_000).write(to: clip)
        try? Data(repeating: 3, count: 300_000).write(to: rawFolder.appendingPathComponent("A001_C002_0101AB_002.R3D"))
        try? Data(repeating: 3, count: 300_000).write(to: rawFolder.appendingPathComponent("B001_C001.braw"))
        let rdc = rawFolder.appendingPathComponent("A002_C001_0202CD.RDC")
        try? fm.createDirectory(at: rdc, withIntermediateDirectories: true)
        for (name, count) in [("A002_C001_0202CD_001.R3D", 300_000), ("A002_C001_0202CD_002.R3D", 200_000), ("A002_C001_0202CD.RMD", 1000)] {
            try? Data(repeating: 4, count: count).write(to: rdc.appendingPathComponent(name))
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: rdc.appendingPathComponent(name).path)
        }
        for name in (try? fm.contentsOfDirectory(atPath: rawFolder.path)) ?? [] {
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: rawFolder.appendingPathComponent(name).path)
        }
        try? #"""
        #!/bin/sh
        while read -r line; do
          case "$line" in
            *'"op":"open"'*) echo '{"ok":true,"format":"r3d","width":64,"height":36,"fps":25,"frames":12,"timecode":"01:02:03:04","meta":{}}' ;;
            *) echo '{"ok":false,"problem":"no"}' ;;
          esac
        done
        """#.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let raws = S.scan([share.appendingPathComponent("Projects/Raw")], ffprobe: ffprobe, minimum: 200_000, quiet: 0, raw: ["r3d"],
                          open: { try RawHelperSource(url: $0, helper: stub) })
        let red = raws.first { $0.path == clip.path }, braw = raws.first { $0.path.hasSuffix(".braw") }
        let span = raws.first { $0.path.hasSuffix("A002_C001_0202CD_001.R3D") }
        check("shrink: a RED .RDC clip in two spans is one unit (its spans and .RMD go with it, one master from the first)",
              span.map { $0.skip == nil && $0.parts.count == 2 && $0.size == 501_000 && $0.parts.contains { $0.hasSuffix(".RMD") } } == true
              && !raws.contains { $0.path.hasSuffix("_002.R3D") }, "\(String(describing: span))")
        check("shrink: RAW listed as rushes and ticked by default, its spans go with it", raws.count == 3 && red?.skip == nil && red?.kind == .rushes
              && red.map { !$0.tooSmall(hd) && !$0.tooRecent(months: 6) } == true && red?.parts.count == 1 && red?.size == 700_000,
              "\(raws.map { "\($0.path) \($0.skip ?? "") \($0.kind)" })")
        check("shrink: RAW without its decoder says why", braw?.skip?.hasPrefix(String(localized: "Can’t shrink: this Pluck has no decoder for BRAW")) == true,
              braw?.skip ?? "none")

        // The always-on Mac: refused without Admin or Full Trust; files it can't see stay; an older one said in words.
        var viewer = OfficeRenderServer.Device(id: UUID(), name: "Viewer", secret: Data(), added: .now)
        viewer.role = "viewer"
        var admin = viewer
        admin.role = "admin"
        let officeCenter = ShrinkCenter(store: base.appendingPathComponent("office.json"))
        let sent = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(four.prefix(1).compactMap { ShrinkRemote.translated($0, ShrinkRemote.place) }))) ?? []
        let gone = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode([S.File(path: "smb://test/elsewhere\n/x.mov", folder: "smb://test/elsewhere\n/", size: 1, modified: old)]))) ?? []
        let settingsJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(hd))) ?? [:]
        let refused = (try? ShrinkRemote.start(["id": UUID().uuidString, "files": sent, "settings": settingsJSON], viewer, center: officeCenter, run: false)) == nil
        let accepted = try? ShrinkRemote.start(["id": UUID().uuidString, "files": sent, "settings": settingsJSON], admin, center: officeCenter, run: false)
        let unseen = try? ShrinkRemote.start(["id": UUID().uuidString, "files": gone, "settings": settingsJSON], admin, center: officeCenter, run: false)
        check("shrink: always-on Mac refuses a Viewer, takes an Admin's files, leaves files it can't see",
              refused && accepted?["started"] as? Int == 1 && unseen?["started"] as? Int == 0 && (unseen?["missing"] as? [String])?.count == 1
              && officeCenter.runs.first?.files.first?.path == four.first?.path,
              "\(String(describing: accepted)) \(String(describing: unseen)) \(four.first.map { "\($0.path) → \(String(describing: ShrinkRemote.place($0.path)))" } ?? "no files")")
        check("shrink: an older always-on Mac is said in words",
              ShrinkRemote.reason(OfficeLink.Failure.office(String(localized: "The host Mac doesn’t know how to do that."))) == String(localized: "The always-on Mac needs a newer Pluck"))

        // Waiting while someone edits, then carrying on once it's quiet.
        let waitClip = share.appendingPathComponent("Projects/Wait/A009C001.mov")
        make(waitClip, "testsrc2=size=640x360", 1, prores)
        let waitFiles = S.scan([waitClip.deletingLastPathComponent()], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        let waiter = ShrinkCenter(store: base.appendingPathComponent("wait.json"))
        let editing = OSAllocatedUnfairLock(initialState: true)
        waiter.quiet = 0
        waiter.editQuiet = 1
        waiter.editCheck = 0.4
        waiter.editing = { _ in editing.withLock { $0 } }
        let waitID = waiter.add(waitFiles, settings: hd, roots: [waitClip.deletingLastPathComponent().path])
        let going = Task { await waiter.resume(waitID, ffmpeg: ffmpeg, ffprobe: ffprobe) }
        try? await Task.sleep(for: .seconds(2))
        let paused = waiter.waitingForEdit && waiter.run(waitID)?.files.first?.state == .pending
        editing.withLock { $0 = false }
        await going.value
        check("shrink: pauses while someone edits, carries on once quiet", paused && waiter.run(waitID)?.files.first?.state == .done && !waiter.waitingForEdit)

        // Deliveries are never touched.
        if var delivery = file(export) {
            delivery.kind = .deliveries
            check("shrink: a delivery is never shrunk", S.prepare(delivery, settings: hd, holding: holding, ffmpeg: ffmpeg, ffprobe: ffprobe, quiet: 0).state == .skipped)
        }

        // Clients and projects on shares laid out every which way (sparse files: sizes without the bytes).
        func sparse(_ relative: String, _ bytes: UInt64) {
            let url = base.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) { try? handle.truncate(atOffset: bytes); try? handle.close() }
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        sparse("Clout/Brand A/Video/Factory Visit/002_Production/001_Video-Opnames/C0001.MP4", 300_000_000)
        sparse("Clout/Brand A/Video/Factory Visit/002_Production/002_Proxies/C0001.mov", 50_000_000)
        sparse("Clout/Brand A/Video/Factory Visit/002_Production/004_Audio/mix.wav", 10_000_000)
        sparse("Clout/_Backup/old.mov", 300_000_000)
        sparse("Clout/_New Client/Video/x.mov", 300_000_000)
        sparse("Clout/#recycle/x.mov", 300_000_000)
        sparse("Clout/_Small clients/Bakery/Video/Promo 2023/Rushes/A001.mov", 300_000_000)
        sparse("Clout/Brand A/Video/_New project/Rushes/x.mov", 300_000_000)
        sparse("Wide Open/Frontline/Rushes/A001C001.mov", 300_000_000)
        sparse("Wide Open/Frontline/Exports/Final.mov", 200_000_000)
        sparse("Wide Open/Frontline/Cache/render.bin", 20_000_000)
        sparse("Wide Open/Frontline/Adobe After Effects Auto-Save/anim.aep", 150_000_000)
        sparse("Wide Open/Frontline/Frontline_Animation_V2.mov", 200_000_000)
        sparse("Wide Open/Agency/Video/Roadshow/CITY A/Rushes/DJI_0001.MP4", 300_000_000)
        sparse("Wide Open/Agency/Video/Roadshow/CITY A/Rushes/Proxy/DJI_0001.mov", 20_000_000)
        sparse("Wide Open/Agency/Video/Roadshow/CITY B/Render/cut.mov", 100_000_000)
        sparse("Wide Open/Agency/Video/Roadshow/CITY B/Music/song.wav", 5_000_000)
        let layouts = S.survey([base.appendingPathComponent("Clout"), base.appendingPathComponent("Wide Open")], ffprobe: ffprobe, minimum: 200_000, quiet: 0, rules: S.Rules())
        let titles = Set(layouts.projects.values.map(\.title))
        check("shrink: clients and projects found in three layouts, a container of small clients, templates and _ folders skipped",
              titles == ["Brand A – Factory Visit", "Bakery – Promo 2023", "Frontline", "Agency – Roadshow"], "\(titles.sorted())")
        let visit = layouts.projects.values.first { $0.name == "Factory Visit" }, front = layouts.projects.values.first { $0.name == "Frontline" }
        check("shrink: each project's space by kind", visit.map { $0.rushes == 300_000_000 && $0.proxies == 50_000_000 && $0.other == 10_000_000 } == true
              && front.map { $0.proxies == 20_000_000 && $0.deliveries == 200_000_000 && $0.rushes >= 300_000_000 } == true,
              "\(String(describing: visit)) \(String(describing: front))")
        check("shrink: big files that aren't video listed", layouts.big.contains { $0.path.hasSuffix("anim.aep") && $0.reason == String(localized: "Not video") })
        let roadshow = base.appendingPathComponent("Wide Open/Agency/Video/Roadshow").path
        let shareWO = base.appendingPathComponent("Wide Open").path
        var rules = S.Rules()
        rules.marks[S.Rules.key(roadshow + "/CITY A", share: shareWO)] = .project
        rules.names[S.Rules.key(roadshow + "/CITY A", share: shareWO)] = "Roadshow City A"
        let split = S.detect(roadshow + "/CITY A/Rushes/DJI_0001.MP4", share: shareWO, rules: rules)
        rules.marks[S.Rules.key(roadshow + "/CITY A", share: shareWO)] = .part
        let joined = S.detect(roadshow + "/CITY A/Rushes/DJI_0001.MP4", share: shareWO, rules: rules)
        var renamed = S.Rules()
        renamed.names[S.Rules.key(roadshow, share: shareWO)] = "Tour"
        let regrouped = S.regroup(layouts, rules: renamed)
        check("shrink: the owner's corrections (a folder made a project, renamed, put back with its parent)",
              split?.project == "Roadshow City A" && split?.folder == roadshow + "/CITY A" && joined?.folder == roadshow
              && regrouped.projects[roadshow]?.title == "Agency – Tour", "\(String(describing: split)) \(String(describing: joined))")

        // Clips in several files and card structures.
        let u = { S.unit(of: URL(fileURLWithPath: $0), names: $1) }
        let chapters = u("/V/GoPro/GX010042.MP4", ["GX010042.MP4", "GX020042.MP4", "GL010042.LRF", "GX010043.MP4"])
        let later = u("/V/GoPro/GX020042.MP4", ["GX010042.MP4", "GX020042.MP4"])
        let older = u("/V/GoPro/GOPR0044.MP4", ["GOPR0044.MP4", "GP010044.MP4"])
        let single = u("/V/GoPro/GX010043.MP4", ["GX010042.MP4", "GX020042.MP4", "GX010043.MP4", "GL010043.LRF", "GX010043.THM"])
        check("shrink: GoPro chapters left alone with why, a single chapter keeps its LRF and THM beside it",
              chapters.skip == String(localized: "GoPro recording in 2 chapters") && later.skip != nil && older.skip != nil && single.skip == nil
              && single.sidecars.map { ($0 as NSString).lastPathComponent } == ["GL010043.LRF", "GX010043.THM"], "\(chapters) \(single)")
        let spanned = u("/V/A002_C001_0202CD.RDC/A002_C001_0202CD_001.R3D", ["A002_C001_0202CD_001.R3D", "A002_C001_0202CD_002.R3D", "A002_C001_0202CD.RMD", "A002_C001_0202CD.rtn"])
        let gap = u("/V/A002_C001_0202CD.RDC/A002_C001_0202CD_001.R3D", ["A002_C001_0202CD_001.R3D", "A002_C001_0202CD_003.R3D"])
        check("shrink: a RED clip's whole .RDC goes with it; a missing span leaves it alone", spanned.skip == nil && spanned.parts.count == 3
              && gap.skip == String(localized: "A part of this RED clip is missing"), "\(spanned) \(gap)")
        let sony = u("/V/Card/PRIVATE/M4ROOT/CLIP/C0001.MP4", ["C0001.MP4", "C0001M01.XML", "C0002.MP4", "C0002M01.XML"])
        let xf = u("/V/Card/CONTENTS/CLIPS001/AA0001/AA000101.MXF", ["AA000101.MXF", "AA000102.MXF", "AA0001.XML"])
        let xfOne = u("/V/Card/CONTENTS/CLIPS001/AA0002/AA000201.MXF", ["AA000201.MXF", "AA0002.XML", "AA0002.CIF"])
        let avchd = u("/V/Card/PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", ["00000.MTS", "00001.MTS"])
        let p2 = base.appendingPathComponent("P2/CONTENTS")
        for folder in ["VIDEO", "AUDIO", "CLIP"] { try? fm.createDirectory(at: p2.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let p2Clip = u(p2.appendingPathComponent("VIDEO/0001AB.MXF").path, ["0001AB.MXF"])
        check("shrink: Sony XAVC keeps its XML, a Canon XF clip in two files and P2 and AVCHD cards are left alone with why",
              sony.skip == nil && sony.sidecars.map { ($0 as NSString).lastPathComponent } == ["C0001M01.XML"]
              && xf.skip == String(localized: "Canon XF clip in 2 files") && xfOne.skip == nil && xfOne.sidecars.count == 2
              && avchd.skip != nil && p2Clip.skip == String(localized: "P2 card: picture and sound are separate files"),
              "\(sony) \(xf) \(xfOne) \(avchd) \(p2Clip)")
        let sonyClip = share.appendingPathComponent("Projects/Sony/PRIVATE/M4ROOT/CLIP/C0001.MP4"), sonyXML = sonyClip.deletingLastPathComponent().appendingPathComponent("C0001M01.XML")
        make(sonyClip, "testsrc2=size=640x360", 1, prores + ["-f", "mov"])
        try? Data("<NonRealTimeMeta/>".utf8).write(to: sonyXML)
        let sonyFiles = S.scan([share.appendingPathComponent("Projects/Sony")], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        let sonyCenter = ShrinkCenter(store: base.appendingPathComponent("sony.json"))
        sonyCenter.quiet = 0
        sonyCenter.editing = { _ in false }
        let sonyID = await sonyCenter.start(sonyFiles, settings: hd, roots: [share.appendingPathComponent("Projects/Sony").path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink: a Sony XAVC card's clip shrunk in its folders, its XML beside the master and a copy with the original",
              sonyCenter.run(sonyID)?.files.first?.state == .done && sonyFiles.first?.sidecars == [sonyXML.path]
              && fm.fileExists(atPath: sonyClip.deletingLastPathComponent().appendingPathComponent("C0001.mov").path) && fm.fileExists(atPath: sonyXML.path)
              && fm.fileExists(atPath: holding.appendingPathComponent("Projects/Sony/PRIVATE/M4ROOT/CLIP/C0001M01.XML").path)
              && fm.fileExists(atPath: holding.appendingPathComponent("Projects/Sony/PRIVATE/M4ROOT/CLIP/C0001.MP4").path),
              "\(sonyCenter.run(sonyID)?.files.map { "\($0.state) \($0.note ?? "")" } ?? [])")

        // The visual check: a right master passes; range, rotation and gamma mistakes fail.
        let visual = base.appendingPathComponent("Visual")
        let source = visual.appendingPathComponent("original.mov")
        make(source, "testsrc2=size=640x360", 2, prores + ["-color_range", "tv"])
        let sourceInfo = ProjectArchive.streams(source.path, ffprobe: ffprobe)
        func wrong(_ name: String, _ filter: String) -> String {
            let out = visual.appendingPathComponent(name).path
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-i", source.path, "-vf", filter, "-c:v", "libx264", "-preset", "veryfast", "-crf", "16",
                                        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-an", out])
            return out
        }
        let right = visual.appendingPathComponent("right.mov")
        try? ProjectArchive.encode(source.path, to: right, settings: hd, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let looks = [("right", right.path), ("x264", wrong("x264.mp4", "null")), ("range", wrong("range.mp4", "setparams=range=pc")),
                     ("rotated", wrong("rotated.mp4", "transpose=1")), ("gamma", wrong("gamma.mp4", "eq=gamma=0.8"))]
            .map { ($0.0, ProjectArchive.pictureProblems($0.1, source: source.path, original: sourceInfo, ffmpeg: ffmpeg, ffprobe: ffprobe)) }
        let verdict = Dictionary(uniqueKeysWithValues: looks)
        check("shrink: the picture check passes right masters and fails a video/full range swap, a 90° turn and a darker gamma",
              verdict["right"] == [] && verdict["x264"] == [] && verdict["range"]?.isEmpty == false && verdict["rotated"]?.isEmpty == false
              && verdict["gamma"]?.isEmpty == false, "\(looks)")

        // Dates, camera tags, colour tags (full range), rotation and pixel aspect kept on the master.
        let metaFolder = share.appendingPathComponent("Projects/Meta/Rushes"), plain = visual.appendingPathComponent("plain.mov"), metaClip = metaFolder.appendingPathComponent("A005C001.mov")
        try? fm.createDirectory(at: metaFolder, withIntermediateDirectories: true)
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1,noise=alls=20:allf=t",
                                    "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=4.0:sample_rates=48000", "-shortest",
                                    "-vf", "setsar=4/3", "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", "-pix_fmt", "yuv420p", "-color_primaries", "bt709",
                                    "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "pc", "-c:a", "pcm_s24le",
                                    "-metadata", "creation_time=2023-05-01T10:00:00.000000Z", "-metadata", "com.apple.quicktime.make=TestMake",
                                    "-metadata", "com.apple.quicktime.model=TestCam", "-movflags", "+use_metadata_tags", "-timecode", "10:00:00:00", plain.path])
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-display_rotation", "90", "-i", plain.path, "-c", "copy", "-map_metadata", "0",
                                    "-movflags", "+use_metadata_tags", metaClip.path])
        let shot = Date(timeIntervalSince1970: 1_683_000_000)
        try? fm.setAttributes([.creationDate: shot, .modificationDate: old], ofItemAtPath: metaClip.path)
        let metaBefore = ProjectArchive.streams(metaClip.path, ffprobe: ffprobe)
        let metaFiles = S.scan([share.appendingPathComponent("Projects/Meta")], ffprobe: ffprobe, minimum: 200_000, quiet: 0)
        let metaCenter = ShrinkCenter(store: base.appendingPathComponent("meta.json"))
        metaCenter.quiet = 0
        metaCenter.editing = { _ in false }
        let metaID = await metaCenter.start(metaFiles, settings: hd, roots: [share.appendingPathComponent("Projects/Meta").path], ffmpeg: ffmpeg, ffprobe: ffprobe)
        let metaAfter = ProjectArchive.streams(metaClip.path, ffprobe: ffprobe)
        let dates = try? fm.attributesOfItem(atPath: metaClip.path)
        let metaDone = metaCenter.run(metaID)?.files.first?.state == .done && metaAfter.codec == "hevc"
        let picture = metaBefore.rotation == 90 && metaAfter.rotation == 90 && metaAfter.sar == "4:3" && metaAfter.colour == metaBefore.colour && metaAfter.colour.last == "pc"
        let sound = metaAfter.layouts == ["4.0"] && metaAfter.bits == 10 && metaAfter.timecode == "10:00:00:00"
        let camera = metaAfter.tags["com.apple.quicktime.make"] == "TestMake" && metaAfter.tags["com.apple.quicktime.model"] == "TestCam"
            && metaAfter.tags["creation_time"] == metaBefore.tags["creation_time"]
        let created = (dates?[.creationDate] as? Date).map { abs($0.timeIntervalSince(shot)) < 2 } == true
        let modifiedKept = (dates?[.modificationDate] as? Date).map { abs($0.timeIntervalSince(old)) < 2 } == true
        check("shrink: the master keeps the shoot dates, camera tags, full range, rotation, pixel aspect, 4.0 layout and 10 bits",
              metaDone && picture && sound && camera && created && modifiedKept,
              "\(metaCenter.run(metaID)?.files.map { "\($0.state) \($0.note ?? "")" } ?? []) \(metaBefore) → \(metaAfter) \(String(describing: dates?[.creationDate]))")
        var stripped = metaBefore
        stripped.rotation = 0
        stripped.tags["com.apple.quicktime.make"] = nil
        stripped.colour[3] = "tv"
        check("shrink: the metadata check says what a master lost", ProjectArchive.metadataProblems(stripped, metaBefore).count == 3,
              "\(ProjectArchive.metadataProblems(stripped, metaBefore))")

        // A project's own size: Keep 4K and Skip, remembered per share; the client's switch still works.
        let rulesBefore = try? Data(contentsOf: S.Rules.url)
        defer { if let rulesBefore { try? rulesBefore.write(to: S.Rules.url) } else { try? fm.removeItem(at: S.Rules.url) } }
        let chooser = ArchiveModel(center: ShrinkCenter(store: base.appendingPathComponent("choose.json")))
        chooser.survey = looked
        if let project = looked.projects[job.path], let plainFile = file(pro4k) {
            let before = chooser.files.first { $0.path == pro4k.path }?.estimate(chooser.settings) ?? 0
            chooser.choose([project], .k4)
            let kept = chooser.files.first { $0.path == pro4k.path }
            let k4ok = chooser.settings.size == .k4 || (kept?.projectSettings?.size == .k4 && (kept?.estimate(chooser.settings) ?? 0) > before * 3)
            chooser.choose([project], .skip)
            let skipped = chooser.files.first { $0.path == pro4k.path }.map(chooser.reason)
            let again = ArchiveModel(center: ShrinkCenter(store: base.appendingPathComponent("choose2.json")))
            again.survey = looked
            let row = chooser.clients.flatMap(\.projects).first { $0.project.folder == job.path }
            check("shrink: Keep 4K sizes a project's masters at 4K, Skip leaves it (remembered per share), Default undoes it",
                  k4ok && skipped == String(localized: "Skipped") && !chooser.picked.contains { $0.project == job.path } && row?.dim == String(localized: "skipped")
                  && again.choices[job.path] == .skip && plainFile.projectSettings == nil,
                  "\(String(describing: kept?.projectSettings)) \(String(describing: skipped)) \(String(describing: row?.dim)) \(again.choices)")
            chooser.choose([project], nil)
            let back = chooser.files.first { $0.path == pro4k.path }.map(chooser.reason) ?? "x"
            chooser.select([project], false)
            let off = !chooser.picked.contains { $0.project == job.path }
            chooser.select([project], true)
            check("shrink: back to Default, the client switch still turns it off and on", chooser.choices.isEmpty && back == nil && off
                  && chooser.picked.contains { $0.project == job.path }, "\(String(describing: back))")
        } else {
            check("shrink: Keep 4K and Skip", false, "no job project")
        }
        await shrinkSafetyTest()
    }
}
