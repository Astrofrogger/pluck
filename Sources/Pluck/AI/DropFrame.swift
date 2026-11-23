import Foundation

/// SMPTE timecode as frame counts, drop-frame (29.97 and 59.94 DF: frame numbers 0 and 1, or 0–3,
/// skipped each minute except every tenth) or not. Non-drop counts at the whole base rate (24 for
/// 23.976, 30 for 29.97), which is what editors expect.
enum DropFrame {
    /// The whole-number rate timecode counts in: 24 for 23.976, 30 for 29.97.
    static func base(_ fps: Double) -> Int { max(Int(fps.rounded()), 1) }

    /// Only 29.97 and 59.94 (and their multiples) can drop frames.
    static func canDrop(_ fps: Double) -> Bool {
        let base = base(fps)
        return base % 30 == 0 && abs(fps - Double(base) * 1000 / 1001) < 0.01
    }

    /// "01:00:00;00" (or with a full stop) is drop-frame timecode.
    static func isDrop(_ text: String) -> Bool { text.contains(";") || text.contains(".") }

    private static func skip(_ base: Int) -> Int { base / 15 }

    static func frames(_ text: String, base: Int, drop: Bool) -> Int? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4, parts[3] < base else { return nil }
        let count = ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * base + parts[3]
        guard drop, base % 30 == 0 else { return count }
        let minutes = parts[0] * 60 + parts[1]
        return count - skip(base) * (minutes - minutes / 10)
    }

    static func string(_ frames: Int, base: Int, drop: Bool) -> String {
        var frames = frames
        let drop = drop && base % 30 == 0
        if drop {
            let skip = skip(base), tenMinutes = base * 600 - skip * 9, minute = base * 60 - skip
            let tens = frames / tenMinutes, rest = frames % tenMinutes
            frames += skip * 9 * tens + (rest > skip ? skip * ((rest - skip) / minute) : 0)
        }
        let s = frames / base
        return String(format: "%02d:%02d:%02d", s / 3600 % 24, s / 60 % 60, s % 60) + (drop ? ";" : ":") + String(format: "%02d", frames % base)
    }
}
