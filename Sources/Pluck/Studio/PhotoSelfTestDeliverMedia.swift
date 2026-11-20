import AppKit
import Foundation

extension PhotoSelfTest {
    /// 4.1's review media (run inside -PluckScreenshotOnly review): Pluck-made transcripts as captions.vtt/transcript.json,
    /// 4K/HDR rendition strings and arguments, an HDR probe, a tone-mapped 1080 from a generated PQ clip, the 4K HEVC
    /// renditions, and Quick Look previews of files ImageIO can't read.
    static func deliverMediaChecks(_ base: URL, ffmpeg: String, ffprobe: String) async {
        let fm = FileManager.default
        let folder = base.appendingPathComponent("Media410", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Transcript: two speakers (one named in Pluck), word times kept, voice tags, the old three-field words plus a speaker index.
        var transcript = Transcript(id: "T", title: "Interview", filePath: "/x.mov", sourceURL: nil, language: "en-US", duration: 4, created: .now,
                                    words: [.init(s: 0.0, e: 0.4, t: " Hello"), .init(s: 0.45, e: 0.9, t: " there."), .init(s: 2.0, e: 2.5, t: " Hi"), .init(s: 2.5, e: 3.1, t: " <back>")])
        transcript.speakerTurns = [.init(s: 0, e: 1, speaker: 1), .init(s: 1.9, e: 3.2, speaker: 2)]
        transcript.speakerNames = ["1": "Host"]
        let files = DeliverCopies.transcriptFiles(transcript)
        let json = (try? JSONSerialization.jsonObject(with: files.json)) as? [String: Any] ?? [:]
        let words = json["words"] as? [[Any]] ?? []
        check("media: transcript.json speakers", (json["speakers"] as? [String]) == ["Host", String(localized: "Speaker \(2)")] && json["lang"] as? String == "en-US", "\(json)")
        check("media: transcript.json words", words.count == 4 && words[0][2] as? String == "Hello" && (words[2][0] as? Double) == 2.0 && (words[2][1] as? Double) == 2.5
              && words[0].count == 4 && (words[0][3] as? Int) == 0 && (words[3][3] as? Int) == 1, "\(words)")
        check("media: captions.vtt voices", files.vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.900\n<v Host>Hello there.")
              && files.vtt.contains("00:00:02.000 --> 00:00:03.100\n<v \(String(localized: "Speaker \(2)"))>Hi &lt;back&gt;"), files.vtt)
        let plain = Transcript(id: "P", title: "", filePath: "/y.mov", sourceURL: nil, language: "nl", duration: 1, created: .now, words: [.init(s: 0, e: 1, t: " Dag")])
        let plainJSON = (try? JSONSerialization.jsonObject(with: DeliverCopies.transcriptFiles(plain).json)) as? [String: Any] ?? [:]
        check("media: transcript without speakers", plainJSON["speakers"] == nil && ((plainJSON["words"] as? [[Any]])?.first?.count ?? 0) == 3, "\(plainJSON)")
        let written = folder.appendingPathComponent("tx")
        DeliverCopies.writeTranscript(transcript, into: written)
        check("media: transcript files written", fm.fileExists(atPath: written.appendingPathComponent("captions.vtt").path) && fm.fileExists(atPath: written.appendingPathComponent("transcript.json").path))

        // 4K/HDR strings and arguments.
        check("media: 4K codecs", DeliverCopies.codecs("2160", audio: true) == "hvc1.1.6.L153.B0,mp4a.40.2" && DeliverCopies.codecs("2160h", audio: false) == "hvc1.2.4.L153.B0"
              && DeliverCopies.codecs("1080", audio: true) == "avc1.64002a,mp4a.40.2")
        let pqJSON: [String: Any] = ["format": ["duration": "2"], "streams": [["codec_type": "video", "width": 3840, "height": 2160, "r_frame_rate": "25/1",
                                                                                "color_transfer": "smpte2084", "color_primaries": "bt2020"]]]
        let pqProbe = DeliverCopies.probe(pqJSON)
        check("media: HDR probe", pqProbe?.isHDR == true && pqProbe?.primaries == "bt2020" && DeliverCopies.probe(["streams": [["codec_type": "video", "width": 10, "height": 10]]])?.isHDR == false)
        if let pqProbe {
            var hd = pqProbe; hd.width = 1920; hd.height = 1080
            check("media: rendition list", DeliverCopies.renditions(for: pqProbe, uhd: true, hevc: true) == ["2160h", "2160", "1080", "540", "360"]
                  && DeliverCopies.renditions(for: pqProbe, uhd: false, hevc: true) == ["1080", "540", "360"]
                  && DeliverCopies.renditions(for: pqProbe, uhd: true, hevc: false) == ["1080", "540", "360"]
                  && DeliverCopies.renditions(for: hd, uhd: true, hevc: true) == ["1080", "540", "360"])
            let tools = DeliverCopies.Tools(hevc: "hevc_videotoolbox", tonemap: true)
            let hdr = DeliverCopies.arguments(URL(fileURLWithPath: "/in.mov"), rendition: "2160h", probe: pqProbe, folder: folder, tools: tools)
            let sdr1080 = DeliverCopies.arguments(URL(fileURLWithPath: "/in.mov"), rendition: "1080", probe: pqProbe, folder: folder, tools: tools)
            func at(_ a: [String], _ k: String) -> String? { a.firstIndex(of: k).map { a[$0 + 1] } }
            check("media: 2160h arguments", at(hdr, "-c:v") == "hevc_videotoolbox" && at(hdr, "-profile:v") == "main10" && at(hdr, "-tag:v") == "hvc1"
                  && at(hdr, "-color_trc") == "smpte2084" && at(hdr, "-vf")?.hasSuffix("format=p010le") == true, hdr.joined(separator: " "))
            let flat = DeliverCopies.arguments(URL(fileURLWithPath: "/in.mov"), rendition: "1080", probe: pqProbe, folder: folder, tools: .init(hevc: nil, tonemap: false))
            check("media: without tonemap the SDR copy of HDR is still tagged BT.709", at(flat, "-color_trc") == "bt709" && at(flat, "-colorspace") == "bt709"
                  && at(flat, "-vf")?.contains("tonemap") == false && at(flat, "-vf")?.contains("color_trc=bt709") == true, flat.joined(separator: " "))
            check("media: 1080 tone-mapped", at(sdr1080, "-c:v") == "libx264" && at(sdr1080, "-vf")?.contains("tonemap=hable") == true && at(sdr1080, "-color_trc") == "bt709")
        }

        // The real thing: a 1 s PQ clip at 3200 px → tone-mapped 1080 (8-bit 4:2:0, BT.709) and HEVC 2160h/2160.
        let tools = await DeliverCopies.tools(ffmpeg)
        check("media: ffmpeg has HEVC and tonemap", tools.hevc != nil && tools.tonemap, "\(tools)")
        let pq = folder.appendingPathComponent("pq.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=3200x1800:r=25:d=1", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                                                "-vf", "format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                                                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-tag:v", "hvc1", "-c:a", "aac", "-shortest", pq.path])
        let out = folder.appendingPathComponent("copies")
        let made = await DeliverCopies.make(pq, kind: .video, into: out, ffmpeg: ffmpeg, ffprobe: ffprobe, uhd: true) { _ in }
        check("media: 4K renditions made", made.renditions == ["2160h", "2160", "1080", "540", "360"] && made.probe?.isHDR == true, "\(String(describing: made.renditions))")
        let streams = await DeliveryCheck.output(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,pix_fmt,color_transfer", "-of", "csv=p=0",
                                                           out.appendingPathComponent("1080/index.m3u8").path])
        check("media: 1080 is SDR yuv420p", streams.contains("h264,yuv420p") && !streams.contains("smpte2084"), streams)
        let top = await DeliveryCheck.output(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,pix_fmt,color_transfer", "-of", "csv=p=0",
                                                       out.appendingPathComponent("2160h/index.m3u8").path])
        check("media: 2160h is HEVC 10-bit PQ", top.contains("hevc,yuv420p10le,smpte2084"), top)
        check("media: 2160h index", DeliverCopies.index(out.appendingPathComponent("2160h"))?.codecs.hasPrefix("hvc1.2.4.L153.B0") == true
              && DeliverCopies.index(out.appendingPathComponent("2160"))?.width == 3200)

        // Quick Look: a file ImageIO can't read gets page 1 as a picture; nothing to show stays download only.
        let text = folder.appendingPathComponent("notes.txt")
        try? "Shot list\n1. Wide\n2. Close".write(to: text, atomically: true, encoding: .utf8)
        let preview = folder.appendingPathComponent("ql")
        let ql = await DeliverCopies.make(text, kind: .other, into: preview, ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
        let jpeg = (try? Data(contentsOf: preview.appendingPathComponent("image.jpg"))) ?? Data()
        check("media: Quick Look preview", ql.probe != nil && jpeg.starts(with: [0xFF, 0xD8, 0xFF]) && DeliverCopies.isPreviewOnly(text) && !DeliverCopies.isPreviewOnly(pq.deletingPathExtension().appendingPathExtension("png")),
              "\(jpeg.count) bytes")
        let nothing = folder.appendingPathComponent("blob.unknownext")
        try? Data([0, 1, 2]).write(to: nothing)
        let none = await DeliverCopies.make(nothing, kind: .other, into: folder.appendingPathComponent("none"), ffmpeg: ffmpeg, ffprobe: ffprobe) { _ in }
        check("media: no preview stays download only", none.probe == nil && none.renditions == [])
    }
}
