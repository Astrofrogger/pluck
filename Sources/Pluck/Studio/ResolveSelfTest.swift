import AppKit

/// A round trip through a running DaVinci Resolve (screenshot mode "resolvetest"), in two runs:
/// -PluckScreenshotResolve send|update, -PluckScreenshotProject <project.json>,
/// -PluckScreenshotLink <link.json> (written by send, read by update), -PluckScreenshotLog <file>.
/// The project open in Resolve is the one used; the timeline is changed there in between.
@MainActor
enum ResolveSelfTest {
    static func run(defaults: UserDefaults) async {
        guard let log = defaults.string(forKey: "PluckScreenshotLog"),
              let projectFile = defaults.string(forKey: "PluckScreenshotProject"),
              let linkFile = defaults.string(forKey: "PluckScreenshotLink") else { return }
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var project = try decoder.decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: projectFile)))
            if defaults.string(forKey: "PluckScreenshotResolve") == "update" {
                project.resolveTimeline = try JSONDecoder().decode(ResolveLink.self, from: Data(contentsOf: URL(fileURLWithPath: linkFile)))
                let model = ProjectModel(project: project)
                let summary = try await model.updateFromResolve()
                say("summary markers=\(summary.markers) moved=\(summary.moved) trimmed=\(summary.trimmed) added=\(summary.added) removed=\(summary.removed) skipped=\(summary.skipped)")
                for clip in model.project.clips {
                    say(String(format: "clip %@ %@ %.3f-%.3f zoom=%.1f volume=%.2f", clip.id.uuidString.prefix(13).description,
                               URL(fileURLWithPath: clip.path).lastPathComponent, clip.start, clip.end, clip.look?.zoom ?? 1, clip.volume))
                }
                for item in (model.project.tracks ?? []).flatMap(\.items) {
                    say(String(format: "item %@ %@ %.3f-%.3f at=%.3f", item.id.uuidString.prefix(13).description,
                               URL(fileURLWithPath: item.path).lastPathComponent, item.start, item.end, item.at ?? -1))
                }
                for marker in model.project.markers ?? [] {
                    say(String(format: "marker %@ %.3f %@ %@", marker.id.uuidString.prefix(13).description, marker.time, marker.title, marker.color.rawValue))
                }
            } else {
                let result = try await ProjectResolve.send(project, size: CGSize(width: 1280, height: 720))
                guard let link = result.link else { say("FAIL no link"); throw CancellationError() }
                try JSONEncoder().encode(link).write(to: URL(fileURLWithPath: linkFile))
                say("sent \(link.project) / \(link.timeline) at \(link.rate), \(link.sent?.count ?? 0) placed")
                for entry in link.sent ?? [] {
                    say("placed \(entry.id.uuidString.prefix(13)) V\(entry.track) \(entry.start)-\(entry.end) source \(entry.sourceStart)-\(entry.sourceEnd) fps \(entry.fps)")
                }
            }
        } catch {
            say("FAIL \(error.localizedDescription)")
        }
        say("done")
        NSApp.terminate(nil)
    }
}
