import Foundation

/// A part of a video to download, in seconds. `end == nil` means until the end.
struct ClipRange: Codable, Equatable {
    var start: Double
    var end: Double?

    /// "0:05–1:30" or "0:05–end".
    var label: String {
        "\(Format.duration(start))–\(end.map(Format.duration) ?? "end")"
    }

    /// yt-dlp's --download-sections value, e.g. "*5-90".
    var sectionArgument: String {
        "*\(Self.seconds(start))-\(end.map(Self.seconds) ?? "inf")"
    }

    /// Appended to the file name so a clip never replaces the full download. Colons aren't
    /// used because Finder shows them as slashes.
    var fileSuffix: String {
        " (clip \(label.replacingOccurrences(of: ":", with: ".")))"
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// Parses "90", "1:30", "1:02:03" (and decimals like "1:30.5"). Empty means nil.
    static func parseTime(_ text: String) -> Double?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .some(nil) }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds after the first field must stay below 60.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return .some(total)
    }

    /// Builds a clip from the two fields, or nil when they don't make a valid range.
    static func from(start: String, end: String) -> ClipRange? {
        guard let parsedStart = parseTime(start), let parsedEnd = parseTime(end) else { return nil }
        let s = parsedStart ?? 0
        if let e = parsedEnd, e <= s { return nil }
        if parsedStart == nil, parsedEnd == nil { return nil }
        return ClipRange(start: s, end: parsedEnd)
    }
}
