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
        /// Where it went, to bring the edit back from.
        var link: ResolveLink?
    }

    static func send(_ project: Project, size: CGSize) async throws -> Result {
        let clips = project.clips.filter { $0.length > 0 }
        guard !clips.isEmpty else { throw ResolveBridge.Failure(message: String(localized: "There are no clips on the timeline.")) }
        // The pictures laid over the main line go on V2 and up, a lane each (hidden ones switched off).
        let lanes = (project.tracks ?? []).filter { $0.kind == .video }
        let files = Array(Set(clips.map(\.path) + lanes.flatMap(\.items).map(\.path))).sorted()
        let imported = try await ResolveBridge.run(["action": "import", "paths": files, "bin": project.name])
        // Each file's rate as Resolve counts its frames ("29.97 DF" too), else as the file says.
        var rates: [String: Double] = [:]
        for entry in imported["clips"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String else { continue }
            let text = (entry["fps"] as? String) ?? (entry["fps"] as? NSNumber)?.stringValue ?? ""
            if let fps = Double(text.split(separator: " ").first ?? ""), fps > 0 { rates[path] = fps }
        }
        for path in files where rates[path] == nil {
            let track = try? await AVURLAsset(url: URL(fileURLWithPath: path)).loadTracks(withMediaType: .video).first
            let rate = Double((try? await track?.load(.nominalFrameRate)) ?? 0)
            rates[path] = rate > 0 ? rate : 25
        }
        let (rate, name) = try await ResolveBridge.createTimeline(project.name, frameRate: rates[clips[0].path] ?? 25)
        var items: [[String: Any]] = [], markers: [[String: Any]] = []
        var record = 0
        // Where each linked clip starts there, so what's laid over it keeps its place on it.
        var linkedAt: [UUID: Int] = [:]
        var ownMarkers: [[String: Any]] = []
        for clip in clips {
            let clipRate = rates[clip.path] ?? 25
            // Whole timeline frames first, the source length from those (no gaps between rates).
            // Speed changes can't be set through Resolve's scripting: a sped-up clip goes in at
            // normal speed for the same length, so everything after it (and the subtitles) lines up.
            let frames = Int((clip.length * rate).rounded())
            let sourceIn = Int((clip.start * clipRate).rounded())
            let sourceOut = sourceIn + Int((Double(frames) * clipRate / rate).rounded())
            guard frames > 0, sourceOut > sourceIn else { continue }
            if let link = clip.link { linkedAt[link] = record }
            let properties = self.properties(clip.look, size: size)
            for mediaType in [1, 2] {
                var item: [String: Any] = ["path": clip.path, "track": 1, "recordIn": record, "sourceIn": sourceIn,
                                           "sourceOut": sourceOut, "mediaType": mediaType]
                if mediaType == 1 { item["key"] = clip.id.uuidString }
                if mediaType == 1, !properties.isEmpty { item["properties"] = properties }
                if mediaType == 1, clip.look?.hasDynamicZoom == true { item["zoom"] = "inOut" }
                if let role = clip.role { item["clipColor"] = colour(role) }
                items.append(item)
            }
            if let title = clip.title {
                ownMarkers.append(["frame": record, "color": clip.role.map(colour) ?? "Blue", "name": String(title.prefix(40)), "note": title,
                                   "customData": ProjectResolveRead.ownMarker])
            }
            record += frames
        }
        var laneOf: [UUID: UUID] = [:]
        for (number, lane) in lanes.enumerated() {
            for item in lane.items {
                let itemRate = rates[item.path] ?? 25
                let frames = Int((item.length * rate).rounded())
                let sourceIn = Int((item.start * itemRate).rounded())
                let sourceOut = sourceIn + Int((Double(frames) * itemRate / rate).rounded())
                guard frames > 0, sourceOut > sourceIn else { continue }
                let at = item.link.flatMap { linkedAt[$0] }.map { $0 + Int(((item.linkOffset ?? 0) * rate).rounded()) }
                    ?? Int(((item.at ?? 0) * rate).rounded())
                var entry: [String: Any] = ["path": item.path, "track": number + 2, "recordIn": at,
                                            "sourceIn": sourceIn, "sourceOut": sourceOut, "mediaType": 1, "key": item.id.uuidString]
                let properties = self.properties(item.look, size: size)
                if !properties.isEmpty { entry["properties"] = properties }
                items.append(entry)
                laneOf[item.id] = lane.id
            }
        }
        for title in project.titles {
            ownMarkers.append(["frame": Int((title.start * rate).rounded()), "color": "Purple", "name": String(title.text.prefix(40)),
                               "note": title.text, "duration": max(Int(((title.end - title.start) * rate).rounded()), 1),
                               "customData": ProjectResolveRead.ownMarker])
        }
        // The project's own markers first (they come back when the edit does, by their id), then
        // Pluck's: Resolve keeps one marker per frame, so a later one moves to the next free frame.
        var taken: Set<Int> = []
        let projectMarkers: [[String: Any]] = (project.markers ?? []).map { marker in
            ["frame": Int((marker.time * rate).rounded()), "color": ProjectResolveRead.resolveColour(marker.color),
             "name": marker.title, "note": "", "duration": max(Int(((marker.length ?? 0) * rate).rounded()), 1),
             "customData": ProjectResolveRead.markerPrefix + marker.id.uuidString]
        }
        for var marker in projectMarkers + ownMarkers {
            var frame = marker["frame"] as? Int ?? 0
            while taken.contains(frame) { frame += 1 }
            taken.insert(frame)
            marker["frame"] = frame
            markers.append(marker)
        }
        var instruction: [String: Any] = ["action": "buildTimeline", "name": name, "videoTracks": 1 + lanes.count, "items": items, "markers": markers,
                                          "disabledTracks": lanes.indices.filter { lanes[$0].hidden }.map { $0 + 2 }]
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
        let timeline = (answer["timeline"] as? String) ?? name
        let paths = Dictionary((clips + lanes.flatMap(\.items)).map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let sent: [ResolveLink.Sent] = (answer["sent"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let key = (entry["key"] as? String).flatMap(UUID.init(uuidString:)), let path = paths[key],
                  let start = (entry["start"] as? NSNumber)?.intValue, let end = (entry["end"] as? NSNumber)?.intValue,
                  let sourceStart = (entry["sourceStart"] as? NSNumber)?.doubleValue, let sourceEnd = (entry["sourceEnd"] as? NSNumber)?.doubleValue
            else { return nil }
            return ResolveLink.Sent(id: key, track: (entry["track"] as? NSNumber)?.intValue ?? 1, lane: laneOf[key], path: path,
                                    start: start, end: end, sourceStart: sourceStart, sourceEnd: sourceEnd, fps: rates[path] ?? rate)
        }
        return Result(timeline: timeline, subtitles: (answer["subtitles"] as? String) ?? "none",
                      link: (answer["project"] as? String).map { ResolveLink(project: $0, timeline: timeline, rate: rate, sent: sent) })
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
                if let link = result.link { model.setUp { $0.resolveTimeline = link } }
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

extension ProjectResolve {
    /// Brings the edit back from the timeline it was sent to, and says what came back.
    static func updateAndShow(_ model: ProjectModel) {
        model.sendingToResolve = true
        Task {
            defer { model.sendingToResolve = false }
            let alert = NSAlert()
            do {
                let summary = try await model.updateFromResolve()
                alert.messageText = String(localized: "Updated from DaVinci")
                var lines = [String(localized: "^[\(summary.markers) marker](inflect: true), ^[\(summary.trimmed) trim](inflect: true), ^[\(summary.moved) clip](inflect: true) moved, \(summary.added) added, \(summary.removed) removed.")]
                if !summary.skipped.isEmpty {
                    lines.append(String(localized: "Not brought back: \(summary.skipped.joined(separator: ", "))."))
                }
                alert.informativeText = lines.joined(separator: "\n")
            } catch {
                alert.messageText = String(localized: "Couldn’t update from DaVinci")
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }
}

/// File ▸ Update from DaVinci: the edit back from the timeline the open project was sent to.
struct UpdateFromResolveCommand: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        if ProjectResolve.isAvailable {
            Button("Update from DaVinci") {
                if let project = nav.current?.project { ProjectResolve.updateAndShow(project) }
            }
            .disabled(nav.current?.project?.project.resolveTimeline == nil || nav.current?.project?.sendingToResolve == true)
        }
    }
}

/// File ▸ Send to DaVinci Resolve: the open project as a timeline in Resolve.
struct SendToResolveCommand: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        if ProjectResolve.isAvailable {
            Button("Send to DaVinci") {
                if let project = nav.current?.project { ProjectResolve.sendAndShow(project) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(nav.current == nil || nav.current?.project?.sendingToResolve == true)
        }
    }
}
