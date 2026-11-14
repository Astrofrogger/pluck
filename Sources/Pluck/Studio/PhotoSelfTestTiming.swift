import Foundation

/// First display timing by process (-PluckScreenshotOnly timing): the same 24 MP RAW decoded and developed at the preview's
/// size, caches emptied each time, three runs per process; notes only (to compare processes and builds).
extension PhotoSelfTest {
    static func timing() async {
        let arw = p4Raws.appendingPathComponent("DSC01994.ARW").path
        guard FileManager.default.fileExists(atPath: arw) else { skip("timing", "no RAW"); return }
        func ms(_ start: Date) -> Double { (Date().timeIntervalSince(start) * 1000).rounded() }
        var lines: [String] = []
        for process in [3, 5, 6, 5, 6] {
            var record = PhotoRecord(); record.adjust.process = process
            var runs: [Double] = []
            for _ in 0..<3 {
                BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
                let start = Date()
                if let image = PhotoRender.image(arw, record: record, maxSize: 2048) { _ = PhotoRender.picture(image) }
                runs.append(ms(start))
            }
            // The decode alone, for the share it takes.
            BaseCache.shared.removeAll()
            let d = Date()
            _ = PhotoRender.base(arw, maxSize: 2048, record: record)
            lines.append("p\(process): \(runs) (decode \(ms(d)))")
        }
        note("timing first display ms: " + lines.joined(separator: "; "))
    }

}
