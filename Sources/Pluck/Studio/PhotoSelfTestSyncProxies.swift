import Foundation

extension PhotoSelfTest {
    /// Sync Cameras' proxies: originals dropped with their proxies (a Proxy folder of ProRes Proxy copies,
    /// _Proxy names, Sony's Sub/…S03, Resolve's OptimizedMedia with its own names) leave the proxies out, a
    /// proxy without its original stays (marked), two cameras that only share a name aren't taken for one,
    /// and no "Proxy" camera is made.
    @MainActor static func syncProxiesTest(ffmpeg: String) async {
        let fm = FileManager.default
        // In the work folder beside the test home when there is one (deleted after either way).
        let work = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("syncfix", isDirectory: true)
        let base = (fm.fileExists(atPath: work.deletingLastPathComponent().appendingPathComponent("st410.sh").path) ? work : URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("fix-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        func make(_ path: String, size: String, tc: String, proxy: Bool, seconds: Double = 5) -> Bool {
            let file = base.appendingPathComponent(path)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=\(size):r=25:d=\(seconds)",
                                 "-f", "lavfi", "-i", "sine=f=440:d=\(seconds)", "-shortest"]
                + (proxy ? ["-c:v", "prores_ks", "-profile:v", "0"] : ["-c:v", "mpeg4", "-q:v", "10"]) + ["-c:a", "pcm_s16le", "-timecode", tc, file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let files: [(String, String, String, Bool)] = [
            ("A-cam/A038_05231239_C004.mov", "640x360", "10:00:00:00", false),
            ("Proxy/A038_05231239_C004.mov", "320x180", "10:00:00:00", true),
            ("B-cam/IZ6A5272.mov", "640x360", "10:01:00:00", false),
            ("B-cam/IZ6A5272_Proxy.mov", "320x180", "10:01:00:00", true),
            ("C-cam/C0001.mov", "640x360", "10:02:00:00", false),
            ("C-cam/Sub/C0001S03.mov", "320x180", "10:02:00:00", false),
            ("D-cam/Z004_C001.mov", "640x360", "10:03:00:00", false),
            ("OptimizedMedia/8f2c-41aa.mov", "320x180", "10:03:00:00", true),
            ("Proxy/N164_C002.mov", "320x180", "10:04:00:00", true),
            ("X-cam/R6LO9274.mov", "640x360", "10:05:00:00", false),
            ("Y-cam/R6LO9274.mov", "640x360", "10:05:00:00", false),
        ]
        for (path, size, tc, proxy) in files where !make(path, size: size, tc: tc, proxy: proxy) {
            return check("sync proxies: test clips made", false, path)
        }
        let model = CameraSyncModel()
        model.add([base])
        for _ in 0..<200 where model.running { try? await Task.sleep(for: .milliseconds(100)) }
        let names = model.cameras.map { "\($0.name):\($0.clips.map(\.name).joined(separator: "+"))" }.joined(separator: ", ")
        let left = Set(model.proxiesLeftOut.map { $0.clip.file.deletingLastPathComponent().lastPathComponent + "/" + $0.clip.name })
        check("sync proxies: the four proxies of originals left out", left == ["Proxy/A038_05231239_C004.mov", "B-cam/IZ6A5272_Proxy.mov", "Sub/C0001S03.mov", "OptimizedMedia/8f2c-41aa.mov"],
              left.sorted().joined(separator: ", "))
        let clips = model.clips
        func clip(_ path: String) -> SyncClip? { clips.first { $0.path.hasSuffix("/" + path) } }
        check("sync proxies: each original knows its proxy (played instead)",
              clip("A-cam/A038_05231239_C004.mov")?.proxy?.hasSuffix("Proxy/A038_05231239_C004.mov") == true
              && clip("B-cam/IZ6A5272.mov")?.proxy?.hasSuffix("IZ6A5272_Proxy.mov") == true
              && clip("C-cam/C0001.mov")?.proxy?.hasSuffix("Sub/C0001S03.mov") == true
              && clip("D-cam/Z004_C001.mov")?.proxy?.hasSuffix("8f2c-41aa.mov") == true, names)
        check("sync proxies: a proxy without its original stays, marked", clip("Proxy/N164_C002.mov")?.isProxy == true
              && clips.filter(\.isProxy).count == 1, names)
        check("sync proxies: two cameras sharing a name stay two", clip("X-cam/R6LO9274.mov") != nil && clip("Y-cam/R6LO9274.mov") != nil
              && clip("X-cam/R6LO9274.mov")?.proxy == nil, names)
        check("sync proxies: no proxy grouped as a camera beside its original", clips.count == 7
              && !model.cameras.contains { $0.clips.contains { $0.path.contains("/OptimizedMedia/") || $0.name.contains("_Proxy") || $0.name.hasSuffix("S03.mov") } }, names)
        // Dropped later than their originals: still left out.
        let later = CameraSyncModel()
        later.add(files.filter { !$0.0.contains("Proxy") && !$0.0.contains("Sub/") && !$0.0.contains("Optimized") }.map { base.appendingPathComponent($0.0) })
        for _ in 0..<200 where later.running { try? await Task.sleep(for: .milliseconds(100)) }
        later.add([base.appendingPathComponent("Proxy"), base.appendingPathComponent("C-cam/Sub")])
        for _ in 0..<200 where later.running { try? await Task.sleep(for: .milliseconds(100)) }
        check("sync proxies: proxies dropped after their originals are left out too", later.proxiesLeftOut.count == 2 && later.clips.count == 7
              && later.clips.filter(\.isProxy).map(\.name) == ["N164_C002.mov"], later.clips.map(\.name).joined(separator: ", "))
        // What's sent is the original, never its proxy.
        if let c = model.cameras.firstIndex(where: { $0.clips.contains { $0.proxy != nil } }) {
            model.cameras[c].clips[0].start = 0
            let xml = CameraSyncExport.fcpxml(model.cameras, name: "Proxies")
            check("sync proxies: the original is sent, not its proxy", xml.contains(model.cameras[c].clips[0].name) && !xml.contains("/Proxy/") && !xml.contains("_Proxy")
                  && !xml.contains("/Sub/") && !xml.contains("OptimizedMedia"))
        }
        model.includeProxies()
        check("sync proxies: Include puts them back", model.proxiesLeftOut.isEmpty && model.clips.count == 11)
    }
}
