import Foundation
import FoundationModels

/// Looks at a whole shoot at once, the way an editor goes through the rushes: shots grouped by
/// what they show (the build, the crew, details, the result…), the best of each group picked with
/// different shot sizes, shots with a look of their own given a chance whatever their score, and
/// a word on what story the footage tells and what it's short of.
enum ShootPlan {
    /// What the footage is for, which changes what counts.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case corporate, commercial, aftermovie, music, brand
        var id: String { rawValue }

        var label: String {
            switch self {
            case .corporate: String(localized: "Corporate")
            case .commercial: String(localized: "Commercial")
            case .aftermovie: String(localized: "Aftermovie")
            case .music: String(localized: "Music video")
            case .brand: String(localized: "Brand video")
            }
        }

        var weights: VisualIndex.Weights {
            var w = VisualIndex.Weights()
            switch self {
            case .corporate:
                w.faces = 0.25; w.activity = 0.2; w.action = 0.2; w.smiling = 0.2; w.look = 0.1; w.aesthetics = 0.2
            case .commercial:
                w.look = 0.3; w.aesthetics = 0.45; w.closeUp = 0.15; w.faces = 0.1; w.smiling = 0.1; w.action = 0.1; w.strict = true
            case .aftermovie:
                w.smiling = 0.35; w.action = 0.35; w.faces = 0.2; w.cameraMove = 0.15; w.aerial = 0.15; w.look = 0.1
            case .music:
                w.look = 0.3; w.aesthetics = 0.35; w.action = 0.3; w.cameraMove = 0.15; w.faces = 0.2; w.closeUp = 0.1
            case .brand:
                w.look = 0.25; w.aesthetics = 0.35; w.faces = 0.2; w.smiling = 0.25; w.activity = 0.15
            }
            return w
        }

        /// For the local AI: what an editor of this kind of video looks for.
        var brief: String {
            switch self {
            case .corporate: "a corporate video: the people, the work and craft, the workplace, the product or result, the team, interview moments"
            case .commercial: "a commercial: hero shots of the product, details, clean and beautiful compositions, a strong opening and ending image"
            case .aftermovie: "an event aftermovie: energy, the crowd, smiles and reactions, the venue and its scale, peak moments, an arrival and a goodbye"
            case .music: "a music video: the artist and performance, close-ups, movement and rhythm, a strong visual style, variety of looks"
            case .brand: "a brand video: emotion and values, people, beautiful images, details that say who the brand is, a story arc"
            }
        }
    }

    struct Pick: Hashable, Sendable {
        var path: String
        var shot: VisualIndex.Shot
        var topic: String
    }

    struct Topic: Identifiable, Sendable {
        var name: String
        var shots: [(path: String, shot: VisualIndex.Shot)]
        var id: String { name + "\(shots.first?.shot.start ?? 0)" }
    }

    struct Plan: Sendable {
        var topics: [Topic]
        var picks: [Pick]
        /// The story the footage can tell, and what's missing (local AI; nil where it isn't available).
        var overview: Overview?
    }

    struct Overview: Sendable {
        var story: [String]
        var missing: [String]
    }

    static func plan(_ indexes: [VisualIndex.FileIndex], kind: Kind = .corporate) async -> Plan {
        // Scored for this kind of video.
        let weights = kind.weights
        let shots = indexes.flatMap { index in index.shots.map { shot -> (path: String, shot: VisualIndex.Shot) in
            var shot = shot
            let result = VisualIndex.score(shot, weights: weights)
            shot.quality?.score = result.score
            shot.quality?.problems = result.problems
            return (index.path, shot)
        } }
        guard !shots.isEmpty else { return Plan(topics: [], picks: [], overview: nil) }
        let topics = group(shots)
        var picks: [Pick] = []
        func isPicked(_ path: String, _ start: Double) -> Bool { picks.contains { $0.path == path && $0.shot.start == start } }
        for topic in topics {
            // A one-off shot only if it's really good; bigger groups get more picks.
            if topic.shots.count == 1 {
                if let only = topic.shots.first, (only.shot.quality?.score ?? 0) >= 0.6 { picks.append(Pick(path: only.path, shot: only.shot, topic: topic.name)) }
                continue
            }
            let quota = max(1, min(4, Int(Double(topic.shots.count).squareRoot().rounded())))
            var chosen: [(path: String, shot: VisualIndex.Shot)] = []
            let ranked = topic.shots.filter { !($0.shot.quality?.problems.contains(.soft) ?? false) || !($0.shot.quality?.look.isEmpty ?? true) }
                .sorted { ($0.shot.quality?.score ?? 0) > ($1.shot.quality?.score ?? 0) }
            func taken(_ c: (path: String, shot: VisualIndex.Shot)) -> Bool {
                chosen.contains { $0.path == c.path && $0.shot.start == c.shot.start }
            }
            for candidate in ranked where chosen.count < quota {
                let score = candidate.shot.quality?.score ?? 0
                guard score >= 0.3 else { break }
                if taken(candidate) { continue }
                // Not the next piece of a shot already chosen.
                if chosen.contains(where: { $0.path == candidate.path
                    && (abs($0.shot.end - candidate.shot.start) < 0.5 || abs($0.shot.start - candidate.shot.end) < 0.5) }) { continue }
                // Different shot sizes before more of the same, as long as the score is close.
                if chosen.contains(where: { $0.shot.framing == candidate.shot.framing }),
                   let other = ranked.first(where: { c in !chosen.contains(where: { $0.shot.framing == c.shot.framing }) && !taken(c) }),
                   (other.shot.quality?.score ?? 0) > score - 0.15 {
                    chosen.append(other)
                    continue
                }
                chosen.append(candidate)
            }
            picks += chosen.map { Pick(path: $0.path, shot: $0.shot, topic: topic.name) }
        }
        // Shots with a look of their own: a videographer shot them for a reason.
        let striking = shots.filter { item in
            guard let q = item.shot.quality, !q.look.isEmpty, q.score >= 0.45 else { return false }
            return !isPicked(item.path, item.shot.start)
        }.sorted { ($0.shot.quality?.score ?? 0) > ($1.shot.quality?.score ?? 0) }
        for item in striking.prefix(max(2, picks.count / 5)) {
            let topic = topics.first { $0.shots.contains { $0.path == item.path && $0.shot.start == item.shot.start } }?.name ?? ""
            picks.append(Pick(path: item.path, shot: item.shot, topic: topic))
        }
        // A selects reel, not half the shoot: about a quarter of the shots, keeping the best of
        // each group first and then the highest scores.
        let budget = max(6, Int((Double(shots.count) * 0.25).rounded()))
        if picks.count > budget {
            var kept: [Pick] = []
            for topic in topics {
                if let best = picks.filter({ $0.topic == topic.name }).max(by: { ($0.shot.quality?.score ?? 0) < ($1.shot.quality?.score ?? 0) }),
                   topic.shots.count > 1 {
                    kept.append(best)
                }
            }
            kept = Array(kept.sorted { ($0.shot.quality?.score ?? 0) > ($1.shot.quality?.score ?? 0) }.prefix(budget))
            for pick in picks.sorted(by: { ($0.shot.quality?.score ?? 0) > ($1.shot.quality?.score ?? 0) }) where kept.count < budget {
                if !kept.contains(where: { $0.path == pick.path && $0.shot.start == pick.shot.start }) { kept.append(pick) }
            }
            picks = kept
        }
        // In the order they were filmed.
        picks.sort { ($0.path, $0.shot.start) < ($1.path, $1.shot.start) }
        let overview = await describe(topics, picks: picks, kind: kind)
        return Plan(topics: topics, picks: picks, overview: overview)
    }

    /// Groups shots that show the same thing: each joins the group whose description it's
    /// closest to in meaning, or starts a new one.
    private static func group(_ shots: [(path: String, shot: VisualIndex.Shot)]) -> [Topic] {
        // How alike shots must be depends on the shoot (everything in one venue is alike): just
        // above how alike its shots typically are.
        let vectors = shots.compactMap { $0.shot.embedding?.map(Double.init) }
        let sample = stride(from: 0, to: vectors.count, by: max(1, vectors.count / 200)).map { vectors[$0] }
        var similarities: [Double] = []
        for i in sample.indices { for j in sample.indices where j > i { similarities.append(cosine(sample[i], sample[j])) } }
        similarities.sort()
        let threshold = similarities.isEmpty ? 0.85 : min(0.93, max(0.82, similarities[similarities.count * 9 / 10] + 0.02))
        var groups: [(centre: [Double], members: [(path: String, shot: VisualIndex.Shot)])] = []
        for item in shots {
            guard let vector = item.shot.embedding?.map(Double.init), !vector.isEmpty else {
                groups.append((centre: [], members: [item]))
                continue
            }
            var best = -1, bestSimilarity = 0.0
            for (index, group) in groups.enumerated() where group.centre.count == vector.count {
                let similarity = cosine(group.centre, vector)
                if similarity > bestSimilarity { bestSimilarity = similarity; best = index }
            }
            if best >= 0, bestSimilarity > threshold {
                let count = Double(groups[best].members.count)
                groups[best].centre = zip(groups[best].centre, vector).map { ($0 * count + $1) / (count + 1) }
                groups[best].members.append(item)
            } else {
                groups.append((centre: vector, members: [item]))
            }
        }
        return groups.map { group in Topic(name: name(group.members.map(\.shot)), shots: group.members) }
            .sorted { ($0.shots.first?.path ?? "", $0.shots.first?.shot.start ?? 0) < ($1.shots.first?.path ?? "", $1.shots.first?.shot.start ?? 0) }
    }

    /// The group's most common keywords.
    private static func name(_ shots: [VisualIndex.Shot]) -> String {
        var counts: [String: Int] = [:]
        for shot in shots { for keyword in Set(shot.keywords) { counts[keyword, default: 0] += 1 } }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
        return top.isEmpty ? String(localized: "Other shots") : top.joined(separator: ", ")
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// The story and what's missing, from the local AI, in the Mac's language.
    private static func describe(_ topics: [Topic], picks: [Pick], kind: Kind) async -> Overview? {
        guard #available(macOS 26, *), LocalAI.canSummarize, !topics.isEmpty else { return nil }
        let all = topics.flatMap { $0.shots.map(\.shot) }
        func count(_ framing: VisualIndex.Framing) -> Int { all.filter { $0.framing == framing }.count }
        var summary = "Footage: \(all.count) shots — \(count(.wide)) wide, \(count(.medium)) medium, \(count(.closeUp)) close-up, \(count(.aerial)) aerial; "
        summary += "\(all.filter { $0.quality?.smiling == true }.count) with smiling people.\n"
        for topic in topics.prefix(40) {
            let best = topic.shots.max { ($0.shot.quality?.score ?? 0) < ($1.shot.quality?.score ?? 0) }?.shot
            let activities = Set(topic.shots.compactMap { $0.shot.quality?.activity }.filter { !$0.isEmpty }).prefix(3)
            let feelings = Set(topic.shots.compactMap { $0.shot.quality?.emotion }.filter { !$0.isEmpty }).prefix(3)
            let sizes = Dictionary(grouping: topic.shots.map(\.shot.framing), by: { $0 }).map { "\($0.value.count) \($0.key.rawValue)" }.joined(separator: ", ")
            let smiles = topic.shots.filter { $0.shot.quality?.smiling == true }.count
            summary += "- \(topic.name): \(topic.shots.count) shots (\(sizes)\(smiles > 0 ? ", \(smiles) with smiling people" : "")). Example: \(best?.description ?? "")"
            if !activities.isEmpty { summary += " Happening: \(activities.joined(separator: "; "))." }
            if !feelings.isEmpty { summary += " Feeling: \(feelings.joined(separator: ", "))." }
            summary += "\n"
        }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
        let session = LanguageModelSession(instructions: """
            You are an experienced video editor looking through all the footage of a shoot for \(kind.brief). \
            From the summary of the footage, answer in exactly this format and nothing else:
            STORY
            - (3 to 5 points: the story this footage can tell, in a sensible order)
            MISSING
            - (up to 4 shots that are missing or thin for this kind of video and would make the edit stronger)
            Keep the words STORY and MISSING as they are. Write each point in \(language), plain text, at most 15 words. \
            Only use shots that are in the summary: don't mention aerial shots, smiles or anything else it doesn't list.
            """)
        guard let text = try? await session.respond(to: summary).content else { return nil }
        let overview = parse(text)
        return overview.story.isEmpty && overview.missing.isEmpty ? nil : overview
    }

    /// Reads the STORY / MISSING answer (tolerant of markdown, numbering and stray labels).
    static func parse(_ text: String) -> Overview {
        var overview = Overview(story: [], missing: [])
        var inMissing = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            let heading = line.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if heading.hasPrefix("STORY") && heading.count < 12 { inMissing = false; continue }
            if heading.hasPrefix("MISSING") && heading.count < 14 { inMissing = true; continue }
            // "- point", "• point", "1. point", "1) point"
            if let bullet = line.range(of: #"^([-•–]|\d{1,2}[.)])\s*"#, options: .regularExpression) {
                line.removeSubrange(bullet)
            }
            guard line.count > 3 else { continue }
            if inMissing { if overview.missing.count < 4 { overview.missing.append(line) } }
            else if overview.story.count < 5 { overview.story.append(line) }
        }
        return overview
    }
}
