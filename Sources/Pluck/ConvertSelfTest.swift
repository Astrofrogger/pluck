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
        // Output names are taken at once: two asks for the same name get two different files.
        let a = Converting.reserveOutputURL(folder: output, name: "Reserve test", fileExtension: "mp4")
        let b = Converting.reserveOutputURL(folder: output, name: "Reserve test", fileExtension: "mp4")
        let reserved = a != b && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path)
        lines.append("reserve\t\(reserved ? "PASS" : "FAIL")\t\(a.lastPathComponent)\t\(b.lastPathComponent)")
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
        // The same file converted twice side by side: two results, neither over the other.
        if let file = files.first {
            defaults.set(4, forKey: Prefs.maxConcurrent)
            manager.convert([file, file], preset: .audio)
            let pair = Array(manager.items.prefix(2))
            for _ in 0..<1200 where pair.contains(where: { ![.finished, .failed, .cancelled].contains($0.state) }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let names = pair.compactMap { $0.fileURL?.lastPathComponent }
            let ok = names.count == 2 && Set(names).count == 2 && pair.allSatisfy { $0.state == .finished }
            lines.append("concurrent\t\(ok ? "PASS" : "FAIL")\t\(names.joined(separator: " | "))")
        }
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
