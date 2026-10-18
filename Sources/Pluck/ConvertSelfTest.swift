import AppKit

/// Tests: every file in a folder through each of the conversions, one at a time, each result
/// written as a line (screenshot mode "converttest").
@MainActor
enum ConvertSelfTest {
    static func run(defaults: UserDefaults, manager: DownloadManager) async {
        guard let folder = defaults.string(forKey: "PluckScreenshotFile"), let output = defaults.string(forKey: "PluckScreenshotOutput"),
              let log = defaults.string(forKey: "PluckScreenshotLog") else { return }
        defaults.set(output, forKey: Prefs.downloadPath)
        defaults.set(false, forKey: Prefs.askLocation)
        let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let presets: [(Conversion.Preset, Int?)] = [(.mp4, nil), (.audio, nil), (.gif, nil), (.smaller, nil), (.compress, 30)]
        var lines: [String] = []
        for file in files {
            for (preset, percent) in presets {
                manager.convert([file], preset: preset, percent: percent)
                guard let item = manager.items.first else { continue }
                for _ in 0..<1200 where ![.finished, .failed, .cancelled].contains(item.state) { try? await Task.sleep(for: .milliseconds(250)) }
                lines.append("\(file.lastPathComponent)\t\(preset)\t\(item.state)\t\(item.fileURL?.lastPathComponent ?? "-")\t\(item.errorMessage ?? "")")
                try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
            }
        }
        lines.append("done")
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
