import Foundation

/// Pacing checks over a project's clips: shots that run long, clips too short to read, and jump
/// cuts (two pieces of the same file joined with a small step, so the picture jumps).
enum Pacing {
    struct Flag: Equatable {
        let index: Int
        let kind: Kind
    }

    enum Kind: Equatable {
        case long, short, jumpCut
    }

    /// The flags for each clip (by index), in clip order. A clip can carry more than one flag.
    static func flags(_ clips: [ProjectClip], frameRate: Double, longAfter: Double, shortUnder: Int) -> [Flag] {
        var flags: [Flag] = []
        let shortest = Double(shortUnder) / max(frameRate, 1)
        for (index, clip) in clips.enumerated() {
            if clip.length > longAfter { flags.append(Flag(index: index, kind: .long)) }
            if clip.length < shortest { flags.append(Flag(index: index, kind: .short)) }
            // Two pieces of one file, joined a short step apart (a small overlap counts too).
            if index > 0 {
                let left = clips[index - 1]
                let gap = clip.start - left.end
                if left.path == clip.path, left.freeze == nil, clip.freeze == nil, gap > -2, gap < 2 {
                    flags.append(Flag(index: index, kind: .jumpCut))
                }
            }
        }
        return flags
    }
}
