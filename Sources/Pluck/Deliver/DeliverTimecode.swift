import Foundation

/// Timecode on screen (§2): the start timecode plus a frame, non-drop for whole rates and SMPTE drop-frame
/// when the clip says so (2 frames a minute at 29.97, 4 at 59.94, except every 10th minute).
enum DeliverTimecode {
    static func rate(_ fpsNum: Int, _ fpsDen: Int) -> Int { max(1, Int((Double(fpsNum) / Double(max(fpsDen, 1))).rounded())) }
    static func dropped(_ rate: Int) -> Int { rate == 30 ? 2 : rate == 60 ? 4 : 0 }

    /// The frame count a timecode stands for ("01:00:00:00", or with ";" for drop frame).
    static func frames(_ timecode: String, fpsNum: Int, fpsDen: Int, drop: Bool) -> Int {
        let parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4 else { return 0 }
        let rate = rate(fpsNum, fpsDen), minutes = parts[0] * 60 + parts[1]
        let nominal = ((parts[0] * 3600 + parts[1] * 60 + parts[2]) * rate) + parts[3]
        return drop ? nominal - dropped(rate) * (minutes - minutes / 10) : nominal
    }

    static func string(frame: Int, start: String = "00:00:00:00", fpsNum: Int, fpsDen: Int, drop: Bool) -> String {
        let rate = rate(fpsNum, fpsDen), skip = drop ? dropped(rate) : 0
        let day = skip > 0 ? (rate * 600 - skip * 9) * 144 : rate * 86400
        var n = (frames(start, fpsNum: fpsNum, fpsDen: fpsDen, drop: drop) + max(frame, 0)) % day
        if skip > 0 {
            let tenMinutes = rate * 600 - skip * 9, minute = rate * 60 - skip
            let blocks = n / tenMinutes, rest = n % tenMinutes
            n += skip * 9 * blocks + (rest > skip ? skip * ((rest - skip) / minute) : 0)
        }
        let separator = skip > 0 ? ";" : ":"
        return String(format: "%02d:%02d:%02d", n / (3600 * rate), n / (60 * rate) % 60, n / rate % 60) + separator + String(format: "%02d", n % rate)
    }
}

extension DeliverTimecode {
    /// A length as "2:30" (or "1:02:30").
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}
