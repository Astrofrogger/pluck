import AVFoundation
import CoreImage

/// Looks over a part of the timeline (Task 9): on the picture only there, the same in the export.
extension EditSelfTest {
    static func looks(_ manager: DownloadManager) async {
        await longDucking(manager)
        // An old project has none.
        check("old project has no adjustments", (try? JSONDecoder().decode(Project.self, from: Data(#"{"name":"Old"}"#.utf8)))?.adjustments == nil)

        // a709.mp4: a.mp4 tagged as Rec. 709 (camera files say what they are; untagged ones are guessed).
        let model = await project(["a709.mp4"])
        let id = model.addAdjustment(over: 5...8)
        model.setAdjustment(id, record: true) { $0.color.saturation = -100 }
        check("adding a look is one step", model.adjustment(id)?.color.saturation == -100 && near(model.adjustment(id)?.end ?? 0, 8))
        await built(model)
        let grey = await preview(model, at: 6), colour = await preview(model, at: 1)
        check("adjustment applies in range", (grey?.spread ?? 99) <= 2 && (colour?.spread ?? 0) > 20,
              "spread ≤ 2 at 6 s, > 20 at 1 s; got \(grey?.spread ?? -1), \(colour?.spread ?? -1)")

        // Half of it: halfway between.
        model.setAdjustment(id, record: false) { $0.amount = 0.5 }
        let half = await preview(model, at: 6)
        check("look amount mixes", (half?.spread ?? 0) > 5 && (half?.spread ?? 99) < (colour?.spread ?? 0) - 5,
              "between; got \(half?.spread ?? -1)")
        model.setAdjustment(id, record: true) { $0.amount = 1 }

        // The export: the look made the same way as in the viewer.
        let defaults = UserDefaults.standard
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-look-export-\(UUID().uuidString)")
        defaults.set(folder.path, forKey: Prefs.downloadPath)
        defaults.set(false, forKey: Prefs.askLocation)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = EditorRenderSettings()
        settings.codec = .h264
        settings.resolution = .p480
        settings.hardware = false
        defaults.set(settings.saved, forKey: "editorRenderSettings")
        defaults.set(false, forKey: "projectExportAudio")
        func export() async -> Sample? {
            let done = model.exports.finished.count
            quickExport(model, manager: manager)
            for _ in 0..<480 where model.exports.isRunning || model.exports.finished.count <= done {
                try? await Task.sleep(for: .milliseconds(250))
            }
            return exportedFrame(model.exports.output, at: 6, manager: manager)
        }
        let exported = await export()
        // The same frame without the look, in both: the look should move them alike (the viewer and
        // the export needn't match to the last value without it).
        model.setAdjustment(id, record: true) { $0.amount = 0 }
        await built(model)
        let plainViewer = await preview(model, at: 6), plainExport = await export()
        // Saturation −100 makes each pixel its Rec. 709 brightness, so the grey frame's average is
        // the brightness of the same frame without the look, in the viewer and in the export alike.
        func luma(_ rgb: [Int]?) -> Double {
            guard let rgb, rgb.count == 3 else { return -99 }
            return 0.2126 * Double(rgb[0]) + 0.7152 * Double(rgb[1]) + 0.0722 * Double(rgb[2])
        }
        let viewerOff = abs(Double(grey?.average.first ?? 0) - luma(plainViewer?.average))
        let exportOff = abs(Double(exported?.average.first ?? 0) - luma(plainExport?.average))
        check("adjustment export matches preview", (exported?.spread ?? 99) <= 3 && viewerOff <= 3 && exportOff <= 3,
              "grey at the frame's brightness within 3/255; got spread \(exported?.spread ?? -1), viewer off \(viewerOff), export off \(exportOff)")
        // Without a look, the viewer shows the file's colours as the export writes them.
        let base = zip(plainViewer?.average ?? [], plainExport?.average ?? []).map { abs($0 - $1) }.max() ?? 999
        check("viewer and export colours agree", base <= 4, "within 4/255; viewer \(plainViewer?.average ?? []), export \(plainExport?.average ?? [])")
        model.setAdjustment(id, record: true) { $0.amount = 1 }

        // Taking the export's in-to-out keeps the look where it was in the picture.
        var part = model.project
        part.inPoint = 4
        part.outPoint = 10
        let cut = part.cut(to: 4...10)
        check("in to out moves looks", cut.adjustments?.count == 1 && near(cut.adjustments?[0].start ?? 0, 1) && near(cut.adjustments?[0].end ?? 0, 4))

        model.removeAdjustment(id)
        check("removing the last look", model.project.adjustments == nil)

        // Undo after a click on a look (a drag that changed nothing) doesn't bring back what was undone.
        let other = model.addAdjustment(over: 1...2)
        model.setAdjustment(other, record: true) { $0.color.contrast = 50 }
        model.undo()
        model.setAdjustment(other, record: false) { _ in }
        model.endDrag()
        _ = model.addAdjustment(over: 3...4)
        model.undo()
        check("undo after a click stays undone", model.adjustment(other)?.color.contrast == 0 && model.project.adjustments?.count == 1,
              "contrast 0, one look; got \(model.adjustment(other)?.color.contrast ?? -1), \(model.project.adjustments?.count ?? 0)")
        // A slider let go where it was makes no step.
        model.setAdjustment(other, record: true) { _ in }
        model.undo()
        check("slider let go adds no step", model.project.adjustments == nil, "the look added was undone; got \(model.project.adjustments?.count ?? 0)")
        // Delete with nothing it can take makes no step.
        let steps = model.project.modified
        model.delete([UUID()])
        check("empty delete adds no step", model.project.modified == steps)
    }

    /// A long talk: 3,000 stretches of speech under a song still export (the expression stays
    /// shallow, and the graph goes in a file).
    private static func longDucking(_ manager: DownloadManager) async {
        let spans = (0..<3000).map { Double($0) * 2.0...(Double($0) * 2.0 + 1) }
        let expression = Ducking.ffmpegExpression(Ducking.envelope(spans, amountDB: -12).map { ($0.time, $0.gain) })
        var project = Project(name: "Self Test", clips: [ProjectClip(path: "x", start: 0, end: 6000)],
                              music: [ProjectMusic(path: "m", at: 0, start: 0, end: 6000)])
        project.music[0].duck = -12
        let arguments = ProjectExports.arguments(project, streams: ["x": ["audio"], "m": ["audio"]], settings: EditorRenderSettings(), audioOnly: true,
                                                 size: CGSize(width: 640, height: 360), fps: 25, titles: nil, subtitles: nil, hardware: false,
                                                 output: URL(fileURLWithPath: "/tmp/x.m4a"), speech: spans)
        check("long ducking goes in a file", arguments.contains("-/filter_complex") && !arguments.contains("-filter_complex"),
              "-/filter_complex; got \(arguments.prefix(12))")
        guard let ffmpeg = manager.tool("ffmpeg") else { return check("long ducking runs in ffmpeg", false, "no ffmpeg") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-long-duck-\(UUID().uuidString).txt")
        try? ("[0:a]" + Ducking.smallFrames + "," + expression + "[out]").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=duration=20:sample_rate=48000",
                                 "-/filter_complex", file.path, "-map", "[out]", "-f", "null", "-"]
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        check("long ducking runs in ffmpeg", status == 0, "exit 0; got \(status) (\(expression.utf8.count) characters)")
    }

    /// A frame's average colour and how far apart its channels get (0–255), from 8 × 8 cells.
    struct Sample { var average: [Int]; var spread: Int }

    private static func sample(_ pixels: [UInt8], stride: Int) -> Sample {
        var sums = [0, 0, 0], spread = 0, count = 0
        for i in Swift.stride(from: 0, to: pixels.count - 2, by: stride) {
            let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            for k in 0..<3 { sums[k] += rgb[k] }
            spread = max(spread, rgb.max()! - rgb.min()!)
            count += 1
        }
        return Sample(average: sums.map { $0 / max(count, 1) }, spread: spread)
    }

    /// Waits for the edit to be built with what the project has now.
    private static func built(_ model: ProjectModel) async {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if model.player.currentItem?.videoComposition != nil { break }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func preview(_ model: ProjectModel, at seconds: Double) async -> Sample? {
        guard let item = model.player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        // Its own pixels, unconverted, averaged as ffmpeg does (on the encoded values).
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sums = [0, 0, 0]
        for i in stride(from: 0, to: pixels.count, by: 4) { for k in 0..<3 { sums[k] += Int(pixels[i + k]) } }
        // Spread: from 8 × 8 cells' averages (as the export's area-scaled frame).
        var cells: [UInt8] = []
        for cy in 0..<8 {
            for cx in 0..<8 {
                var cell = [0, 0, 0], count = 0
                for y in (cy * height / 8)..<((cy + 1) * height / 8) {
                    for x in (cx * width / 8)..<((cx + 1) * width / 8) {
                        let i = (y * width + x) * 4
                        for k in 0..<3 { cell[k] += Int(pixels[i + k]) }
                        count += 1
                    }
                }
                cells += cell.map { UInt8($0 / max(count, 1)) } + [255]
            }
        }
        var result = sample(cells, stride: 4)
        result.average = sums.map { $0 / max(width * height, 1) }
        return result
    }

    private static func exportedFrame(_ file: URL?, at seconds: Double, manager: DownloadManager) -> Sample? {
        guard let file, let ffmpeg = manager.tool("ffmpeg") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-ss", String(seconds), "-i", file.path, "-frames:v", "1",
                             "-vf", "scale=8:8:flags=area:in_color_matrix=bt709:in_range=tv", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.count >= 192 ? sample([UInt8](data), stride: 3) : nil
    }
}
