import AppKit

/// Delivery Check (-PluckScreenshotOnly deliverycheck): clips made with ffmpeg in the test home. Transitions (dissolve,
/// fade to black, dip to white, whip pan, flash, wipe) are notes, not problems; a stray frame, a black flash and a
/// black gap are reported; silence at a fade is a note; a spec's codec, bitrate and colour are checked; and the
/// PDF, CSV and Resolve marker files are written.
extension PhotoSelfTest {
    static func deliveryCheckTest() async {
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            return check("delivery: ffmpeg", false, "no ffmpeg")
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("DeliveryCheckTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let size = "640x360"
        let a = "testsrc2=s=\(size):r=25", b = "mandelbrot=s=\(size):r=25", other = "life=s=\(size):r=25:mold=10:ratio=0.5:seed=7"
        let tone = "sine=f=440:r=48000"
        let encode = ["-c:v", "mpeg4", "-q:v", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-shortest"]
        func make(_ name: String, _ inputs: [String], _ graph: String, extra: [String] = []) async -> URL {
            let file = folder.appendingPathComponent(name + ".mov")
            _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y"] + inputs.flatMap { ["-f", "lavfi", "-i", $0] }
                                           + ["-filter_complex", graph, "-map", "[v]", "-map", "\(inputs.count - 1)"] + encode + extra + [file.path])
            return file
        }
        func segments(_ firstLength: Double, _ edit: String, _ frames: Int) -> String {
            // A then B, the last `frames` of A and the first of B through `edit` (blur, brightness).
            let cut = Double(frames) / 25
            return "[0]split[a1][a2];[a1]trim=end=\(firstLength),setpts=PTS-STARTPTS[s1];[a2]trim=start=\(firstLength),setpts=PTS-STARTPTS,\(edit)[s2];"
                + "[1]split[b1][b2];[b1]trim=end=\(cut),setpts=PTS-STARTPTS,\(edit)[s3];[b2]trim=start=\(cut),setpts=PTS-STARTPTS[s4];"
                + "[s1][s2][s3][s4]concat=n=4:v=1:a=0[v]"
        }
        let clips: [(String, URL)] = [
            ("dissolve", await make("dissolve", ["\(a):d=3", "\(b),trim=duration=3", "\(tone):d=5"], "[0][1]xfade=transition=fade:duration=1:offset=2[v]")),
            ("fade to black", await make("fadeblack", ["\(a):d=3", "color=black:s=\(size):r=25:d=0.4", "\(b),trim=duration=2",
                                                       "aevalsrc=0.3*sin(2*PI*440*t)*(1-between(t\\,3\\,3.4)):s=48000:d=5.4"],
                                         "[0]fade=t=out:st=2.2:d=0.8[f];[f][1][2]concat=n=3:v=1:a=0[v]")),
            ("dip to white", await make("dipwhite", ["\(a):d=3", "\(b),trim=duration=3", "\(tone):d=5"], "[0][1]xfade=transition=fadewhite:duration=1:offset=2[v]")),
            ("wipe", await make("wipe", ["\(a):d=3", "\(b),trim=duration=3", "\(tone):d=5"], "[0][1]xfade=transition=wipeleft:duration=0.8:offset=2[v]")),
            ("whip pan", await make("whip", ["\(a):d=2.12", "\(b),trim=duration=2.12", "\(tone):d=5"], segments(2, "avgblur=sizeX=90:sizeY=1", 3))),
            ("flash", await make("flash", ["\(a):d=2.08", "\(b),trim=duration=2.08", "\(tone):d=5"], segments(2, "eq=brightness=0.5:contrast=0.6", 2))),
        ]
        let reported: [(String, URL, String)] = [
            ("stray frame", await make("stray", ["\(a):d=2", "\(other),trim=duration=0.04", "\(b),trim=duration=2", "\(tone):d=5"], "[0][1][2]concat=n=3:v=1:a=0[v]"), "Flash frame"),
            ("black gap", await make("blackgap", ["\(a):d=2", "color=black:s=\(size):r=25:d=0.6", "\(b),trim=duration=2", "\(tone):d=5"], "[0][1][2]concat=n=3:v=1:a=0[v]"), "Black"),
            ("black flash", await make("blackflash", ["\(a):d=2", "color=black:s=\(size):r=25:d=0.04", "\(b),trim=duration=2", "\(tone):d=5"], "[0][1][2]concat=n=3:v=1:a=0[v]"), "Black flash"),
        ]
        // Elsewhere: no targets, so only what the picture and sound do counts.
        let anywhere = DeliveryCheck.Destination.other.spec
        func describe(_ report: DeliveryCheck.Report) -> String {
            report.issues.map { "\($0.severity) \($0.time.map { String(format: "%.2f", $0) } ?? "-") \($0.title): \($0.detail)" }.joined(separator: " | ")
        }
        func run(_ file: URL, spec: DeliveryCheck.Spec = anywhere) async -> DeliveryCheck.Report? {
            try? await DeliveryCheck.run(file, spec: spec, ffmpeg: ffmpeg, ffprobe: ffprobe) { _, _ in }
        }
        for (name, file) in clips {
            guard let report = await run(file) else { check("delivery: \(name) checked", false, "no report"); continue }
            let picture = report.issues.filter { $0.kind == .picture || $0.kind == .transition }
            let kinds = report.issues.filter { $0.kind == .transition }.map(\.detail)
            check("delivery: \(name) is a transition, not a problem",
                  !kinds.isEmpty && !picture.contains { $0.severity != .note } && !kinds.isEmpty, describe(report) + " ~ " + DeliveryCheck.measured.joined(separator: "; "))
            check("delivery: \(name) named", kinds.contains { $0.lowercased().hasPrefix(name) }, kinds.joined(separator: ", "))
            if name == "fade to black" {
                let sound = report.issues.filter { $0.kind == .sound && $0.time != nil }
                check("delivery: silence at the fade is a note", !sound.isEmpty && sound.allSatisfy { $0.severity == .note }, describe(report))
            }
            DeliveryCheck.measured = []
        }
        var stray: DeliveryCheck.Report?
        for (name, file, title) in reported {
            guard let report = await run(file) else { check("delivery: \(name) checked", false, "no report"); continue }
            if name == "stray frame" { stray = report }
            check("delivery: \(name) reported", report.issues.contains { $0.title == title && $0.severity != .note && abs(($0.time ?? 0) - 2) < 0.1 },
                  describe(report) + " ~ " + DeliveryCheck.measured.joined(separator: "; "))
            check("delivery: \(name) not a transition", !report.issues.contains { $0.kind == .transition }, describe(report))
            DeliveryCheck.measured = []
        }

        // The spec: codec, bitrate and colour off.
        var spec = anywhere
        spec.codecs = ["h264"]
        spec.minBitrate = 40
        spec.primaries = "bt709"; spec.transfer = "bt709"; spec.matrix = "bt709"
        spec.channels = 6
        let tagged = await make("tagged", ["\(a):d=1", "\(tone):d=1"], "[0]null[v]",
                                extra: ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"])
        if let report = await run(tagged, spec: spec) {
            for title in ["Codec", "Bitrate", "Colour space", "Sound channels"] {
                check("delivery: spec \(title.lowercased())", report.issues.contains { $0.title == title && $0.kind == .file }, describe(report))
            }
        } else {
            check("delivery: spec checked", false, "no report")
        }
        spec.codecs = ["mpeg4"]; spec.minBitrate = nil; spec.primaries = nil; spec.transfer = nil; spec.matrix = nil; spec.channels = nil
        if let report = await run(tagged, spec: spec) {
            check("delivery: spec met", !report.issues.contains { $0.kind == .file }, describe(report))
        }
        // Presets and saving one's own.
        let saved = DeliveryCheck.save(DeliveryCheck.Destination.broadcastEU.spec)
        check("delivery: preset saved as a copy", !saved.builtIn && DeliveryCheck.specs.contains { $0.id == saved.id }
              && DeliveryCheck.spec(id: saved.id).frameRates == [25, 50])
        DeliveryCheck.delete(saved)
        check("delivery: own spec deleted", !DeliveryCheck.specs.contains { $0.id == saved.id })

        // Intended: kept per file content.
        if let report = stray, let issue = report.issues.first(where: { $0.title == "Flash frame" }) {
            DeliveryCheck.setIntended(issue, fileKey: report.fileKey, true)
            let again = await run(report.file)
            check("delivery: intended kept for the file", again.map { DeliveryCheck.intended($0.fileKey).contains(issue.key) && $0.issues.contains { $0.key == issue.key } } ?? false)
            check("delivery: intended is per file", !DeliveryCheck.intended(DeliveryCheck.contentKey(tagged)).contains(issue.key))
            DeliveryCheck.setIntended(issue, fileKey: report.fileKey, false)
            check("delivery: intended undone", !DeliveryCheck.intended(report.fileKey).contains(issue.key))

            // Compared with itself shortened: the length changed, the stray frame isn't new.
            var approved = report
            approved.duration -= 1
            approved.loudness = (report.loudness ?? -20) - 3
            let changes = DeliveryCheck.compare(report, approved: approved)
            check("delivery: compare length and loudness", changes.contains { $0.title == "Length changed" } && changes.contains { $0.title == "Loudness changed" },
                  changes.map(\.title).joined(separator: ", "))
            approved.issues = []
            check("delivery: compare marks new problems", DeliveryCheck.markNew(report.issues, approved: approved).contains { $0.isNew && $0.title == "Flash frame" }
                  && !DeliveryCheck.markNew(report.issues, approved: report).contains { $0.isNew })

            // The files.
            let frames = await DeliveryCheck.thumbnails(report.file, times: report.issues.compactMap(\.time))
            check("delivery: thumbnails", !frames.isEmpty && frames.count == Set(report.issues.compactMap(\.time)).count)
            let pdf = DeliveryCheck.pdf(report, issues: report.issues, thumbnails: frames)
            check("delivery: pdf", pdf.count > 2000 && pdf.starts(with: Data("%PDF".utf8)) && (NSPDFImageRep(data: pdf)?.pageCount ?? 0) >= 1, "\(pdf.count) bytes")
            let csv = DeliveryCheck.csv(report, issues: report.issues).split(separator: "\n")
            check("delivery: csv", csv.first?.hasPrefix("Severity,Timecode") == true && csv.count == report.issues.count + 1, "\(csv.count) lines")
            let edl = DeliveryCheck.markerEDL(report, issues: report.issues).components(separatedBy: "\n")
            let events = edl.filter { $0.range(of: #"^\d{3}  001      V     C        \d\d:\d\d:\d\d:\d\d \d\d:\d\d:\d\d:\d\d \d\d:\d\d:\d\d:\d\d \d\d:\d\d:\d\d:\d\d  $"#, options: .regularExpression) != nil }
            let notes = edl.filter { $0.range(of: #"^ \|C:ResolveColor(Red|Yellow|Blue) \|M:.+ \|D:1$"#, options: .regularExpression) != nil }
            check("delivery: edl markers", edl.first?.hasPrefix("TITLE: stray") == true && edl.contains("FCM: NON-DROP FRAME")
                  && events.count == report.issues.filter { $0.time != nil }.count && notes.count == events.count
                  && notes.contains { $0.contains("ResolveColorRed") && $0.contains("Flash frame") }, edl.joined(separator: "⏎"))
        } else {
            check("delivery: stray report for the rest", false)
        }
    }
}
