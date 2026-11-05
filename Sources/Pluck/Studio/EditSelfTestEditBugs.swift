import AVFoundation
import CoreImage

/// The Edit page after 3.9.0's run-through: titles go in at once and can be changed, ⌫ takes out
/// titles and looks, the inspector follows what's chosen, Canon Log 2, and the transitions.
extension EditSelfTest {
    static func editBugs(_ manager: DownloadManager) async {
        await titles()
        await deleting()
        inspectorFollows()
        canonLog2()
        await transitions(manager)
    }

    // MARK: - Titles

    private static func titles() async {
        let model = await project(["a.mp4"])
        // Dropped: on the timeline at once (drawn by the viewer, rendered in the background).
        let clock = ContinuousClock.now
        let placed = await model.apply(.title(templateID: "slab"), at: 1)
        let took = ContinuousClock.now - clock
        let items = (model.project.tracks ?? []).flatMap(\.items)
        check("title drop is instant", placed && items.count == 1 && took < .milliseconds(100), "under 100 ms; got \(took), \(items.count) items")
        guard let item = items.first, let motion = item.motion?.timed(item) else { return check("title drop keeps its template", false) }
        check("dropped title is chosen", model.selected == [item.id] && model.chosen == .title)

        let size = CGSize(width: 640, height: 360)
        func pixels(_ motion: ProjectMotion) -> [UInt8] {
            guard let image = motion.image(at: 2.5, size: size) else { return [] }
            var data = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            ciContext.render(image, toBitmap: &data, rowBytes: Int(size.width) * 4, bounds: image.extent, format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return data
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / max(a.count / 4, 1) }
        func covered(_ p: [UInt8]) -> Int { stride(from: 3, to: p.count, by: 4).filter { p[$0] > 8 }.count }
        let base = pixels(motion)

        // The words, the colours and the plate, each changing the drawn frame (undoable).
        model.setMotion(item.id, record: true) { $0.placement.texts["name"] = "Sam Rivera" }
        var changed = model.project.tracks?.first?.items.first
        check("title text changes its frame", difference(base, pixels(changed!.motion!.timed(changed!))) > 0 && changed?.motion?.placement.texts["name"] == "Sam Rivera",
              "the frame and the text changed")
        check("title text changes its export file", changed.flatMap { model.titleFile($0) } != model.titleFile(item))
        model.undo()
        check("title text is undoable", model.project.tracks?.first?.items.first?.motion?.placement.texts["name"] == nil)

        model.setMotion(item.id, record: true) { $0.style.text = MotionColor(r: 1, g: 0.85, b: 0) }
        changed = model.project.tracks?.first?.items.first
        check("title colour changes its frame", difference(base, pixels(changed!.motion!.timed(changed!))) > 0)
        model.setMotion(item.id, record: true) { $0.style.plates = false }
        changed = model.project.tracks?.first?.items.first
        let bare = pixels(changed!.motion!.timed(changed!))
        check("background off leaves just the words", covered(bare) < covered(base) / 2 && covered(bare) > 0,
              "fewer than half as many pixels covered; \(covered(base)) → \(covered(bare))")
        // A full-frame card: see-through without its background, so it renders with an alpha.
        var card = ProjectMotion(template: "headline", style: MotionStyle(), placement: MotionTemplate.all.first { $0.id == "headline" }!.placement)
        let opaque = card.transparent
        card.style.plates = false
        let corner = pixels(card).prefix(4)
        check("background off makes a card see-through", !opaque && card.transparent && corner.last == 0, "corner alpha \(Array(corner))")

        // Typing: one step once it pauses.
        let steps = model.canUndo
        model.setMotion(item.id, record: false) { $0.placement.texts["role"] = "D" }
        model.setMotion(item.id, record: false) { $0.placement.texts["role"] = "Director" }
        try? await Task.sleep(for: .seconds(1.2))
        model.undo()
        check("typing in a title is one undo step", steps && model.project.tracks?.first?.items.first?.motion?.placement.texts["role"] == nil)

        // The viewer draws it (no file needed): the frame under it changes with the plate.
        model.setMotion(item.id, record: true) { $0.style.plates = nil }
        await builtProject(model)
        let withPlate = await previewCells(model, at: 3.5)
        model.setMotion(item.id, record: true) { $0.style.plates = false }
        let without = await previewCells(model, at: 3.5)
        check("viewer draws the title live", !withPlate.isEmpty && cellsDifference(withPlate, without) > 0.3,
              "plate on and off differ; got \(cellsDifference(withPlate, without))")
    }

    // MARK: - ⌫

    private static func deleting() async {
        let model = await project(["a.mp4"])
        _ = await model.apply(.title(templateID: "pill"), at: 1)
        let look = model.addAdjustment(over: 2...4)
        let titleID = model.addTitle(at: 5)
        guard let item = (model.project.tracks ?? []).flatMap(\.items).first else { return check("delete: a title to take out", false) }

        model.selected = [item.id]
        model.deleteSelection()
        check("⌫ takes out a title", (model.project.tracks ?? []).flatMap(\.items).isEmpty)
        model.undo()
        check("taking out a title is undoable", (model.project.tracks ?? []).flatMap(\.items).count == 1)

        // A look chosen while a plain title was chosen before: the look goes, the title stays.
        model.selectedTitle = titleID
        model.selected = [look]
        model.deleteSelection()
        check("⌫ takes out a colour layer", model.project.adjustments == nil && model.project.titles.count == 1,
              "\(model.project.adjustments?.count ?? 0) looks, \(model.project.titles.count) titles")
        model.undo()
        check("taking out a colour layer is undoable", model.project.adjustments?.count == 1)

        model.selected = []
        model.selectedTitle = titleID
        model.deleteSelection()
        check("⌫ takes out a plain title", model.project.titles.isEmpty)
        let clips = model.project.clips.count
        model.selected = Set(model.project.clips.map(\.id))
        model.deleteSelection()
        check("⌫ still takes out clips", clips == 1 && model.project.clips.isEmpty)
    }

    private static func inspectorFollows() {
        typealias Tab = ProjectInspector.Tab
        check("title chosen opens Text", Tab.following(.audio, .title) == .text && Tab.following(.colour, .title) == .text)
        check("look chosen opens Colour", Tab.following(.clip, .look) == .colour && Tab.following(.text, .look) == .colour)
        check("clip chosen keeps the tab", Tab.following(.audio, .clip) == .audio && Tab.following(.colour, .clip) == .colour
              && Tab.following(.export, .clip) == .export)
        check("clip chosen leaves Text for Clip", Tab.following(.text, .clip) == .clip)
        check("nothing chosen keeps the tab", Tab.following(.ai, .nothing) == .ai)
    }

    // MARK: - Canon Log 2

    private static func canonLog2() {
        let log = CameraLog.canonLog2
        // Canon's curve puts 18 % grey at 39.8 % (colour-science's log_encoding_CanonLog2(0.18)); Canon's
        // own table rounds it to 39.2 %.
        check("Canon Log 2 grey", near(log.linear(0.398254694), 0.18, 0.0005) && near(log.linear(0.392), 0.18, 0.015),
              "0.18; got \(log.linear(0.398254694)), \(log.linear(0.392))")
        check("Canon Log 2 is black to white, Cinema Gamut", !log.codeValues && log.primaries.map(\.0) == CameraLog.canonLog3.primaries.map(\.0))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-clog2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("A001C001.MXF")
        try? Data("<Gamma>Canon Log 2</Gamma><ColorSpace>Cinema Gamut</ColorSpace>".utf8).write(to: file)
        check("Canon Log 2 found in metadata", CameraLog.detect(file.path) == .canonLog2, "\(String(describing: CameraLog.detect(file.path)))")
    }

    // MARK: - Transitions

    /// Every transition that shows both pictures, between a colour clip and a grey one: its middle
    /// frame is neither, and the export draws it as the viewer does.
    private static func transitions(_ manager: DownloadManager) async {
        let kinds = ProjectTransition.Kind.allCases.filter(\.overlaps)
        let model = await project(Array(repeating: "a.mp4", count: kinds.count + 1))
        guard model.project.clips.count == kinds.count + 1 else { return check("transitions: clips", false) }
        for (index, clip) in model.project.clips.enumerated() {
            model.trim(clip.id, start: 3, end: 4.6, record: true)
            // Every other one mirrored (its picture, not its colour: the viewer's and export's greys aren't the subject here).
            if index % 2 == 1 { model.set(clip.id) { var look = ClipLook(); look.flipH = true; look.flipV = true; $0.look = look } }
        }
        // 0.96 s: whole frames either side of the cut (a half frame would start ffmpeg's half a frame off).
        for (index, kind) in kinds.enumerated() { model.setTransition(into: index + 1, ProjectTransition(kind: kind, length: 0.96)) }
        check("transitions: every kind is kept", kinds.indices.allSatisfy { model.transition(into: $0 + 1)?.kind == kinds[$0] })
        await builtProject(model)
        // On the frame (the viewer draws the very time asked for; ffmpeg's -ss takes the frame at or after it).
        let cuts = model.offsets.map { ($0 * 25).rounded() / 25 }
        var viewer: [[Int]] = [], outgoing: [[Int]] = [], incoming: [[Int]] = []
        for index in kinds.indices {
            viewer.append(await previewCells(model, at: cuts[index + 1]))
            outgoing.append(await previewCells(model, at: cuts[index + 1] - 0.6))
            incoming.append(await previewCells(model, at: cuts[index + 1] + 0.6))
        }

        let defaults = UserDefaults.standard
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-transition-export-\(UUID().uuidString)")
        defaults.set(folder.path, forKey: Prefs.downloadPath)
        defaults.set(false, forKey: Prefs.askLocation)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = EditorRenderSettings()
        settings.codec = .h264
        settings.resolution = .p480
        settings.hardware = false
        defaults.set(settings.saved, forKey: "editorRenderSettings")
        defaults.set(false, forKey: "projectExportAudio")
        let done = model.exports.finished.count
        quickExport(model, manager: manager)
        for _ in 0..<1200 where model.exports.isRunning || model.exports.finished.count <= done {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let file = model.exports.output, model.exports.finished.count > done, let ffmpeg = manager.tool("ffmpeg") else {
            return check("transitions: export", false, model.exports.problem ?? "no file")
        }
        for (index, kind) in kinds.enumerated() {
            let exported = exportCells(file, at: cuts[index + 1] - 0.02, ffmpeg: ffmpeg)
            let fromBoth = min(cellsDifference(viewer[index], outgoing[index]), cellsDifference(viewer[index], incoming[index]))
            check("transition \(kind.rawValue): middle is neither clip", fromBoth > 6, "mean difference > 6; got \(fromBoth)")
            let apart = cellsDifference(viewer[index], exported)
            check("transition \(kind.rawValue): export matches the viewer", apart <= 8, "mean difference ≤ 8/255; got \(apart)")
        }
    }

    // MARK: - Frames

    private static let ciContext = CIContext()

    private static func builtProject(_ model: ProjectModel) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if model.player.currentItem?.videoComposition != nil { break }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The viewer's frame as 8 × 8 cells of RGB (0–255), the file's own numbers.
    private static func previewCells(_ model: ProjectModel, at seconds: Double) async -> [Int] {
        guard let item = model.player.currentItem else { return [] }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return [] }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var cells: [Int] = []
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
                cells += cell.map { $0 / max(count, 1) }
            }
        }
        return cells
    }

    /// The exported frame at a time as 8 × 8 cells of RGB.
    private static func exportCells(_ file: URL, at seconds: Double, ffmpeg: String) -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-ss", String(format: "%.3f", seconds), "-i", file.path, "-frames:v", "1",
                             "-vf", "scale=in_color_matrix=bt709:in_range=tv,format=rgb24,scale=8:8:flags=area", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.count >= 192 ? data.prefix(192).map { Int($0) } : []
    }

    /// The mean difference between two frames' cells (0–255; large when one is missing).
    private static func cellsDifference(_ a: [Int], _ b: [Int]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        return Double(zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(a.count)
    }
}
