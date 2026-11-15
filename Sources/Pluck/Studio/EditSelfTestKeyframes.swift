import AVFoundation
import Foundation

/// Keyframes (-PluckScreenshotOnly keyframes): the curves' maths, editing at the playhead, undo,
/// saving, pasting stretched, what Resolve gets, the viewer against the export, and volume
/// automation in both.
extension EditSelfTest {
    static func keyframes(_ manager: DownloadManager) async {
        curves()
        values()
        await editing()
        resolveBake()
        await keyedExport(manager)
        await volumeAutomation(manager)
    }

    // MARK: - Maths

    private static func curves() {
        let kinds = KeyEase.Kind.allCases.filter { $0 != .custom }
        for kind in kinds {
            let ease = KeyEase(kind)
            let samples = (0...100).map { ease.apply(Double($0) / 100) }
            let rising = zip(samples, samples.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 }
            check("keyframes: \(kind.rawValue) runs 0 to 1, never back, never past",
                  near(samples.first!, 0) && near(samples.last!, 1) && rising && samples.allSatisfy { $0 >= -1e-9 && $0 <= 1 + 1e-9 },
                  "\(samples.first!) … \(samples.last!)")
        }
        let half = kinds.map { ($0, KeyEase($0).apply(0.5)) }
        let expected: [KeyEase.Kind: (Double) -> Bool] = [.linear: { near($0, 0.5) }, .hold: { $0 == 0 }, .easeIn: { $0 < 0.4 },
                                                          .easeOut: { $0 > 0.6 }, .easeInOut: { near($0, 0.5, 0.01) }]
        check("keyframes: each preset at the halfway point", half.allSatisfy { expected[$0.0]?($0.1) ?? false }, "\(half)")
        // CSS's "ease" is cubic-bezier(0.25, 0.1, 0.25, 1): 0.8024 halfway.
        let css = KeyEase(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        check("keyframes: a custom curve matches cubic-bezier", near(css.apply(0.5), 0.8024, 0.002) && near(css.apply(0), 0) && near(css.apply(1), 1),
              "\(css.apply(0.5))")
        let back = KeyEase(x1: 0.3, y1: -0.5, x2: 0.7, y2: 1.5)
        let swing = (0...100).map { back.apply(Double($0) / 100) }
        check("keyframes: handles past 0…1 overshoot", swing.min()! < -0.02 && swing.max()! > 1.02 && near(swing.last!, 1), "\(swing.min()!) \(swing.max()!)")
        // Handles' time outside 0…1 is kept in it: time never runs backwards.
        let wild = KeyEase(x1: -1, y1: 0, x2: 2, y2: 1)
        let xs = (0...100).map { wild.apply(Double($0) / 100) }
        check("keyframes: time never runs backwards", zip(xs, xs.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 })
    }

    private static func values() {
        let frames = [Keyframe(time: 1, value: 10), Keyframe(time: 3, value: 20, ease: KeyEase(.hold)), Keyframe(time: 5, value: 0)]
        check("keyframes: held before the first and after the last", frames.value(at: 0) == 10 && frames.value(at: 9) == 0)
        check("keyframes: straight between two", near(frames.value(at: 2) ?? 0, 15))
        check("keyframes: hold keeps its value to the next", frames.value(at: 4.99) == 20 && frames.value(at: 5) == 0)
        var look = ClipLook()
        look.setKey(.zoom, 1, at: 0)
        look.setKey(.zoom, 2, at: 2)
        check("keyframes: the look resolves", near(look.resolved(at: 1).zoom, 1.5) && look.resolved(at: 1).x == 0)
        // An edit at the playhead: the keyframed setting gets a keyframe, the rest change as before.
        look.edit(at: 1) { $0.zoom = 3; $0.y = 0.2 }
        check("keyframes: an edit keyframes what's keyframed", look.keyframes(.zoom).count == 3 && near(look.resolved(at: 1).zoom, 3) && near(look.y, 0.2),
              "\(look.keyframes(.zoom).map(\.time))")
        var diamond = ClipLook()
        diamond.toggleKey(.opacity, at: 0.5, value: 0.8)
        diamond.toggleKey(.opacity, at: 0.5, value: 0.8)
        check("keyframes: the diamond adds and takes away, the value stays", !diamond.hasKeys && near(diamond.opacity, 0.8))
        var shifted = look
        shifted.shiftKeys(by: 1.5)
        check("keyframes: cut off the start, the motion stays with the footage",
              near(shifted.resolved(at: 0).zoom, look.resolved(at: 1.5).zoom) && near(shifted.resolved(at: 0.5).zoom, look.resolved(at: 2).zoom),
              "\(shifted.keyframes(.zoom).map { ($0.time, $0.value) })")
    }

    // MARK: - Editing

    private static func editing() async {
        let model = await project(["a.mp4", "a.mp4"])
        guard model.project.clips.count == 2 else { return check("keyframes: clips", false) }
        let a = model.project.clips[0].id, b = model.project.clips[1].id
        model.trim(a, start: 0, end: 4, record: true)
        model.trim(b, start: 4, end: 6, record: true)
        model.seek(to: 0)
        model.changeKeys(a) { $0.toggleKey(.zoom, at: 0, value: 1) }
        model.seek(to: 4 - model.frame)
        model.editLook(a, record: true) { $0.zoom = 1.2 }
        let made = model.project.clips[0].look?.keyframes(.zoom) ?? []
        check("keyframes: a slider at the playhead adds a keyframe", made.count == 2 && near(made[1].value, 1.2), "\(made.map { ($0.time, $0.value) })")
        model.undo()
        check("keyframes: undo takes it back", model.project.clips[0].look?.keyframes(.zoom).count == 1)
        model.redo()
        check("keyframes: redo puts it back", model.project.clips[0].look?.keyframes(.zoom).count == 2)
        // Saved and opened again.
        try? ProjectStore.write(model.project)
        let loaded = ProjectStore.load(model.project.id)
        check("keyframes: kept when saved", loaded?.clips.first?.look == model.project.clips[0].look && loaded?.clips.first?.look?.hasKeys == true)
        try? FileManager.default.removeItem(at: ProjectStore.url(for: model.project.id))
        // Copied, pasted stretched onto a clip half as long: the zoom spans it all.
        model.selected = [a]
        model.selectedKeys = []
        check("keyframes: copied", model.copyKeys(a))
        model.pasteKeys(into: [b], stretch: true)
        let stretched = model.project.clips[1].look?.keyframes(.zoom) ?? []
        check("keyframes: paste and stretch to fit", stretched.count == 2 && near(stretched[1].time, (4 - model.frame) / 2, 0.01) && near(stretched[1].value, 1.2),
              "\(stretched.map { ($0.time, $0.value) })")
        model.pasteKeys(into: [b], stretch: false)
        check("keyframes: pasted as they were (past the end left out)", model.project.clips[1].look?.keyframes(.zoom).count == 1)
        // Chosen and deleted, dragged in time, eased.
        model.selected = [a]
        guard let first = model.project.clips[0].look?.keyframes(.zoom).last else { return check("keyframes: one to move", false) }
        let before = model.project.clips[0].look ?? ClipLook()
        model.moveKeys([first.id], of: a, by: -1, from: before, record: false)
        model.changeKeys(a, record: true) { _ in }
        check("keyframes: dragged in time", near(model.project.clips[0].look?.keyframes(.zoom).last?.time ?? 0, first.time - 1, 0.001))
        model.undo()
        check("keyframes: the drag is one undo step", near(model.project.clips[0].look?.keyframes(.zoom).last?.time ?? 0, first.time, 0.001))
        model.setEase(KeyEase(x1: 0.1, y1: 0.9, x2: 0.2, y2: 1), keys: [model.project.clips[0].look!.keyframes(.zoom)[0].id], of: a)
        check("keyframes: a curve set", model.project.clips[0].look?.keyframes(.zoom)[0].ease.kind == .custom)
        model.selectedKeys = [first.id]
        check("keyframes: chosen ones deleted", model.deleteSelectedKeys() && model.project.clips[0].look?.keyframes(.zoom).count == 1)
        // Cut in two: the second half's keyframes go with its footage.
        model.changeKeys(a) { $0.setKey(.x, 0, at: 0); $0.setKey(.x, 0.4, at: 4) }
        model.split(at: 2)
        let second = model.project.clips[1]
        check("keyframes: cut in two, the second half's move continues", near(second.look?.resolved(at: 0).x ?? 0, 0.2, 0.01)
              && near(second.look?.resolved(at: 2).x ?? 0, 0.4, 0.01), "\(second.look?.keyframes(.x).map { ($0.time, $0.value) } ?? [])")
    }

    private static func resolveBake() {
        var clip = ProjectClip(path: "/x.mp4", start: 0, end: 4)
        var look = ClipLook()
        look.setKey(.zoom, 1.2, at: 0); look.setKey(.zoom, 2, at: 4)
        clip.look = look
        let marker = ProjectResolve.keyMarker(clip, at: 10, frames: 100)
        check("keyframes: Resolve gets a marker naming what moves", (marker?["name"] as? String)?.contains("Zoom") == true && marker?["frame"] as? Int == 10,
              "\(String(describing: marker))")
        check("keyframes: Resolve gets the value at the clip's start", near(look.resolved(at: 0).zoom, 1.2))
        check("keyframes: none, no marker", ProjectResolve.keyMarker(ProjectClip(path: "/x.mp4", start: 0, end: 4), at: 0, frames: 1) == nil)
    }

    // MARK: - Viewer against export

    /// Exported with these settings (as Quick Export does); the file, or nil.
    private static func exported(_ model: ProjectModel, _ manager: DownloadManager, audio: Bool) async -> URL? {
        let defaults = UserDefaults.standard
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-keyframe-export-\(UUID().uuidString)")
        defaults.set(folder.path, forKey: Prefs.downloadPath)
        defaults.set(false, forKey: Prefs.askLocation)
        var settings = EditorRenderSettings()
        settings.codec = .h264
        settings.resolution = .p480
        settings.hardware = false
        settings.audioFile = .wav
        defaults.set(settings.saved, forKey: "editorRenderSettings")
        defaults.set(audio, forKey: "projectExportAudio")
        let done = model.exports.finished.count
        quickExport(model, manager: manager)
        for _ in 0..<1200 where model.exports.isRunning || model.exports.finished.count <= done {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard model.exports.finished.count > done, let file = model.exports.output else {
            check("keyframes: export", false, model.exports.problem ?? "no file")
            return nil
        }
        return file
    }

    private static func keyedExport(_ manager: DownloadManager) async {
        let model = await project(["a.mp4", "a.mp4"])
        guard model.project.clips.count == 2, let ffmpeg = manager.tool("ffmpeg") else { return check("keyframes: export clips", false) }
        let a = model.project.clips[0].id, b = model.project.clips[1].id
        model.trim(a, start: 2, end: 6, record: true)
        model.trim(b, start: 8, end: 11, record: true)
        model.setTransition(into: 1, ProjectTransition(kind: .dissolve, length: 0.96))
        model.changeKeys(a) { look in
            look.setKey(.zoom, 1, at: 0); look.setKey(.zoom, 1.8, at: 4)
            look.setKey(.x, 0, at: 0); look.setKey(.x, 0.25, at: 4)
            look.setKey(.opacity, 1, at: 0); look.setKey(.opacity, 0.4, at: 4)
            look.setKeyframes(.x, look.keyframes(.x).map { var k = $0; k.ease = KeyEase(.easeInOut); return k })
            look.setKeyframes(.opacity, look.keyframes(.opacity).map { var k = $0; k.ease = KeyEase(x1: 0.2, y1: 0, x2: 0.3, y2: 1.1); return k })
        }
        check("keyframes: the keyframed clip takes the drawn route, the other ffmpeg's",
              ProjectKeyframeRender.isKeyed(model.project.clips[0]) && !ProjectKeyframeRender.isKeyed(model.project.clips[1]))
        await builtProject(model)
        let times = [1.0, 2.0, 3.0, 5.4]
        var viewer: [[Int]] = []
        for t in times { viewer.append(await previewCells(model, at: t)) }
        guard let file = await exported(model, manager, audio: false) else { return }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for (index, t) in times.enumerated() {
            let apart = cellsDifference(viewer[index], exportCells(file, at: t - 0.02, ffmpeg: ffmpeg))
            check("keyframes: export matches the viewer at \(t) s", apart <= 8, "mean difference ≤ 8/255; got \(apart)")
        }
        check("keyframes: the picture moves", cellsDifference(viewer[0], viewer[2]) > 6, "\(cellsDifference(viewer[0], viewer[2]))")
    }

    // MARK: - Volume

    /// The sound's mean level (dB) over a stretch of a file.
    private static func level(_ file: URL, from: Double, length: Double, ffmpeg: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "info", "-ss", String(format: "%.3f", from), "-t", String(format: "%.3f", length), "-i", file.path,
                             "-af", "volumedetect", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.contains("mean_volume:") }),
              let number = line.split(separator: ":").last?.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces) else { return nil }
        return Double(number)
    }

    private static func volumeAutomation(_ manager: DownloadManager) async {
        let model = await project(["a.mp4"])
        guard let id = model.project.clips.first?.id, let ffmpeg = manager.tool("ffmpeg") else { return check("keyframes: volume clip", false) }
        model.trim(id, start: 0, end: 4, record: true)
        guard let plain = await exported(model, manager, audio: true) else { return }
        defer { try? FileManager.default.removeItem(at: plain.deletingLastPathComponent()) }
        model.changeKeys(id) { look in
            look.setKeyframes(.volume, [Keyframe(time: 0, value: 0), Keyframe(time: 2, value: -20)])
        }
        let arguments = ProjectExports.arguments(model.project, streams: [model.project.clips[0].path: ["audio", "video"]], settings: EditorRenderSettings(),
                                                 audioOnly: true, size: CGSize(width: 640, height: 360), fps: 25, titles: nil, subtitles: nil,
                                                 hardware: false, output: URL(fileURLWithPath: "/tmp/x.wav"))
        check("keyframes: volume as an envelope in the export", arguments.contains { $0.contains("volume=eval=frame") })
        // The viewer: the audio mix's level a second in, halfway down to -20 dB.
        await builtProject(model)
        var viewerGain: Float?
        if let mix = model.player.currentItem?.audioMix {
            for params in mix.inputParameters {
                var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
                if params.getVolumeRamp(for: CMTime(seconds: 1, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range), range.duration.seconds > 0 {
                    let f = Float((1 - range.start.seconds) / range.duration.seconds)
                    viewerGain = start + (end - start) * f
                    break
                }
            }
        }
        check("keyframes: the viewer's volume follows the keyframes", viewerGain.map { abs(Double($0) - pow(10, -10.0 / 20)) < 0.03 } ?? false,
              "\(String(describing: viewerGain)) for \(pow(10, -10.0 / 20))")
        guard let keyed = await exported(model, manager, audio: true) else { return }
        defer { try? FileManager.default.removeItem(at: keyed.deletingLastPathComponent()) }
        for (at, expected) in [(0.95, -10.0), (3.0, -20.0)] {
            guard let a = level(keyed, from: at - 0.05, length: 0.1, ffmpeg: ffmpeg), let b = level(plain, from: at - 0.05, length: 0.1, ffmpeg: ffmpeg) else {
                check("keyframes: export loudness at \(at) s", false, "not measured")
                continue
            }
            check("keyframes: export loudness at \(at) s", abs((a - b) - expected) <= 2.5, "expected \(expected) dB; got \(a - b)")
        }
    }
}
