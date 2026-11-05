import AppKit
import CoreImage

/// A title from a motion template (the Logo Animator's, in the Brand Pack's style), laid over the
/// picture on a track. The viewer draws it as it plays, so it goes in at once and every change
/// shows straight away; a video of it is rendered in the background (once per look, kept with the
/// project) for the export and DaVinci Resolve.
struct ProjectMotion: Codable, Hashable, Sendable {
    var template: String
    var style: MotionStyle
    var placement: MotionPlacement

    var motionTemplate: MotionTemplate? { MotionTemplate.all.first { $0.id == template } }

    /// As drawn on a track item: its outro at the item's end (stretching it retimes it).
    func timed(_ item: ProjectClip) -> ProjectMotion {
        var motion = self
        motion.placement.duration = max(item.end, 0.2)
        return motion
    }

    /// See-through around the words (a card with its background fills the frame).
    var transparent: Bool { !(motionTemplate?.fullFrame == true && style.drawn.background != nil) }

    // MARK: - Drawn for the viewer

    nonisolated(unsafe) private static var drawn: [String: CIImage] = [:]
    private static let lock = NSLock()

    /// The frame `t` seconds in, at the edit's size: drawn at most 1920 wide and scaled up (on the
    /// CPU, a 4K frame each time is too slow to play; the export renders it full size). The last
    /// two kept: a paused viewer asks again.
    func image(at t: Double, size: CGSize) -> CIImage? {
        guard let template = motionTemplate, size.width >= 2, size.height >= 2 else { return nil }
        let key = "\(hashValue)@\(Int((t * 600).rounded()))-\(Int(size.width))x\(Int(size.height))"
        if let known = Self.lock.withLock({ Self.drawn[key] }) { return known }
        let scale = min(1, 1920 / size.width)
        let drawn = CGSize(width: max((size.width * scale).rounded(), 2), height: max((size.height * scale).rounded(), 2))
        guard let context = CGContext(data: nil, width: Int(drawn.width), height: Int(drawn.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        template.render(t: max(t, 0), in: context, canvas: drawn, style: style, placement: placement)
        guard let made = context.makeImage() else { return nil }
        var image = CIImage(cgImage: made)
        if drawn != size {
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / drawn.width, y: size.height / drawn.height), highQualityDownsample: true)
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        Self.lock.withLock {
            if Self.drawn.count >= 2 { Self.drawn.removeAll() }
            Self.drawn[key] = image
        }
        return image
    }

    // MARK: - Rendered for the export

    /// The video of it at this size and rate, named for what's in it (the same title, the same file).
    func file(in folder: URL, size: CGSize, rate: Int) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var name: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ((try? encoder.encode(self)) ?? Data()) + Data("\(Int(size.width))x\(Int(size.height))@\(rate)".utf8) {
            name = (name ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return folder.appendingPathComponent("\(template)-\(String(name, radix: 16)).\(transparent ? "mov" : "mp4")")
    }

    /// Renders being made, by file (the background one and an export's share one).
    @MainActor private static var making: [String: Task<Void, Error>] = [:]

    /// Its video, rendered unless it's there already.
    @MainActor
    func render(to url: URL, size: CGSize, rate: Int, ffmpeg: String) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        if let running = Self.making[url.path] { return try await running.value }
        guard let template = motionTemplate else { throw CocoaError(.fileNoSuchFile) }
        let style = style, placement = placement, transparent = transparent
        let task = Task {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written aside, then moved: a file there is always whole.
            let part = url.deletingLastPathComponent().appendingPathComponent("part-" + url.lastPathComponent)
            do {
                try await LogoAnimation.writeVideo(to: part, size: size, frameRate: rate, length: placement.duration, transparent: transparent,
                                                   motionBlur: 3, ffmpeg: ffmpeg, progress: { _ in }) { t, context in
                    template.render(t: t, in: context, canvas: size, style: style, placement: placement)
                }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: part, to: url)
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
        }
        Self.making[url.path] = task
        defer { Self.making[url.path] = nil }
        try await task.value
    }

    /// The project with each title's video rendered and its items pointing at them (for the
    /// export and DaVinci Resolve).
    @MainActor
    static func rendered(_ project: Project, size: CGSize, fps: Double, ffmpeg: String) async throws -> Project {
        var project = project
        let folder = ProjectModel.titleRenders(project.id), rate = max(Int(fps.rounded()), 1)
        for t in (project.tracks ?? []).indices {
            for i in project.tracks![t].items.indices {
                let item = project.tracks![t].items[i]
                guard let motion = item.motion?.timed(item) else { continue }
                let url = motion.file(in: folder, size: size, rate: rate)
                try await motion.render(to: url, size: size, rate: rate, ffmpeg: ffmpeg)
                project.tracks![t].items[i].path = url.path
            }
        }
        return project
    }
}

extension ProjectModel {
    /// Where this project's rendered titles are kept: with Pluck's data, so they stay as long as
    /// the project uses them (Caches can be emptied by macOS).
    nonisolated static func titleRenders(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Titles/\(id.uuidString)", isDirectory: true)
    }

    var titleRenders: URL { Self.titleRenders(project.id) }

    /// The file a title item's video is (or will be) in, at the edit's size and rate.
    func titleFile(_ item: ProjectClip) -> URL? {
        item.motion.map { $0.timed(item).file(in: titleRenders, size: renderSize, rate: max(Int(frameRate.rounded()), 1)) }
    }

    /// A motion template laid over the picture where it was dropped, at once: the viewer draws it,
    /// and its video is rendered in the background. Chosen, to change in the inspector.
    func placeTemplate(_ id: String, at seconds: Double) -> Bool {
        guard let template = MotionTemplate.all.first(where: { $0.id == id }) else { return false }
        let kit = BrandKit.shared
        var item = ProjectClip(path: "", start: 0, end: kit.placement(template).duration)
        item.motion = ProjectMotion(template: template.id, style: kit.style, placement: kit.placement(template))
        item.title = template.name
        item.ownAudio = false
        item.at = seconds
        item.path = titleFile(item)?.path ?? ""
        change { project in
            let index = Self.track(.video, in: &project)
            project.tracks![index].items.append(item)
        }
        selected = [item.id]
        selectedTitle = nil
        libraryProblem = nil
        renderTitlesSoon()
        return true
    }

    /// Renders the titles' videos a moment after the last change, off the main thread.
    func renderTitlesSoon() {
        titleRender?.cancel()
        titleRender = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") else { return }
            for item in (project.tracks ?? []).flatMap(\.items) {
                guard !Task.isCancelled, let motion = item.motion?.timed(item), let url = titleFile(item) else { continue }
                do {
                    try await motion.render(to: url, size: renderSize, rate: max(Int(frameRate.rounded()), 1), ffmpeg: ffmpeg)
                } catch {
                    libraryProblem = error.localizedDescription
                }
            }
        }
    }

    /// Removes rendered titles the timeline doesn't use any more (when the project closes, so
    /// undo can't bring one back).
    func pruneTitleRenders() {
        let items = (project.tracks ?? []).flatMap(\.items)
        let used = Set(items.map(\.path) + items.compactMap { titleFile($0)?.path })
        let files = (try? FileManager.default.contentsOfDirectory(at: titleRenders, includingPropertiesForKeys: nil)) ?? []
        for file in files where !used.contains(file.path) { try? FileManager.default.removeItem(at: file) }
    }
}
