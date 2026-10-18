import AppKit

/// Tests: one link downloaded into each of several folders in turn, each result written as a line
/// with whatever was left in the folder (screenshot mode "downloadtest").
@MainActor
enum DownloadSelfTest {
    static func run(defaults: UserDefaults, manager: DownloadManager) async {
        guard let link = defaults.string(forKey: "PluckScreenshotLink"), let folders = defaults.string(forKey: "PluckScreenshotFile"),
              let log = defaults.string(forKey: "PluckScreenshotLog") else { return }
        var lines: [String] = []
        for (n, folder) in folders.split(separator: "|").map(String.init).enumerated() {
            // A different link each time, so it isn't taken for a repeat of the one before.
            let url = link + (link.contains("?") ? "&" : "?") + "attempt=\(n)"
            manager.add([url], folder: folder)
            guard let item = manager.items.first(where: { $0.url == url }) else {
                lines.append("\(folder)\tnot added")
                continue
            }
            for _ in 0..<1200 where ![.finished, .failed, .cancelled].contains(item.state) { try? await Task.sleep(for: .milliseconds(250)) }
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().joined(separator: ", ")
            lines.append("\(folder)\t\(item.state)\t\(item.fileURL?.lastPathComponent ?? "-")\t\(item.errorMessage ?? "")\tleft: \(left)")
            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
        lines.append("done")
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
