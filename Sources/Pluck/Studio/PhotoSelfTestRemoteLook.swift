import Foundation

extension PhotoSelfTest {
    /// Viewing looks on log proxies (part of remotepull): each curve's 18% grey lands near Rec.709 mid-grey, detection
    /// from sample metadata (never a guess), Off by default, a proxy made with a look is brighter and tagged, and a
    /// manifest entry from an older office (no `look`) still reads.
    static func remoteLookTest(root: URL) async {
        let grey: [(OfficeLook, Double)] = [(.slog3, 420.0 / 1023), (.vlog, 0.4233), (.logc3, 0.3910), (.logc4, 0.2784), (.clog3, 0.3434)]
        for (look, code) in grey {
            let linear = look.linear(code), shown = look.apply([code, code, code])
            check("look: \(look.label) 18% grey is mid-grey in Rec.709", abs(linear - 0.18) < 0.005 && shown.allSatisfy { abs($0 - 0.409) < 0.03 },
                  "\(linear) \(shown)")
        }
        let identity = OfficeLook.multiply(OfficeLook.invert(OfficeLook.toXYZ(OfficeLook.rec709)), OfficeLook.toXYZ(OfficeLook.rec709))
        check("look: gamut maths (709 to 709 is the identity)", (0..<3).allSatisfy { r in (0..<3).allSatisfy { abs(identity[r][$0] - (r == $0 ? 1 : 0)) < 1e-9 } })
        let cube = OfficeLook.slog3.cube(size: 5)
        check("look: the .cube has its size and every point", cube.hasPrefix("TITLE") && cube.contains("LUT_3D_SIZE 5") && cube.split(separator: "\n").count == 127)

        check("look: Sony's XML", OfficeLook.detect(text: #"<CaptureGammaEquation value="s-log3-cine"/>"#) == .slog3)
        check("look: ARRI LogC4 and plain LogC", OfficeLook.detect(text: #"{"gamma":"LogC4"}"#) == .logc4 && OfficeLook.detect(text: "LogC") == .logc3)
        check("look: Panasonic and Canon", OfficeLook.detect(text: "V-Log") == .vlog && OfficeLook.detect(text: "Canon Log 3") == .clog3)
        check("look: nothing found, or two curves, is no look", OfficeLook.detect(text: "rec709") == nil && OfficeLook.detect(text: "S-Log3 V-Log") == nil)
        check("look: Off by default", OfficeLook.setting("never-set-\(UUID().uuidString)") == .off)
        check("look: RAW never gets a LUT", OfficeLook.look(for: URL(fileURLWithPath: "/x/A001.braw"), setting: .slog3, ffprobe: nil) == nil)
        let old = #"{"share":"s","path":"a.mov","proxy":"a.mov","reel":"a","size":1}"#
        check("look: an older office's manifest entry reads (no look)", (try? JSONDecoder().decode(RemoteManifestEntry.self, from: Data(old.utf8)))?.look == nil)

        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg"), let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe") else {
            return check("look: ffmpeg for the test", false)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("Looks"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Looks/C001.mov")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: ffmpeg)
        // (Code value 0.6 in S-Log3 is a bright highlight.)
        make.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x999999:s=320x240:r=25", "-t", "1", "-c:v", "prores_ks", "-profile:v", "0", source.path]
        try? make.run()
        make.waitUntilExit()
        try? Data(#"<NonRealTimeMeta><CaptureGammaEquation value="s-log3-cine"/></NonRealTimeMeta>"#.utf8).write(to: root.appendingPathComponent("Looks/C001M01.XML"))
        check("look: Automatic finds Sony's sidecar", OfficeLook.detect(source, ffprobe: ffprobe) == .slog3)
        func luma(_ file: URL) -> Int {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-v", "error", "-i", file.path, "-frames:v", "1", "-vf", "crop=2:2", "-f", "rawvideo", "-pix_fmt", "gray", "-"]
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.first.map(Int.init) ?? -1
        }
        let plain = root.appendingPathComponent("Looks/plain.mov"), looked = root.appendingPathComponent("Looks/looked.mov")
        let a = await OfficeProxies.encode(source, to: plain, format: .light, ffmpeg: ffmpeg, ffprobe: ffprobe, progress: { _ in })
        let b = await OfficeProxies.encode(source, to: looked, format: .light, ffmpeg: ffmpeg, ffprobe: ffprobe, look: .automatic, progress: { _ in })
        check("look: a proxy with the look is brighter, one without is as shot", a && b && luma(looked) > luma(plain) + 50, "\(luma(plain)) \(luma(looked))")
        check("look: the proxy says which look it has", OfficeLook.tagged(looked, ffprobe: ffprobe) == "slog3-709" && OfficeLook.tagged(plain, ffprobe: ffprobe) == nil)
    }
}
