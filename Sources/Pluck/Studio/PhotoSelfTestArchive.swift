import Foundation

/// Archive Project (-PluckScreenshotOnly archive), on generated media in a temporary folder: a
/// Pluck project plus an FCPXML and an EDL using some of the clips; only what's used is copied,
/// every copy checked on two drives, a copy cut short carries on, the inventory is complete,
/// trimmed clips play and keep their handles, and the clean-up moves only what was listed, and
/// only once the archive is checked.
extension PhotoSelfTest {
    static func archiveTest() async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pluck-archive-\(UUID().uuidString)", isDirectory: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        defer {
            for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
            try? fm.removeItem(at: base)
        }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("archive: ffmpeg", false, "no ffmpeg")
        }
        let shoot = base.appendingPathComponent("Shoot"), renders = base.appendingPathComponent("Renders"), graphics = base.appendingPathComponent("Graphics")
        for folder in ["Shoot/Day 1/A", "Shoot/Day 1/B", "Shoot/Audio", "Renders", "Graphics", "NAS", "Drive 2", "Trim", "Trash"] {
            try? fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func make(_ relative: String, seconds: Int, codec: [String]) {
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=25:duration=\(seconds)",
                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-map", "0:v", "-map", "1:a"]
                                + codec + ["-timecode", "01:00:00:00", shoot.appendingPathComponent(relative).path])
        }
        let prores = ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"]
        make("Day 1/A/clip1.mov", seconds: 20, codec: prores)
        make("Day 1/A/clip2.mov", seconds: 10, codec: prores)
        make("Day 1/B/unused.mov", seconds: 5, codec: prores)
        make("Day 1/B/clip3.mp4", seconds: 20, codec: ["-c:v", "mpeg4", "-g", "25", "-q:v", "6", "-c:a", "aac"])
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=duration=10", shoot.appendingPathComponent("Audio/song.wav").path])
        try? Data(repeating: 7, count: 50_000).write(to: renders.appendingPathComponent("Final.mp4"))
        try? Data(repeating: 9, count: 2_000).write(to: graphics.appendingPathComponent("logo.png"))
        let clip1 = shoot.appendingPathComponent("Day 1/A/clip1.mov").path, clip2 = shoot.appendingPathComponent("Day 1/A/clip2.mov").path
        let clip3 = shoot.appendingPathComponent("Day 1/B/clip3.mp4").path, song = shoot.appendingPathComponent("Audio/song.wav").path
        guard [clip1, clip2, clip3, song].allSatisfy({ fm.fileExists(atPath: $0) }) else { return check("archive: test media made", false) }

        // The job: a Pluck project, an FCPXML (clip2 at 2–5 s) and an EDL (clip1 at 10–12 s, by timecode).
        var project = Project(name: "Test Job")
        project.clips = [ProjectClip(path: clip1, start: 5, end: 8), ProjectClip(path: clip3, start: 12, end: 14)]
        project.music = [ProjectMusic(path: song, at: 0, start: 0, end: 5)]
        let fcpxml = base.appendingPathComponent("Cut v2.fcpxml")
        try? Data("""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE fcpxml><fcpxml version="1.10"><resources><format id="r1" frameDuration="1/25s"/>
        <asset id="r2" name="clip2" start="3600s" duration="10s" hasVideo="1"><media-rep kind="original-media" src="\(URL(fileURLWithPath: clip2).absoluteString)"/></asset>
        </resources><library><event name="E"><project name="Cut v2"><sequence format="r1"><spine>
        <asset-clip ref="r2" offset="0s" start="3602s" duration="3s" name="clip2"/></spine></sequence></project></event></library></fcpxml>
        """.utf8).write(to: fcpxml)
        let edl = base.appendingPathComponent("Cut v3.edl")
        try? Data("""
        TITLE: Cut v3
        FCM: NON-DROP FRAME

        001  AX       V     C        01:00:10:00 01:00:12:00 00:00:00:00 00:00:02:00
        * FROM CLIP NAME: clip1.mov
        002  AX       V     C        01:00:00:00 01:00:01:00 00:00:02:00 00:00:03:00
        * FROM CLIP NAME: gone.mov

        """.utf8).write(to: edl)
        var sources = ProjectArchive.Sources(name: project.name, uses: ProjectArchive.uses(of: project))
        sources.pluck = project
        sources.projectFolder = shoot.path
        sources.renders = [renders.path]
        sources.extras = [graphics.path]
        sources.projectFiles = [fcpxml.path, edl.path]
        let fromXML = ProjectArchive.uses(file: fcpxml, search: [], ffprobe: ffprobe)
        let fromEDL = ProjectArchive.uses(file: edl, search: [shoot.path], ffprobe: ffprobe)
        sources.uses.merge(fromXML.uses) { $0 + $1 }
        sources.uses.merge(fromEDL.uses) { $0 + $1 }
        let xmlUse = fromXML.uses[clip2]?.first, edlUse = fromEDL.uses[clip1]?.first
        check("archive: FCPXML read", xmlUse.map { abs($0.start - 2) < 0.01 && abs($0.end - 5) < 0.01 && $0.timeline == "Cut v2" } == true, "\(fromXML.uses)")
        check("archive: EDL read by timecode", edlUse.map { abs($0.start - 10) < 0.05 && abs($0.end - 12) < 0.05 && $0.timeline == "Cut v3" } == true
              && fromEDL.missing == ["gone.mov"], "\(fromEDL.uses) missing \(fromEDL.missing)")

        // Caches: a steadied copy of a used clip (listed), another one (not).
        let steadied = Stabilizer.copyURL(for: clip1), other = Stabilizer.folder.appendingPathComponent("other-\(UUID().uuidString).mov")
        try? fm.createDirectory(at: Stabilizer.folder, withIntermediateDirectories: true)
        try? Data(repeating: 1, count: 4_000).write(to: steadied)
        try? Data(repeating: 2, count: 4_000).write(to: other)
        defer { try? fm.removeItem(at: steadied); try? fm.removeItem(at: other) }

        let plan = ProjectArchive.plan(sources, trimmed: false, ffprobe: ffprobe)
        let media = Set(plan.items.filter { $0.kind == .media }.map(\.relative))
        check("archive: only used media planned", media == ["Day 1/A/clip1.mov", "Day 1/A/clip2.mov", "Day 1/B/clip3.mp4", "Audio/song.wav"], "\(media.sorted())")
        check("archive: renders, extras and project files planned",
              Set(plan.items.filter { $0.kind != .media }.map(\.archived)) == ["Renders/Renders/Final.mp4", "Extras/Graphics/logo.png", "Project/Cut v2.fcpxml", "Project/Cut v3.edl"],
              "\(plan.items.filter { $0.kind != .media }.map(\.archived))")
        check("archive: caches found", plan.cleanables.map(\.path) == [steadied.path], "\(plan.cleanables.map(\.path))")

        // Nothing is cleaned before a checked archive.
        let trash = base.appendingPathComponent("Trash")
        func toTrash(_ url: URL) throws { try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + url.lastPathComponent)) }
        let early = ProjectArchive.clean(plan.cleanables, plan: plan, verified: false, trash: toTrash)
        check("archive: no clean-up before it's checked", early.moved.isEmpty && fm.fileExists(atPath: steadied.path))

        // Cut short before: clip2 already whole on the NAS, half of clip1 in its part file.
        let nas = base.appendingPathComponent("NAS"), drive2 = base.appendingPathComponent("Drive 2")
        let there = nas.appendingPathComponent("Test Job/Media/Day 1/A")
        try? fm.createDirectory(at: there, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: clip2, toPath: there.appendingPathComponent("clip2.mov").path)
        let whole = (try? Data(contentsOf: URL(fileURLWithPath: clip1))) ?? Data()
        try? whole.prefix(whole.count / 2).write(to: there.appendingPathComponent(".clip1.mov.pluckpart"))
        func inode(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
        let kept = inode(there.appendingPathComponent("clip2.mov").path)

        let run = ArchiveRun()
        await run.start(plan, pluck: project, targets: [nas, drive2], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive: done and checked", run.phase == .done && run.verified, "\(run.phase)")
        check("archive: a copy job gone from the queue isn't checked", !ProjectArchive.verified(run.jobs, expected: run.jobIDs.count + 1)
              && ProjectArchive.verified(run.jobs, expected: run.jobIDs.count))
        func xxh64(_ path: String) -> String {
            var hasher = XXH64()
            ((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()).withUnsafeBytes { hasher.update($0) }
            return String(format: "%016llx", hasher.digest())
        }
        for drive in [nas, drive2] {
            let folder = drive.appendingPathComponent("Test Job")
            let copied = Set(OffloadCenter.files(in: folder.appendingPathComponent("Media")).map(\.path).filter { !$0.hasSuffix(".mhl") })
            check("archive: only used media copied to \(drive.lastPathComponent)", copied == media, "\(copied.sorted())")
            check("archive: copies match on \(drive.lastPathComponent)",
                  plan.items.allSatisfy { xxh64(folder.appendingPathComponent($0.archived).path) == xxh64($0.source) })
            check("archive: MHL beside the media on \(drive.lastPathComponent)",
                  OffloadCenter.files(in: folder.appendingPathComponent("Media")).contains { $0.path.hasSuffix(".mhl") })
            let csv = (try? String(contentsOf: folder.appendingPathComponent("Inventory.csv"), encoding: .utf8)) ?? ""
            let rows = csv.split(separator: "\n").dropFirst()
            check("archive: inventory complete on \(drive.lastPathComponent)",
                  rows.count == plan.items.count + 1 && rows.allSatisfy { $0.range(of: #",[0-9a-f]{16},"#, options: .regularExpression) != nil }
                  && csv.contains("Cut v2") && csv.contains("Cut v3") && csv.contains("Test Job")
                  && fm.fileExists(atPath: folder.appendingPathComponent("Inventory.html").path), csv)
        }
        check("archive: a copy cut short carries on", inode(there.appendingPathComponent("clip2.mov").path) == kept
              && !fm.fileExists(atPath: there.appendingPathComponent(".clip1.mov.pluckpart").path))
        let relinked = try? JSONDecoder.iso.decode(Project.self, from: Data(contentsOf: nas.appendingPathComponent("Test Job/Project/Test Job.pluckproject")))
        check("archive: project points at the archive", relinked.map { copy in
            copy.id != project.id && copy.clips.allSatisfy { $0.path.hasPrefix(nas.path + "/Test Job/Media/") && fm.fileExists(atPath: $0.path) }
                && copy.music.first?.path.hasPrefix(nas.path) == true
        } == true, "\(relinked?.clips.map(\.path) ?? [])")

        // Clean-up: only what was listed, never an original, into the (test) Trash.
        let chosen = plan.cleanables + [ProjectArchive.Cleanable(path: other.path, size: 0, label: "x", suggested: true),
                                        ProjectArchive.Cleanable(path: clip1, size: 0, label: "x", suggested: true)]
        let left = run.clean(chosen, trash: toTrash)
        check("archive: clean-up moves only the listed caches", run.cleaned == [steadied.path] && Set(left) == [other.path, clip1]
              && !fm.fileExists(atPath: steadied.path) && fm.fileExists(atPath: other.path) && fm.fileExists(atPath: clip1)
              && ((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).count == 1, "moved \(run.cleaned) left \(left)")

        // Trimmed: the parts used and 1 s each side, playable, with the timecode moved on.
        let trimPlan = ProjectArchive.plan(sources, trimmed: true, handles: 1, minimumLength: 0, ffprobe: ffprobe)
        let wanted = trimPlan.items.first { $0.original == clip1 }?.trim
        check("archive: trim plan with handles", wanted == 4...13 && trimPlan.items.first { $0.original == song }?.trim == nil, "\(String(describing: wanted))")
        let trimRun = ArchiveRun()
        await trimRun.start(trimPlan, pluck: project, targets: [base.appendingPathComponent("Trim")], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive: trimmed archive checked", trimRun.phase == .done && trimRun.verified, "\(trimRun.phase)")
        let folder = base.appendingPathComponent("Trim/Test Job")
        for original in [clip1, clip2, clip3] {
            guard let item = trimRun.plan?.items.first(where: { $0.original == original }), let kept = item.trim,
                  let need = trimPlan.items.first(where: { $0.original == original })?.trim else {
                check("archive: \((original as NSString).lastPathComponent) trimmed", false); continue
            }
            let piece = folder.appendingPathComponent(item.archived).path
            let length = ProjectArchive.probe(piece, ffprobe: ffprobe).duration ?? 0
            let plays = ProjectArchive.run(ffmpeg, ["-nostdin", "-v", "error", "-i", piece, "-f", "null", "-"]).status == 0
            check("archive: \((original as NSString).lastPathComponent) trimmed, plays, keeps its handles",
                  plays && kept.lowerBound <= need.lowerBound + 0.001 && length >= need.upperBound - kept.lowerBound - 0.1 && length < 19,
                  "kept \(kept) need \(need) length \(length)")
        }
        let code = ProjectArchive.probe(folder.appendingPathComponent("Media/Day 1/A/clip1.mov").path, ffprobe: ffprobe).timecode ?? -1
        check("archive: trimmed timecode moved on", abs(code - (3600 + 4)) < 0.05, "\(code)")
        let again = ArchiveRun()
        await again.start(trimPlan, pluck: project, targets: [base.appendingPathComponent("Trim")], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive: the same archive again matches what's there", again.phase == .done && again.verified, "\(again.phase)")
        let trimmedProject = try? JSONDecoder.iso.decode(Project.self, from: Data(contentsOf: folder.appendingPathComponent("Project/Test Job.pluckproject")))
        check("archive: trimmed project times moved", trimmedProject?.clips.first.map { abs($0.start - 1) < 0.01 && abs($0.end - 4) < 0.01 } == true,
              "\(trimmedProject?.clips.map { ($0.start, $0.end) } ?? [])")
        await archiveMasters(base: base, ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// Archive masters on generated clips (ProRes and H.264 with timecode and 4 sound channels,
    /// high bitrate): each level keeps frames, timecode and channels and the compact ones are
    /// smaller; a cut-short master fails its check; the archive points at the masters; only
    /// checked originals can go to the Trash. Raw through a stand-in decoder (the real SDKs
    /// need real footage).
    private static func archiveMasters(base: URL, ffmpeg: String, ffprobe: String) async {
        typealias M = ProjectArchive.MasterSettings
        let fm = FileManager.default
        let shoot = base.appendingPathComponent("MShoot/Day 1")
        try? fm.createDirectory(at: shoot, withIntermediateDirectories: true)
        let four = ["-filter_complex", "[1:a]pan=4c|c0=c0|c1=c0|c2=c0|c3=c0[a]", "-map", "0:v", "-map", "[a]"]
        let pro = shoot.appendingPathComponent("A001.mov").path, avc = shoot.appendingPathComponent("B001.mp4").path, kept = shoot.appendingPathComponent("C001.mov").path
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3,noise=alls=12:allf=t",
                                    "-f", "lavfi", "-i", "sine=f=440:d=3:sample_rate=48000"] + four
                           + ["-c:v", "prores_ks", "-profile:v", "3", "-c:a", "pcm_s24le", "-timecode", "01:00:00:00", pro])
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30000/1001:duration=3,noise=alls=12:allf=t",
                                    "-f", "lavfi", "-i", "sine=f=440:d=3"] + four
                           + ["-c:v", "libx264", "-qp", "8", "-pix_fmt", "yuv420p", "-c:a", "aac", "-timecode", "10:00:00;00", avc])
        ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=25:duration=2", "-c:v", "prores_ks", kept])
        guard [pro, avc, kept].allSatisfy({ fm.fileExists(atPath: $0) }) else { return check("archive masters: test clips made", false) }
        func size(_ path: String) -> Int64 { Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var taken: Set<String> = ["a/clip.mov"]
        let names = ["a/clip.mov", "a/clip.mp4", "a/clip.MP4", "a/other.mxf"].map { ProjectArchive.masterRelative($0, taken: &taken) }
        check("archive masters: every master gets its own name", names == ["a/clip.mov.mov", "a/clip.mp4.mov", "a/clip 2.mov", "a/other.mov"], "\(names)")
        func item(_ path: String) -> ProjectArchive.Item {
            ProjectArchive.Item(root: shoot.deletingLastPathComponent().path, relative: "Day 1/" + (path as NSString).lastPathComponent, into: "Media",
                                size: size(path), modified: .now, kind: .media, original: path)
        }

        check("archive masters: sizes fit, aspect kept, never larger",
              M.compact4K.fit(8192, 4320) == (3840, 2024) && M.compact4K.fit(2160, 3840) == (2160, 3840) && M(size: .hd).fit(6144, 3240) == (1920, 1012)
              && M.compact4K.fit(640, 360) == (640, 360), "\(M.compact4K.fit(8192, 4320))")

        // Each level on both clips.
        var compactMaster: String?
        for (name, settings) in [("master", M.master), ("compact", M.compact), ("compact 4K", M.compact4K), ("compact small 1080p", M(size: .hd, quality: .small))] {
            let into = base.appendingPathComponent("Masters \(name)")
            let made = ProjectArchive.makeMasters([item(pro), item(avc)], settings: [pro: settings, avc: settings], into: into, ffmpeg: ffmpeg, ffprobe: ffprobe)
            for original in [pro, avc] {
                let label = "\(name) \((original as NSString).lastPathComponent)"
                guard let result = made.checks[original], let master = made.items.first(where: { $0.original == original }) else {
                    check("archive masters: \(label) made", false, "\(made.notes)"); continue
                }
                let source = ProjectArchive.streams(original, ffprobe: ffprobe), got = ProjectArchive.streams(master.source, ffprobe: ffprobe)
                check("archive masters: \(label) keeps frames, timecode, 4 channels, rate",
                      result.ok && got.frames == source.frames && got.timecode == source.timecode && got.channels == 4 && got.sampleRate == source.sampleRate
                      && abs(got.fps - source.fps) < 0.0001 && master.relative.hasSuffix(".mov") && got.audioCodecs.allSatisfy { $0.hasPrefix("pcm_") }
                      && got.reel != nil, "\(result.problems) \(got)")
                let saving = 100 - Int(Double(result.size) * 100 / Double(result.originalSize))
                check("archive masters: \(label) \(result.originalSize / 1000) kB → \(result.size / 1000) kB (saves \(saving)%)",
                      settings.codec == .prores || result.size < result.originalSize, "\(result.size) of \(result.originalSize)")
                if name == "compact", original == pro { compactMaster = master.source }
            }
        }

        // A master cut short fails its check: bytes missing, and frames missing.
        if let compactMaster {
            let source = ProjectArchive.streams(pro, ffprobe: ffprobe)
            let data = (try? Data(contentsOf: URL(fileURLWithPath: compactMaster))) ?? Data()
            let cut = base.appendingPathComponent("cut.mov"), short = base.appendingPathComponent("short.mov")
            try? data.prefix(data.count / 2).write(to: cut)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-i", compactMaster, "-t", "2", "-map", "0:v", "-map", "0:a", "-c", "copy", "-timecode", "01:00:00:00", short.path])
            let broken = ProjectArchive.verify(cut.path, against: source, ffmpeg: ffmpeg, ffprobe: ffprobe)
            let shorter = ProjectArchive.verify(short.path, against: source, ffmpeg: ffmpeg, ffprobe: ffprobe)
            check("archive masters: a cut-short master fails its check", !broken.isEmpty && !shorter.isEmpty
                  && ProjectArchive.verify(compactMaster, against: source, ffmpeg: ffmpeg, ffprobe: ffprobe).isEmpty, "\(broken) \(shorter)")
        } else {
            check("archive masters: a cut-short master fails its check", false, "no compact master")
        }

        // The estimate, from a short test encode.
        let ratios = ProjectArchive.estimate([item(pro), item(avc)], settings: [M.master, M.compact], ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("archive masters: estimate from a test encode", (ratios[M.compact] ?? 1) < 1 && ratios[M.master] != nil, "\(ratios)")

        // A whole archive with masters: the project and an FCPXML point at them, the clean-up only
        // takes checked originals.
        var project = Project(name: "Master Job")
        project.clips = [ProjectClip(path: pro, start: 0, end: 2), ProjectClip(path: avc, start: 1, end: 2), ProjectClip(path: kept, start: 0, end: 1)]
        let fcpxml = base.appendingPathComponent("Masters cut.fcpxml")
        try? Data("""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE fcpxml><fcpxml version="1.10"><resources><format id="r1" frameDuration="1/25s"/>
        <asset id="r2" name="A001" start="3600s" duration="3s" hasVideo="1"><media-rep kind="original-media" src="\(URL(fileURLWithPath: pro).absoluteString)"/></asset>
        </resources><library><event name="E"><project name="Masters cut"><sequence format="r1"><spine>
        <asset-clip ref="r2" offset="0s" start="3600s" duration="2s" name="A001"/></spine></sequence></project></event></library></fcpxml>
        """.utf8).write(to: fcpxml)
        var sources = ProjectArchive.Sources(name: project.name, uses: ProjectArchive.uses(of: project))
        sources.pluck = project
        sources.projectFiles = [fcpxml.path]
        let plan = ProjectArchive.plan(sources, trimmed: false, ffprobe: ffprobe)
        let target = base.appendingPathComponent("MNAS")
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let run = ArchiveRun()
        await run.start(plan, pluck: project, targets: [target], ffmpeg: ffmpeg, ffprobe: ffprobe, settings: [pro: .compact, avc: .compact, kept: .original])
        let folder = target.appendingPathComponent("Master Job")
        check("archive masters: archive with masters done and checked", run.phase == .done && run.verified && run.masters.count == 2
              && run.masters.values.allSatisfy(\.ok), "\(run.phase) \(run.notes)")
        let media = Set(OffloadCenter.files(in: folder.appendingPathComponent("Media")).map(\.path).filter { !$0.hasSuffix(".mhl") })
        check("archive masters: masters archived instead of the originals", media == ["A001.mov", "B001.mov", "C001.mov"]
              && size(folder.appendingPathComponent("Media/A001.mov").path) < size(pro)
              && !fm.fileExists(atPath: folder.appendingPathComponent(".Masters").path), "\(media.sorted())")
        let relinked = try? JSONDecoder.iso.decode(Project.self, from: Data(contentsOf: folder.appendingPathComponent("Project/Master Job.pluckproject")))
        check("archive masters: project points at the masters", relinked.map { copy in
            copy.clips.map(\.path) == ["A001.mov", "B001.mov", "C001.mov"].map { folder.appendingPathComponent("Media/" + $0).path }
                && copy.clips.allSatisfy { fm.fileExists(atPath: $0.path) }
        } == true, "\(relinked?.clips.map(\.path) ?? [])")
        let relink = (try? String(contentsOf: folder.appendingPathComponent("Relink.csv"), encoding: .utf8)) ?? ""
        let masterXML = (try? String(contentsOf: folder.appendingPathComponent("Project/Masters cut (masters).fcpxml"), encoding: .utf8)) ?? ""
        let inventory = (try? String(contentsOf: folder.appendingPathComponent("Inventory.csv"), encoding: .utf8)) ?? ""
        let page = (try? String(contentsOf: folder.appendingPathComponent("Inventory.html"), encoding: .utf8)) ?? ""
        check("archive masters: relink list, FCPXML for the masters, inventory with checks and totals",
              relink.split(separator: "\n").count == 3 && relink.contains(pro) && relink.contains(avc) && !relink.contains(kept)
              && masterXML.contains(folder.appendingPathComponent("Media/A001.mov").absoluteString) && !masterXML.contains(URL(fileURLWithPath: pro).absoluteString)
              && inventory.contains("frames, timecode, sound, plays") && page.contains("saves"), relink + inventory)

        // Clean-up: never before the archive is checked, never an original without a checked master.
        let trash = base.appendingPathComponent("MTrash")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func toTrash(_ url: URL) throws { try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + url.lastPathComponent)) }
        let originals = run.replacedOriginals
        check("archive masters: originals offered with their masters", Set(originals.map(\.path)) == [pro, avc]
              && originals.allSatisfy { $0.master.map { fm.fileExists(atPath: $0) } == true && !$0.suggested })
        let early = ProjectArchive.clean(originals, plan: plan, verified: false, masters: [pro: folder.path], trash: toTrash)
        check("archive masters: no originals go before the archive is checked", early.moved.isEmpty && fm.fileExists(atPath: pro))
        let left = run.clean(originals + [ProjectArchive.Cleanable(path: kept, size: 0, label: "x", suggested: true, master: folder.path)], trash: toTrash)
        check("archive masters: only checked originals go to the Trash", Set(run.cleaned) == [pro, avc] && left == [kept]
              && !fm.fileExists(atPath: pro) && !fm.fileExists(atPath: avc) && fm.fileExists(atPath: kept), "moved \(run.cleaned) left \(left)")

        await rawMasters(base: base, ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// Raw: the frames from the decoder (here a stand-in that answers like pluck-raw) in log, to
    /// a master with the clip's timecode and frame count.
    private static func rawMasters(base: URL, ffmpeg: String, ffprobe: String) async {
        let folder = base.appendingPathComponent("Raw")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = folder.appendingPathComponent("pluck-raw"), clip = folder.appendingPathComponent("A001_C002.R3D")
        try? Data(repeating: 3, count: 400_000).write(to: clip)
        try? #"""
        #!/bin/sh
        while read -r line; do
          case "$line" in
            *'"op":"open"'*) echo '{"ok":true,"format":"r3d","width":64,"height":36,"fps":23.976,"frames":12,"timecode":"01:02:03:04","meta":{"camera_model":"Test Cam"}}' ;;
            *'"op":"frame"'*)
              buffer=$(printf "%s" "$line" | sed 's/.*"buffer":"\([^"]*\)".*/\1/' | sed 's/\\\//\//g')
              dd if=/dev/urandom of="$buffer" bs=18432 count=1 conv=notrunc 2>/dev/null
              echo '{"ok":true,"width":64,"height":36}' ;;
            *) echo '{"ok":false,"problem":"no"}' ;;
          esac
        done
        """#.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let open: @Sendable (URL) throws -> RawSource = { try RawHelperSource(url: $0, helper: stub) }
        let item = ProjectArchive.Item(root: base.path, relative: "Raw/A001_C002.R3D", into: "Media", size: 400_000, modified: .now, kind: .media, original: clip.path)
        let made = ProjectArchive.makeMasters([item], settings: [clip.path: .compact], into: base.appendingPathComponent("RawMasters"), ffmpeg: ffmpeg, ffprobe: ffprobe, open: open)
        let master = made.items.first
        let got = master.map { ProjectArchive.streams($0.source, ffprobe: ffprobe) }
        check("archive masters: raw (stand-in decoder) to a log master with its timecode and frames",
              made.checks[clip.path]?.ok == true && master?.relative == "Raw/A001_C002.mov" && got?.frames == 12 && got?.timecode == "01:02:03:04"
              && got?.colour.first == "unknown" && got?.colour[2] == "bt709" && abs((got?.fps ?? 0) - 24000 / 1001) < 0.001,
              "\(made.checks[clip.path]?.problems ?? []) \(made.notes) \(String(describing: got))")
        if RawHelperSource.formats.isEmpty {
            skip("archive masters: real RED / Blackmagic RAW", "this build has no raw decoder")
        } else {
            skip("archive masters: real RED / Blackmagic RAW", "decoder present (\(RawHelperSource.formats.sorted().joined(separator: ", "))), no raw test footage here")
        }
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
