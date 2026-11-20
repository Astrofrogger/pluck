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
        check("look: a proxy is Attach Proxies-ready (rate, timecode, shape, audio)", OfficeProxies.attachProblem(source, plain, ffprobe: ffprobe) == nil,
              OfficeProxies.attachProblem(source, plain, ffprobe: ffprobe) ?? "")
        check("look: a proxy that differs from its original is caught", OfficeProxies.attachProblem(source, root.appendingPathComponent("Cuts/P.mov"), ffprobe: ffprobe) != nil)
        check("look: the proxy says which look it has", OfficeLook.tagged(looked, ffprobe: ffprobe) == "slog3-709" && OfficeLook.tagged(plain, ffprobe: ffprobe) == nil)
    }
}

extension PhotoSelfTest {
    /// Premiere Pro and Final Cut Pro (part of remoteresolve): XML paths rewritten to originals (an unknown one left and
    /// reported), what won't translate, the timeline's name, and that a proxy is Attach Proxies-ready (facts compared).
    static func remoteXMLTest() {
        let fcp = """
        <?xml version="1.0"?><fcpxml version="1.11"><resources>
        <asset id="r2" name="A001"><media-rep kind="original-media" src="file:///Users/x/Proxies/Day%201/A001.mov"/></asset>
        <asset id="r3"><media-rep kind="original-media" src="file:///Volumes/Other/B.mov"/></asset></resources>
        <library><event><project name="Cut &amp; Final"><sequence><spine>
        <asset-clip ref="r2"><filter-video name="Color Board"/><filter-video name="Gaussian Blur"/></asset-clip>
        <transition name="Cross Dissolve"/><transition name="Swap"/><title name="Basic Title"/><title name="Basic Title"/>
        </spine></sequence></project></event></library></fcpxml>
        """
        let map = ["/Users/x/Proxies/Day 1/A001.mov": "/Volumes/NAS/Share/Day 1/A001.MXF"]
        let (text, unknown) = RemoteXML.rewrite(fcp, map: map)
        check("xml: FCPXML proxy paths become the originals'", text.contains("src=\"file:///Volumes/NAS/Share/Day%201/A001.MXF\"") && !text.contains("Proxies"), text)
        check("xml: an unknown path is left alone and reported", unknown == ["/Volumes/Other/B.mov"] && text.contains("file:///Volumes/Other/B.mov"))
        check("xml: the files an XML points at", RemoteXML.files(fcp) == ["/Users/x/Proxies/Day 1/A001.mov", "/Volumes/Other/B.mov"], "\(RemoteXML.files(fcp))")
        check("xml: FCPXML's timeline name", RemoteXML.timeline(fcp) == "Cut & Final")
        let lost = RemoteXML.untranslated(fcp)
        check("xml: FCPXML titles, effects, grades, other transitions listed", lost.contains("Title: Basic Title ×2") && lost.contains("Grade: Color Board")
              && lost.contains("Effect: Gaussian Blur") && lost.contains("Transition: Swap") && !lost.contains { $0.contains("Cross Dissolve") }, "\(lost)")
        let premiere = """
        <?xml version="1.0"?><xmeml version="4"><sequence id="s1"><uuid>x</uuid><name>Edit 1</name><media><video><track>
        <clipitem><file id="f1"><pathurl>file://localhost/Users/x/Proxies/Day%201/A001.mov</pathurl></file>
        <filter><effect><name>Lumetri Color</name><effectid>x</effectid><effecttype>filter</effecttype></effect></filter>
        <filter><effect><name>Basic Motion</name><effecttype>filter</effecttype></effect></filter></clipitem>
        <transitionitem><effect><name>Cross Dissolve</name><effecttype>transition</effecttype></effect></transitionitem>
        <generatoritem><name>Text</name></generatoritem></track></video></media></sequence></xmeml>
        """
        let (rewritten, none) = RemoteXML.rewrite(premiere, map: map)
        check("xml: Premiere XML pathurl becomes the original's", rewritten.contains("<pathurl>file://localhost/Volumes/NAS/Share/Day%201/A001.MXF</pathurl>") && none.isEmpty, rewritten)
        check("xml: Premiere's sequence name", RemoteXML.timeline(premiere) == "Edit 1")
        let gone = RemoteXML.untranslated(premiere)
        check("xml: Premiere grades and titles listed, motion and dissolves not", gone == ["Grade: Lumetri Color", "Title or generator"], "\(gone)")
        check("xml: other files are refused", RemoteXML.kind("<html/>") == nil)
    }
}
