import AppKit
import Foundation

/// AI tools for Resolve (-PluckScreenshotOnly aitools): drop-frame timecode and the Remove Silences
/// EDL, timecode and reel kept on remade copies, and Clean Up Audio's PCM channel graph.
extension PhotoSelfTest {
    static func aiToolsTest() async {
        // Drop-frame counting.
        check("ai: DF 01:00:00;00 is 107892", DropFrame.frames("01:00:00;00", base: 30, drop: true) == 107_892)
        check("ai: DF 00:01:00;02 is 1800", DropFrame.frames("00:01:00;02", base: 30, drop: true) == 1800)
        check("ai: DF 00:10:00;00 is 17982", DropFrame.frames("00:10:00;00", base: 30, drop: true) == 17_982)
        check("ai: DF 59.94 01:00:00;00 is 215784", DropFrame.frames("01:00:00;00", base: 60, drop: true) == 215_784)
        check("ai: DF 1799 is 00:00:59;29, 1800 is 00:01:00;02",
              DropFrame.string(1799, base: 30, drop: true) == "00:00:59;29" && DropFrame.string(1800, base: 30, drop: true) == "00:01:00;02")
        var roundTrip = true
        for base in [30, 60] {
            for frames in stride(from: 0, to: 2_500_000, by: 997) {
                if DropFrame.frames(DropFrame.string(frames, base: base, drop: true), base: base, drop: true) != frames { roundTrip = false }
            }
        }
        check("ai: DF round trip", roundTrip)
        check("ai: 29.97 can drop, 25 and 23.976 can't",
              DropFrame.canDrop(30000.0 / 1001) && DropFrame.canDrop(60000.0 / 1001) && !DropFrame.canDrop(25) && !DropFrame.canDrop(24000.0 / 1001))

        // An hour of 29.97 DF footage: the EDL's source out is two hours on, without drift.
        let df = Tighten.edl(keeps: [0...3600], title: "T", clipName: "c.mov", fps: 29.97, startTimecode: "01:00:00;00")
        check("ai: EDL drop frame", df.contains("FCM: DROP FRAME") && df.contains("01:00:00;00 02:00:00;00 01:00:00;00 02:00:00;00"), df)
        // 23.976 as the probe rounds it: an exact non-drop count all the same.
        let ndf = Tighten.edl(keeps: [3000...3010], title: "T", clipName: "c.mov", fps: 23.98, startTimecode: "00:00:00:00")
        check("ai: EDL 23.976 exact", ndf.contains("FCM: NON-DROP FRAME") && ndf.contains("00:49:57:00 00:50:07:00"), ndf)
        let nd30 = Tighten.edl(keeps: [0...2], title: "T", clipName: "c.mov", fps: 29.97, startTimecode: "10:00:00:00")
        check("ai: EDL 29.97 non-drop stays non-drop", nd30.contains("FCM: NON-DROP FRAME") && nd30.contains("10:00:00:00 10:00:02:00 01:00:00:00 01:00:02:00"), nd30)

        // Timecode and reel from ffprobe's JSON (QuickTime keeps them on the timecode track).
        let tags = FrameRewriter.sourceTags(#"{"streams":[{"tags":{"handler_name":"x"}},{"tags":{"timecode":"01:02:03;04","reel_name":"A001C003"}}],"format":{"tags":{}}}"#)
        check("ai: source tags", tags.timecode == "01:02:03;04" && tags.reel == "A001C003", "\(tags)")

        // Clean Up Audio's streams and channel graph.
        let parsed = AudioCleanup.streams(json: #"{"streams":[{"codec_name":"pcm_s24le","channels":2,"channel_layout":"stereo","sample_rate":"48000"},{"codec_name":"pcm_s16le","channels":4,"sample_rate":"96000"}]}"#)
        check("ai: audio streams", parsed.count == 2 && parsed[0].isLossless && parsed[1].rate == 96000 && parsed[1].joinLayout == "4C"
              && !AudioCleanup.Stream(codec: "aac", channels: 2, layout: "stereo", rate: 48000).isLossless, "\(parsed)")
        check("ai: PCM graph", AudioCleanup.pcmGraph([parsed[0]], cleaned: [1: "anull"])
              == "[0:a:0]pan=mono|c0=c0[s0c0];[1:a]anull[s0c1];[s0c0][s0c1]join=inputs=2:channel_layout=stereo[a0]",
              AudioCleanup.pcmGraph([parsed[0]], cleaned: [1: "anull"]))

        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            return check("ai: ffmpeg", false, "no ffmpeg")
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AIToolsTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ tool: String, _ args: [String]) async -> String { await ToolOutput.run(tool, args) }

        // A camera file: ProRes, 29.97 DF timecode, a reel, a lav and a boom on one stereo stream,
        // plus two mono streams.
        let source = folder.appendingPathComponent("A001C003.mov")
        _ = await run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=s=320x180:r=30000/1001:d=2",
                               "-f", "lavfi", "-i", "sine=f=300:d=2", "-f", "lavfi", "-i", "sine=f=700:d=2",
                               "-f", "lavfi", "-i", "sine=f=500:d=2", "-f", "lavfi", "-i", "sine=f=900:d=2",
                               "-filter_complex", "[1][2]join=inputs=2:channel_layout=stereo[st]",
                               "-map", "0:v", "-map", "[st]", "-map", "3:a", "-map", "4:a", "-c:v", "prores", "-c:a", "pcm_s24le",
                               "-timecode", "01:00:00;00", "-metadata:s:v:0", "reel_name=A001C003",
                               "-metadata", "com.apple.quicktime.location.ISO6709=+50.0+004.0/", source.path])
        // The remade picture (as FrameRewriter leaves it: no timecode), muxed the way Enhance, Background and Blur do.
        let picture = folder.appendingPathComponent("picture.mov")
        _ = await run(ffmpeg, ["-v", "error", "-i", source.path, "-map", "0:v", "-c:v", "prores", "-map_metadata", "-1", "-write_tmcd", "0", picture.path])
        let remade = folder.appendingPathComponent("remade.mov")
        _ = await run(ffmpeg, ["-v", "error", "-i", picture.path, "-i", source.path, "-map", "0:v", "-map", "1:a?"]
                      + (await FrameRewriter.keepingSource(source, input: 1, ffprobe: ffprobe))
                      + ["-c:v", "copy", "-c:a", "copy", "-shortest", remade.path])
        let remadeTags = FrameRewriter.sourceTags(await run(ffprobe, ["-v", "error", "-show_entries", "format_tags=timecode,reel_name:stream_tags=timecode,reel_name",
                                                                    "-of", "json", remade.path]))
        check("ai: remade copy keeps timecode and reel", remadeTags.timecode == "01:00:00;00" && remadeTags.reel == "A001C003", "\(remadeTags)")
        let location = await run(ffprobe, ["-v", "error", "-show_entries", "format_tags", "-of", "json", remade.path])
        check("ai: remade copy leaves location out", !location.contains("ISO6709"), location)

        // The PCM graph on the real file: channel 2 (the boom) cleaned (here: silenced), the lav untouched,
        // both mono streams kept as streams.
        let streams = await AudioCleanup.streams(source, ffprobe: ffprobe)
        check("ai: camera file streams", streams.map(\.channels) == [2, 1, 1] && streams.allSatisfy(\.isLossless), "\(streams)")
        let silent = folder.appendingPathComponent("silent.wav")
        _ = await run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "2", silent.path])
        let clean = folder.appendingPathComponent("clean.mov")
        var args = ["-v", "error", "-i", source.path, "-i", silent.path, "-filter_complex",
                    AudioCleanup.pcmGraph(streams, cleaned: [1: "aresample=48000"]), "-map", "0:v"]
        for s in streams.indices { args += ["-map", "[a\(s)]"] }
        args += await FrameRewriter.keepingSource(source, input: 0, ffprobe: ffprobe)
        _ = await run(ffmpeg, args + ["-c:v", "copy", "-c:a", "pcm_s24le", clean.path])
        let out = AudioCleanup.streams(json: await run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries",
                                                                 "stream=codec_name,channels,channel_layout,sample_rate", "-of", "json", clean.path]))
        check("ai: clean copy keeps PCM, channels and layout",
              out.map(\.channels) == [2, 1, 1] && out.allSatisfy { $0.codec == "pcm_s24le" } && out.first?.layout == "stereo", "\(out)")
        func level(_ channel: Int) async -> Double {
            let log = await run(ffmpeg, ["-v", "info", "-i", clean.path, "-map", "0:a:0", "-af", "pan=mono|c0=c\(channel),volumedetect", "-f", "null", "-"])
            return log.components(separatedBy: "mean_volume: ").last.flatMap { Double($0.prefix { "-0123456789.".contains($0) }) } ?? 0
        }
        let lav = await level(0), boom = await level(1)
        check("ai: lav kept, boom replaced", lav > -30 && boom < -80, "lav \(lav) boom \(boom)")
        let cleanTags = FrameRewriter.sourceTags(await run(ffprobe, ["-v", "error", "-show_entries", "format_tags=timecode,reel_name:stream_tags=timecode,reel_name",
                                                                   "-of", "json", clean.path]))
        check("ai: clean copy keeps timecode and reel", cleanTags.timecode == "01:00:00;00" && cleanTags.reel == "A001C003", "\(cleanTags)")
    }
}
