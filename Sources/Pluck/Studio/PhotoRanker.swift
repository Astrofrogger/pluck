import Foundation

/// Scores the photos of a moment, so the strongest show on top. Only the order matters, and it is only
/// ever used inside one moment. The built-in ranking needs no training; a trained style comes later.
struct PhotoRanker {
    /// A score for each photo of a moment, in the moment's order (higher is stronger).
    let score: ([String], [String: PhotoCheck]) -> [Double]

    init(score: @escaping ([String], [String: PhotoCheck]) -> [Double]) { self.score = score }

    func scores(_ moment: [String], checks: [String: PhotoCheck]) -> [Double] { score(moment, checks) }

    /// Face quality first, then sharpness within the moment, minus 1 for closed eyes.
    /// With no faces: sharpness within the moment, plus how good the picture looks.
    static let builtIn = PhotoRanker { moment, checks in
        let features = relativeFeatures(moment, checks: checks)
        return moment.indices.map { index in
            let f = features[index], check = checks[moment[index]]
            let sharp = f["rank_sharp"].flatMap { $0 >= 0 ? 1 - $0 : nil } ?? 0
            if (check?.signals?.faceCount ?? 0) > 0, let quality = check?.signals?.faceQuality {
                return 2 * quality + sharp - (closedEyes(check) ? 1 : 0)
            }
            return sharp + (check?.signals?.aesthetics ?? 0)
        }
    }

    private static func closedEyes(_ check: PhotoCheck?) -> Bool {
        if let open = check?.signals?.eyesOpen { return open < 0.16 }
        return check?.eyesClosed ?? false
    }

    /// For each photo of a moment, by the names the style training uses (`analyze.swift`):
    /// `rank_x` (0 = best in the moment, 1 = worst), `diff_x` (best minus mine) and `ratio_x` (mine over best)
    /// for x = sharp, aes and faceQ; `momSize`, `momLogSize`; and `distBest`, the distance to the moment's sharpest photo.
    /// A measure a photo lacks is -1.
    static func relativeFeatures(_ moment: [String], checks: [String: PhotoCheck]) -> [[String: Double]] {
        func sharp(_ check: PhotoCheck?) -> Double? {
            let s = check?.signals
            if let s, s.faceCount > 0, let face = s.faceSharpness { return face }
            return s?.sharpness ?? check?.sharpness
        }
        let measures: [(name: String, value: (PhotoCheck?) -> Double?)] = [
            ("sharp", sharp), ("aes", { $0?.signals?.aesthetics }), ("faceQ", { $0?.signals?.faceQuality }),
        ]
        var rows = [[String: Double]](repeating: ["momSize": Double(moment.count), "momLogSize": log2(Double(max(moment.count, 1)))], count: moment.count)
        for (name, value) in measures {
            let values = moment.map { value(checks[$0]) }
            let known = values.compactMap { $0 }.sorted()
            let best = known.last
            for (index, mine) in values.enumerated() {
                guard let mine, let best else {
                    rows[index]["rank_\(name)"] = -1; rows[index]["diff_\(name)"] = -1; rows[index]["ratio_\(name)"] = -1
                    continue
                }
                // How many of the others are better than this one (a binary search in the sorted values).
                var low = 0, high = known.count
                while low < high { let mid = (low + high) / 2; if known[mid] <= mine { low = mid + 1 } else { high = mid } }
                let better = known.count - low
                rows[index]["rank_\(name)"] = known.count > 1 ? Double(better) / Double(known.count - 1) : 0
                rows[index]["diff_\(name)"] = best - mine
                rows[index]["ratio_\(name)"] = best != 0 ? mine / best : 1
            }
        }
        let sharps = moment.map { sharp(checks[$0]) }
        let bestIndex = sharps.indices.max { (sharps[$0] ?? -.infinity) < (sharps[$1] ?? -.infinity) }
        let bestPrint = bestIndex.flatMap { checks[moment[$0]]?.signals?.print } ?? []
        for index in moment.indices {
            let distance = PhotoSignals.distance(checks[moment[index]]?.signals?.print ?? [], bestPrint)
            rows[index]["distBest"] = index == bestIndex ? 0 : (distance == .greatestFiniteMagnitude ? 9 : Double(distance))
        }
        return rows
    }
}
