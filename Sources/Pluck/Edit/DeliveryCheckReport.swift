import AppKit
import AVFoundation
import CryptoKit

/// What happens with a report: findings marked intended, a frame per finding, an approved
/// earlier version to compare with, and the PDF, CSV and Resolve marker files.
extension DeliveryCheck {
    // MARK: - Marked intended

    static let intendedKey = "deliveryCheckIntended"

    /// The file's content (its size, first and last megabyte), so a renamed copy keeps its marks
    /// and a new export of the same name doesn't.
    static func contentKey(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return file.path }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var hash = SHA256()
        hash.update(data: Data(String(size).utf8))
        try? handle.seek(toOffset: 0)
        hash.update(data: (try? handle.read(upToCount: 1 << 20)) ?? Data())
        try? handle.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
        hash.update(data: (try? handle.read(upToCount: 1 << 20)) ?? Data())
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func intended(_ fileKey: String) -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: intendedKey)?[fileKey] as? [String]) ?? [])
    }

    static func setIntended(_ issue: Issue, fileKey: String, _ on: Bool) {
        var all = UserDefaults.standard.dictionary(forKey: intendedKey) ?? [:]
        var keys = Set((all[fileKey] as? [String]) ?? [])
        if on { keys.insert(issue.key) } else { keys.remove(issue.key) }
        all[fileKey] = keys.isEmpty ? nil : Array(keys).sorted()
        UserDefaults.standard.set(all, forKey: intendedKey)
    }

    // MARK: - Frames

    /// The frame at each time, `width` wide.
    static func thumbnails(_ file: URL, times: [Double], width: CGFloat = 320) async -> [Double: CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [Double: CGImage] = [:]
        for time in Set(times).sorted() {
            if Task.isCancelled { break }
            result[time] = try? await generator.image(at: CMTime(seconds: time + 0.02, preferredTimescale: 600)).image
        }
        return result
    }

    // MARK: - Against an approved version

    /// What changed since the approved version: the length, the loudness, and findings it didn't have.
    static func compare(_ report: Report, approved: Report) -> [Issue] {
        var issues: [Issue] = []
        let frame = 1 / max(report.fps, 1)
        if abs(report.duration - approved.duration) >= frame {
            issues.append(Issue(severity: .warning, title: String(localized: "Length changed"),
                                detail: "\(timecode(approved.duration, fps: approved.fps)) → \(timecode(report.duration, fps: report.fps))", kind: .compare))
        }
        if let now = report.loudness, let before = approved.loudness, abs(now - before) >= 1 {
            issues.append(Issue(severity: .warning, title: String(localized: "Loudness changed"),
                                detail: String(format: "%.1f → %.1f LUFS", before, now), kind: .compare))
        }
        return issues
    }

    /// The report's findings, those the approved version didn't have marked new.
    static func markNew(_ issues: [Issue], approved: Report) -> [Issue] {
        issues.map { issue in
            var issue = issue
            guard issue.severity != .note, issue.kind != .compare else { return issue }
            issue.isNew = !approved.issues.contains { old in
                old.title == issue.title && (old.time == nil) == (issue.time == nil) && abs((old.time ?? 0) - (issue.time ?? 0)) < 0.5
            }
            return issue
        }
    }

    // MARK: - Files

    static func severityLabel(_ severity: Issue.Severity) -> String {
        switch severity {
        case .problem: String(localized: "Problem")
        case .warning: String(localized: "To check")
        case .note: String(localized: "Note")
        }
    }

    static func csv(_ report: Report, issues: [Issue]) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { ",\"\n".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var lines = ["Severity,Timecode,Seconds,End,Kind,Title,Detail,New"]
        for issue in issues {
            lines.append([severityLabel(issue.severity), issue.time.map { timecode($0, fps: report.fps) } ?? "",
                          issue.time.map { String(format: "%.3f", $0) } ?? "", issue.end.map { String(format: "%.3f", $0) } ?? "",
                          issue.kind.rawValue, issue.title, issue.detail, issue.isNew ? "1" : ""].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Timeline markers for DaVinci Resolve (problems red, things to check yellow, notes blue).
    static func markerEDL(_ report: Report, issues: [Issue]) -> String {
        let markers = issues.compactMap { issue -> (time: Double, colour: String, note: String)? in
            guard let time = issue.time else { return nil }
            let colour = issue.severity == .problem ? "ResolveColorRed" : issue.severity == .warning ? "ResolveColorYellow" : "ResolveColorBlue"
            return (time, colour, "\(severityLabel(issue.severity)): \(issue.title). \(issue.detail)")
        }
        return RemoteReview.markerEDL(markers, title: report.file.deletingPathExtension().lastPathComponent, fps: report.fps)
    }

    /// An A4 report: the file, the spec, the facts, then each finding with its frame.
    static func pdf(_ report: Report, issues: [Issue], thumbnails: [Double: CGImage]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let margin: CGFloat = 40, width = box.width - margin * 2
        var y: CGFloat = 0
        func page() {
            if y > 0 { NSGraphicsContext.restoreGraphicsState(); context.endPDFPage() }
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: box.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            y = margin
        }
        func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, colour: NSColor = .black, x: CGFloat = margin, width: CGFloat = width) -> CGFloat {
            let attributed = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour])
            let height = ceil(attributed.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
            attributed.draw(with: CGRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin])
            return height
        }
        page()
        y += text(String(localized: "Delivery check: \(report.file.lastPathComponent)"), size: 16, weight: .semibold) + 4
        y += text(report.spec.title, size: 10, colour: .darkGray) + 12
        for fact in report.facts {
            _ = text(fact.0, size: 9, colour: .darkGray, width: 110)
            y += text(fact.1, size: 9, x: margin + 110, width: width - 110) + 3
        }
        y += 14
        if issues.isEmpty { y += text(String(localized: "Ready to deliver: nothing found."), size: 11) }
        let thumbWidth: CGFloat = 120
        for issue in issues {
            let image = issue.time.flatMap { thumbnails[$0] }
            let thumbHeight = image.map { thumbWidth * CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? 0
            if y + max(thumbHeight, 40) > box.height - margin { page() }
            let top = y
            if let image {
                NSImage(cgImage: image, size: .zero).draw(in: CGRect(x: margin, y: y, width: thumbWidth, height: thumbHeight),
                                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let x = margin + thumbWidth + 12, textWidth = width - thumbWidth - 12
            let colour: NSColor = issue.severity == .problem ? .systemRed : issue.severity == .warning ? .systemOrange : .darkGray
            var head = severityLabel(issue.severity)
            if let time = issue.time { head += "  ·  " + timecode(time, fps: report.fps) }
            if issue.isNew { head += "  ·  " + String(localized: "New") }
            y += text(head, size: 8, weight: .medium, colour: colour, x: x, width: textWidth) + 2
            y += text(issue.title, size: 11, weight: .medium, x: x, width: textWidth) + 2
            y += text(issue.detail, size: 9, colour: .darkGray, x: x, width: textWidth)
            y = max(y, top + thumbHeight) + 14
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
