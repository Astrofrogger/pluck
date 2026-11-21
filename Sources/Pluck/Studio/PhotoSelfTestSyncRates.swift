import Foundation

extension PhotoSelfTest {
    /// Sync Cameras at 23.976, 29.97 (non-drop and drop frame), 59.94 and 25 (run by syncShownTest): a camera's timecode in
    /// real seconds (as sound, BWF and slates count), placed by it over two hours, the FCPXML asset start and the Resolve
    /// start timecode in the label's frames. Also the timeline rate of a phone's variable rate, and a recorder's timecode
    /// checked to a frame, not a second.
    static func syncRatesTest() {
        struct Case { var name: String; var fps: Double; var base: Int; var drop: Bool }
        let cases = [Case(name: "23.976", fps: 24000.0 / 1001, base: 24, drop: false), Case(name: "29.97 NDF", fps: 30000.0 / 1001, base: 30, drop: false),
                     Case(name: "29.97 DF", fps: 30000.0 / 1001, base: 30, drop: true), Case(name: "59.94 NDF", fps: 60000.0 / 1001, base: 60, drop: false),
                     Case(name: "25", fps: 25, base: 25, drop: false)]
        for k in cases {
            // Ground truth: the frames the label HH:00:00:00 stands for (drop frame skips 2 (4 at 59.94) numbers a minute but
            // every tenth), each 1001/1000 of a whole-rate frame long (25: 1/25 s).
            func frames(_ h: Int) -> Int {
                let label = h * 3600 * k.base, minutes = h * 60
                return k.drop ? label - k.base / 15 * (minutes - minutes / 10) : label
            }
            func real(_ h: Int) -> Double { k.base == 25 ? Double(frames(h)) / 25 : Double(frames(h)) * 1001 / Double(k.base * 1000) }
            func text(_ h: Int) -> String { String(format: "%02d:00:00", h) + (k.drop ? ";00" : ":00") }
            let read = CameraSync.seconds(timecode: text(10), fps: k.fps)
            check("sync rates \(k.name): timecode in real seconds", read.map { abs($0 - real(10)) < 1e-6 } ?? false, "\(read ?? -1) vs \(real(10))")

            // One camera, clips at 10, 11 and 12 o'clock; the first and last heard for sure, the middle one not.
            let camera = SyncCamera(name: "A", key: "a", clips: [10, 11, 12].map { h in
                var clip = SyncClip(path: "/sync-rates/\(k.base)\(k.drop ? "df" : "")/\(h).mov")
                clip.fps = k.fps; clip.hasVideo = true; clip.hasAudio = true; clip.duration = 60
                clip.timecode = CameraSync.seconds(timecode: text(h), fps: k.fps)
                clip.dropFrame = k.drop
                return clip
            })
            var heard = camera
            for i in [0, 2] { heard.clips[i].start = real(10 + i) - real(10) + 5; heard.clips[i].method = .audio; heard.clips[i].confidence = 0.9 }
            let placed = CameraSync.byTimecode([camera], sound: [heard])?.first?.clips ?? []
            let apart = placed.compactMap(\.start).map { $0 - (placed.first?.start ?? 0) }
            let truth = [10, 11, 12].map { real($0) - real(10) }
            check("sync rates \(k.name): placed by timecode over two hours, each at its true place",
                  placed.count == 3 && placed.allSatisfy { $0.method == .timecode } && apart.count == 3 && zip(apart, truth).allSatisfy { abs($0 - $1) < 1e-6 },
                  "\(placed.map { $0.method?.rawValue ?? "-" }) \(apart) vs \(truth)")

            // Out: the label's frames.
            let out = [SyncCamera(name: "A", key: "a", clips: placed)]
            let rate = CameraSyncExport.rate(out)
            let start = CameraSyncExport.startFrame(out, rate: rate)
            let resolve = start.map { CameraSyncExport.timecode($0, rate: rate, drop: CameraSyncExport.dropFrame(out, rate: rate)) }
            check("sync rates \(k.name): Resolve starts at the first clip's timecode", start == frames(10) && resolve == text(10), "\(start ?? -1) \(resolve ?? "-")")
            let records = CameraSyncExport.placements(out, rate: rate).map(\.record)
            check("sync rates \(k.name): placed at the label's frames", records == [10, 11, 12].map { frames($0) - frames(10) }, "\(records)")
            let xml = CameraSyncExport.fcpxml(out, name: "Rates")
            let time = k.base == 25 ? "\(frames(10))/25s" : "\(frames(10) * 1001)/\(k.base * 1000)s"
            check("sync rates \(k.name): FCPXML asset and sequence start at the timecode", xml.contains("<asset id=\"a1\" name=\"10.mov\" start=\"\(time)\"")
                  && xml.contains("tcStart=\"\(time)\" tcFormat=\"\(k.drop ? "DF" : "NDF")\""),
                  xml.split(separator: "\n").filter { $0.contains("a1") || $0.contains("tcStart") }.joined(separator: " | "))
        }
        // A phone's variable rate is the standard one near it; an odd rate stays.
        func camera(_ rates: [Double]) -> [SyncCamera] {
            [SyncCamera(name: "P", key: "p", clips: rates.enumerated().map { n, fps in
                var clip = SyncClip(path: "/sync-rates/phone/\(n).mov"); clip.fps = fps; clip.hasVideo = true; return clip
            })]
        }
        check("sync rates: a phone's 29.98 and 29.87 make a 29.97 timeline, 15 stays 15",
              CameraSyncExport.rate(camera([29.98, 29.87, 30000.0 / 1001])) == 30000.0 / 1001 && CameraSyncExport.rate(camera([15])) == 15,
              "\(CameraSyncExport.rate(camera([29.98, 29.87, 30000.0 / 1001]))) \(CameraSyncExport.rate(camera([15])))")
        // A sound recorder's timecode (no picture rate) checked to a frame: one 0.5 s off its other clip goes by its sound.
        var recorder = SyncCamera(name: "R", key: "r", clips: [100.0, 200].enumerated().map { n, tc in
            var clip = SyncClip(path: "/sync-rates/rec/\(n).wav"); clip.hasAudio = true; clip.duration = 60; clip.timecode = tc; return clip
        })
        let recorded = recorder
        for (i, start) in [5.0, 105.5].enumerated() { recorder.clips[i].start = start; recorder.clips[i].method = .audio; recorder.clips[i].confidence = 0.9 }
        let byRecorder = CameraSync.byTimecode([recorded], sound: [recorder])?.first?.clips ?? []
        check("sync rates: a recorder's timecode checked to a frame", byRecorder.count == 2 && byRecorder.contains { $0.method == .audio }
              && byRecorder.contains { $0.method == .timecode }, byRecorder.map { "\($0.method?.rawValue ?? "-") \($0.start ?? -1)" }.joined(separator: ", "))
    }
}
