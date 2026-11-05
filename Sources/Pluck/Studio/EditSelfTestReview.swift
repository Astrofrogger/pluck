import AppKit
import CoreImage

/// 3.9.1's review: a copied project keeps its own older titles, a closed project isn't written
/// again by a late title change, a picture two views want still comes when one goes, words
/// without their plate stay readable, and a 4K title is drawn small for the viewer.
extension EditSelfTest {
    static func reviewFixes() async {
        let real = ProjectStore.folder
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-review-\(UUID().uuidString)", isDirectory: true)
        ProjectStore.folder = base.appendingPathComponent("Projects", isDirectory: true)
        defer {
            ProjectStore.folder = real
            try? FileManager.default.removeItem(at: base)
        }
        await copiedTitles(base)
        await lateTitleCommit()
        await twoWanters(base)
        bareInk()
        bigTitleFrames()
    }

    /// A title from before 3.9.1 is a plain video in the project's Titles folder: a copy (or an
    /// import) gets its own, so pruning the original's leaves the copy's.
    private static func copiedTitles(_ base: URL) async {
        var old = Project(name: "Old Title")
        let folder = ProjectModel.titleRenders(old.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("legacy.mov")
        try? Data("title".utf8).write(to: file)
        var track = ProjectTrack(kind: .video)
        track.items = [ProjectClip(path: file.path, start: 0, end: 3)]
        old.tracks = [track]
        old.resolveTimeline = ResolveLink(project: "P", timeline: "T", rate: 25)
        ProjectStore.save(old)
        let outside = base.appendingPathComponent("Old.pluckproject")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(old).write(to: outside)
        let copies = [ProjectStore.duplicate(old.id), ProjectStore.importProject(outside)].compactMap { $0 }
        // The original with its title taken out, closed: its folder pruned.
        old.tracks = []
        ProjectModel(project: old).pruneTitleRenders()
        for (name, copy) in zip(["duplicate", "import"], copies) {
            let path = copy.tracks?.first?.items.first?.path ?? ""
            check("review: a \(name) keeps its own older title", !FileManager.default.fileExists(atPath: file.path)
                  && path.hasPrefix(ProjectModel.titleRenders(copy.id).path + "/") && FileManager.default.fileExists(atPath: path)
                  && ProjectStore.load(copy.id)?.tracks?.first?.items.first?.path == path && copy.resolveTimeline == nil,
                  "its file in its own folder, no Resolve link; got \(path)")
            try? FileManager.default.removeItem(at: ProjectModel.titleRenders(copy.id))
        }
        check("review: duplicate and import both made", copies.count == 2)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A title being typed in when the project closes: the late commit doesn't write it again
    /// (it'd take it out of the Trash).
    private static func lateTitleCommit() async {
        let model = ProjectModel(project: Project(name: "Self Test"))
        guard model.placeTemplate("slab", at: 0), let id = model.selected.first else { return check("review: late title commit", false, "no title") }
        model.setMotion(id, record: false) { $0.placement.texts["name"] = "Late" }
        model.close()
        ProjectStore.update(model.project.id) { $0.trashed = .now }
        try? await Task.sleep(for: .milliseconds(1_800))
        check("review: a closed project isn't written again", ProjectStore.load(model.project.id)?.trashed != nil, "still in the Trash")
        try? FileManager.default.removeItem(at: ProjectModel.titleRenders(model.project.id))
    }

    /// A photo shown in two places (a row and the column view's end): one goes, the picture still comes.
    private static func twoWanters(_ base: URL) async {
        let photo = base.appendingPathComponent("Wanted.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 150, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep.map { NSGraphicsContext(bitmapImageRep: $0) }.map { context in
            NSGraphicsContext.current = context
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 150).fill()
            NSGraphicsContext.current = nil
        }
        try? rep?.representation(using: .png, properties: [:])?.write(to: photo)
        let thumbs = FinderThumbnails.shared
        thumbs.wantPicture(photo)
        thumbs.wantPicture(photo)
        thumbs.forgetPicture(photo)
        for _ in 0..<50 where thumbs.pictures[photo] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check("review: a picture two views want comes when one goes", thumbs.pictures[photo] != nil)
        thumbs.forgetPicture(photo)
    }

    /// Without its plate, words meant for a light plate are white (over the picture).
    private static func bareInk() {
        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var style = MotionStyle()
        style.secondary = .white
        func ink(_ style: MotionStyle) -> MotionColor {
            MotionScene(context: context, canvas: CGSize(width: 4, height: 4), t: 0, style: style.drawn, placement: MotionTemplate.stack.placement,
                        logo: nil, logoPlan: nil, defaults: [:]).ink(on: style.drawn.secondary)
        }
        let on = ink(style)
        style.plates = false
        check("review: words without their plate are white", ink(style) == .white && on == .ink, "dark on the light plate, white without it")
    }

    /// A full-frame card at 3840 × 2160: drawn small for the viewer (faster than full size, as it
    /// was drawn before), shown full size.
    private static func bigTitleFrames() {
        let size = CGSize(width: 3840, height: 2160)
        let card = ProjectMotion(template: "headline", style: MotionStyle(), placement: MotionTemplate.all.first { $0.id == "headline" }!.placement)
        func ms(_ body: (Int) -> Void) -> Int {
            let clock = ContinuousClock.now
            for frame in 0..<10 { body(frame) }
            let each = (ContinuousClock.now - clock) / 10
            return Int(each.components.seconds) * 1000 + Int(each.components.attoseconds / 1_000_000_000_000_000)
        }
        let full = ms { frame in
            let context = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            card.motionTemplate!.render(t: 1 + Double(frame) / 25, in: context, canvas: size, style: card.style, placement: card.placement)
            _ = context.makeImage()
        }
        var extents: [CGRect] = []
        let viewer = ms { frame in extents.append(card.image(at: 1 + Double(frame) / 25, size: size)?.extent ?? .null) }
        check("review: a 4K title frame is full size, drawn smaller (\(viewer) ms a frame, \(full) ms full size)",
              extents.allSatisfy { $0 == CGRect(origin: .zero, size: size) } && viewer < full, "got \(extents.first ?? .null)")
    }
}
