import AVFoundation
import SwiftUI

/// Sends a project to DaVinci Resolve: its files go into the open Resolve project (only those
/// not there yet), and the edit becomes a new timeline there, with each clip's Inspector
/// settings, a marker per story passage, and the subtitles on a subtitle track.
@MainActor
enum ProjectResolve {
    static var isAvailable: Bool { Resolve.isInstalled }

    struct Result {
        var timeline: String
        var subtitles: String
    }

    static func send(_ project: Project, size: CGSize) async throws -> Result {
        let clips = project.clips.filter { $0.length > 0 }
        guard !clips.isEmpty else { throw ResolveBridge.Failure(message: String(localized: "There are no clips on the timeline.")) }
        let files = Array(Set(clips.map(\.path))).sorted()
        _ = try await ResolveBridge.run(["action": "import", "paths": files, "bin": project.name])
        var rates: [String: Double] = [:]
        for path in files {
            let track = try? await AVURLAsset(url: URL(fileURLWithPath: path)).loadTracks(withMediaType: .video).first
            let rate = Double((try? await track?.load(.nominalFrameRate)) ?? 0)
            rates[path] = rate > 0 ? rate : 25
        }
        let (rate, name) = try await ResolveBridge.createTimeline(project.name, frameRate: rates[clips[0].path] ?? 25)
        var items: [[String: Any]] = [], markers: [[String: Any]] = []
        var record = 0
        for clip in clips {
            let clipRate = rates[clip.path] ?? 25
            // Whole timeline frames first, the source length from those (no gaps between rates).
            // Speed changes can't be set through Resolve's scripting: a sped-up clip goes in at
            // normal speed for the same length, so everything after it (and the subtitles) lines up.
            let frames = Int((clip.length * rate).rounded())
            let sourceIn = Int((clip.start * clipRate).rounded())
            let sourceOut = sourceIn + Int((Double(frames) * clipRate / rate).rounded())
            guard frames > 0, sourceOut > sourceIn else { continue }
            let properties = self.properties(clip.look, size: size)
            for mediaType in [1, 2] {
                var item: [String: Any] = ["path": clip.path, "track": 1, "recordIn": record, "sourceIn": sourceIn,
                                           "sourceOut": sourceOut, "mediaType": mediaType]
                if mediaType == 1, !properties.isEmpty { item["properties"] = properties }
                if mediaType == 1, clip.look?.zoomEnd != nil { item["zoom"] = "inOut" }
                if let role = clip.role { item["clipColor"] = colour(role) }
                items.append(item)
            }
            if let title = clip.title {
                markers.append(["frame": record, "color": clip.role.map(colour) ?? "Blue", "name": String(title.prefix(40)), "note": title])
            }
            record += frames
        }
        for title in project.titles {
            markers.append(["frame": Int((title.start * rate).rounded()), "color": "Purple", "name": String(title.text.prefix(40)),
                            "note": title.text, "duration": max(Int(((title.end - title.start) * rate).rounded()), 1)])
        }
        var instruction: [String: Any] = ["action": "buildTimeline", "name": name, "videoTracks": 1, "items": items, "markers": markers]
        // The subtitles as an .srt Resolve imports (kept in Pluck's folder, so Resolve can find it later).
        let cues = project.subtitleCues
        if !cues.isEmpty {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pluck/Resolve Subtitles", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(name).srt")
            if (try? EditorSubtitleFiles.srt(cues).write(to: file, atomically: true, encoding: .utf8)) != nil { instruction["subtitles"] = file.path }
        }
        let answer = try await ResolveBridge.run(instruction)
        return Result(timeline: (answer["timeline"] as? String) ?? name, subtitles: (answer["subtitles"] as? String) ?? "none")
    }

    /// The look as Resolve's Inspector settings (pixels of the timeline's frame).
    private static func properties(_ look: ClipLook?, size: CGSize) -> [String: Any] {
        guard let look, !look.isDefault else { return [:] }
        var p: [String: Any] = [:]
        switch look.scaling {
        case .fit: break
        case .fill: p["Scaling"] = 3
        case .stretch: p["Scaling"] = 4
        }
        if look.zoom != 1 { p["ZoomX"] = look.zoom; p["ZoomY"] = look.zoom }
        if look.x != 0 { p["Pan"] = look.x * size.width }
        if look.y != 0 { p["Tilt"] = look.y * size.height }
        if look.rotation != 0 { p["RotationAngle"] = look.rotation }
        if look.flipH { p["FlipX"] = true }
        if look.flipV { p["FlipY"] = true }
        if look.cropLeft > 0 { p["CropLeft"] = look.cropLeft * size.width }
        if look.cropRight > 0 { p["CropRight"] = look.cropRight * size.width }
        if look.cropTop > 0 { p["CropTop"] = look.cropTop * size.height }
        if look.cropBottom > 0 { p["CropBottom"] = look.cropBottom * size.height }
        if look.opacity < 1 { p["Opacity"] = look.opacity * 100 }
        return p
    }

    private static func colour(_ role: StoryBeat.Role) -> String {
        switch role {
        case .hook: "Pink"
        case .context: "Blue"
        case .point: "Green"
        case .emotion: "Orange"
        case .ending: "Purple"
        }
    }

    /// Sends it and brings Resolve forward, or says what went wrong.
    static func sendAndShow(_ model: ProjectModel) {
        model.sendingToResolve = true
        Task {
            defer { model.sendingToResolve = false }
            do {
                let result = try await send(model.project, size: model.renderSize)
                if let resolve = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.blackmagic-design.DaVinciResolve") {
                    _ = try? await NSWorkspace.shared.openApplication(at: resolve, configuration: NSWorkspace.OpenConfiguration())
                }
                if result.subtitles == "failed" || result.subtitles == "imported" {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The timeline is in DaVinci Resolve")
                    alert.informativeText = String(localized: "The subtitles are in its media pool: drag them onto the subtitle track.")
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t send to DaVinci Resolve")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// File ▸ Send to DaVinci Resolve: the open project as a timeline in Resolve.
struct SendToResolveCommand: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        if ProjectResolve.isAvailable {
            Button("Send to DaVinci Resolve") {
                if let project = nav.current?.project { ProjectResolve.sendAndShow(project) }
                else if let model = nav.current?.model { Resolve.sendAndShow([model.file]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(nav.current == nil)
        }
    }
}
