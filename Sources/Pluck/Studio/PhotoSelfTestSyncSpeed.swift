import Foundation

extension PhotoSelfTest {
    /// Sync Cameras' speed on a bigger shoot: six cameras of four 2½-minute clips each (sound cut from one
    /// ten-minute recording made with ffmpeg, each camera with its own noise and colour; the last two with
    /// jam-synced timecode). Timed one clip at a time (as before) and the quick way, from nothing heard;
    /// both must put every clip within a frame of the truth and of each other.
    @MainActor static func syncSpeedTest(ffmpeg: String, ffprobe: String) async {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("syncfix", isDirectory: true)
        let base = (fm.fileExists(atPath: work.deletingLastPathComponent().appendingPathComponent("st410.sh").path) ? work : URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("speed-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        @Sendable func run(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-v", "error"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let made = Date()
        let set = base.appendingPathComponent("set.wav")
        // Pink noise whose loudness swells and falls (never repeating), with clicks: something to match on.
        // The clicks drift (t²) so their pattern never repeats (a plain sin(0.7t) repeated after 403.9 s).
        guard run(["-f", "lavfi", "-i", "anoisesrc=d=600:c=pink:r=16000:seed=7,volume='0.15+0.85*abs(sin(t*1.7)*sin(t*0.37+1)*sin(t*0.091+2))':eval=frame",
                   "-f", "lavfi", "-i", "aevalsrc='0.8*lt(mod(t*2.3+sin(t*0.7+0.0013*t*t),1),0.01)*sin(2*PI*900*t)':d=600:s=16000",
                   "-filter_complex", "amix=inputs=2:normalize=0", set.path]) else { return check("sync speed: the recording made", false) }
        struct Shot { var name: String; var start: Double; var timecode: Bool }
        var shots: [Shot] = []
        var seed: UInt64 = 0x51DE
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let fps = 25
        var ok = true
        await withTaskGroup(of: Bool.self) { group in
            for k in 0..<6 {
                for j in 0..<4 {
                    let start = 10 + Double(j) * 120 + Double(k) * 3.137 + random()
                    let name = "Cam\(k + 1)/C\(k + 1)_\(String(format: "%03d", j + 1)).mov"
                    shots.append(Shot(name: name, start: start, timecode: k >= 4))
                    try? fm.createDirectory(at: base.appendingPathComponent("Cam\(k + 1)"), withIntermediateDirectories: true)
                    let frames = Int((start * Double(fps)).rounded())
                    let tc = String(format: "10:%02d:%02d:%02d", frames / fps / 60, frames / fps % 60, frames % fps)
                    let out = base.appendingPathComponent(name).path
                    let filters = k % 2 == 0 ? "lowpass=f=3000" : "highpass=f=200"
                    group.addTask {
                        run(["-ss", String(start), "-t", "150", "-i", set.path, "-f", "lavfi", "-i", "anoisesrc=d=150:c=white:r=16000:a=0.02:seed=\(100 + k * 4 + j)",
                             "-f", "lavfi", "-i", "color=c=0x\(String(format: "%02x", 40 + k * 30))4040:s=64x36:r=\(fps):d=150",
                             "-filter_complex", "[0:a]\(filters),volume=\(0.5 + Double(k) * 0.15)[a];[a][1:a]amix=inputs=2:normalize=0[m]",
                             "-map", "2:v", "-map", "[m]", "-c:v", "mpeg4", "-q:v", "10", "-c:a", "pcm_s16le", "-shortest"]
                            + (k >= 4 ? ["-timecode", tc] : []) + [out])
                    }
                }
            }
            for await made in group { ok = ok && made }
        }
        try? fm.removeItem(at: set)
        guard ok else { return check("sync speed: test clips made", false) }
        note("sync speed: 24 clips made in \(String(format: "%.1f", Date().timeIntervalSince(made))) s")
        let probes = CameraSync.files(in: [base]).compactMap { CameraSync.probe($0.file, root: $0.root, ffprobe: ffprobe) }
        let cameras = CameraSync.group(probes)
        check("sync speed: six cameras of four", cameras.count == 6 && cameras.allSatisfy { $0.clips.count == 4 }, cameras.map(\.name).joined(separator: ", "))
        func errors(_ synced: [SyncCamera]) -> [String: Double] {
            let clips = synced.flatMap(\.clips)
            guard let anchor = clips.first(where: { $0.path.hasSuffix(shots[0].name) }), let a = anchor.start else { return [:] }
            var out: [String: Double] = [:]
            for shot in shots { out[shot.name] = clips.first { $0.path.hasSuffix(shot.name) }?.start.map { ($0 - a) - (shot.start - shots[0].start) } ?? .infinity }
            return out
        }
        var timings: [Double] = []
        var results: [[String: Double]] = []
        for width in [1, CameraSync.width] {
            let started = Date(), stages = StageClock()
            let synced = await CameraSync.sync(cameras, options: .init(ffmpeg: ffmpeg, cache: SyncCache(), width: width)) { _, text in stages.mark(text) }
            timings.append(Date().timeIntervalSince(started))
            results.append(errors(synced))
            note("sync speed: \(width == 1 ? "one at a time (before)" : "\(width) at once (now)") \(String(format: "%.1f", timings.last!)) s (\(stages.summary))")
        }
        let frame = 1.0 / Double(fps)
        for (k, result) in results.enumerated() {
            let worst = result.values.map(abs).max() ?? .infinity
            check("sync speed: every clip within a frame (\(k == 0 ? "before" : "now"))", result.count == 24 && worst < frame,
                  String(format: "worst %.2f ms; ", worst * 1000) + result.filter { abs($0.value) >= frame }.map(\.key).sorted().joined(separator: ", "))
        }
        let apart = shots.map { abs((results[0][$0.name] ?? .infinity) - (results[1][$0.name] ?? .infinity)) }.max() ?? .infinity
        check("sync speed: now and before agree within a frame", apart < frame, String(format: "%.2f ms", apart * 1000))
        check("sync speed: quicker", timings.count == 2 && timings[1] < timings[0] * 0.8, timings.map { String(format: "%.1f s", $0) }.joined(separator: " → "))
    }
}
