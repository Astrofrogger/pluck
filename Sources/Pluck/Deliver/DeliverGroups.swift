import Foundation

/// Deliverable groups (wf-deliver): a master and its variants (cutdowns, 16:9/9:16/1:1, languages) as one card, each
/// variant still its own asset with its versions and approval. The group is a name on each asset; suggested from names.
extension Deliver {
    /// Name endings that make a variant: frame shapes and lengths (by pattern), cut words, and language codes (in capitals).
    static let variantWords: Set<String> = ["cutdown", "cutdowns", "social", "vertical", "square", "horizontal", "landscape", "portrait",
                                            "subs", "subtitled", "nosubs", "textless"]
    static let languageCodes: Set<String> = ["EN", "NL", "FR", "DE", "ES", "IT", "PT", "JA", "JP", "KO", "ZH", "CN", "DA", "SV", "NO", "FI", "PL"]

    /// "Hero_9x16" → "Hero", "Spot 15s NL" → "Spot"; nil when the name has no variant ending.
    nonisolated static func variantBase(_ name: String) -> String? {
        var base = (name as NSString).deletingPathExtension
        var stripped = false
        while let range = base.range(of: #"[ _\-.]+([A-Za-z0-9]+)$"#, options: .regularExpression) {
            let raw = base[range].trimmingCharacters(in: CharacterSet(charactersIn: " _-.")), word = raw.lowercased()
            let isShape = word.range(of: #"^\d{1,2}x\d{1,2}$"#, options: .regularExpression) != nil
            let isLength = word.range(of: #"^\d{1,3}s(ec)?$"#, options: .regularExpression) != nil
            guard isShape || isLength || variantWords.contains(word) || languageCodes.contains(raw) else { break }
            base.removeSubrange(range)
            stripped = true
        }
        base = base.trimmingCharacters(in: .whitespaces)
        return stripped && !base.isEmpty ? base : nil
    }

    /// Suggested groups for assets without one: those sharing a base name (two or more, the master itself counting).
    nonisolated static func suggestedGroups(_ assets: [Asset]) -> [UUID: String] {
        let loose = assets.filter { $0.group == nil }
        let bases = Dictionary(grouping: loose) { (variantBase($0.name) ?? ($0.name as NSString).deletingPathExtension).lowercased() }
        var out: [UUID: String] = [:]
        for members in bases.values where members.count > 1 {
            // The group is called as its master is (the one without an ending), else as the first variant's base.
            let name = members.first { variantBase($0.name) == nil }.map { ($0.name as NSString).deletingPathExtension } ?? variantBase(members[0].name) ?? members[0].name
            for member in members { out[member.id] = name }
        }
        return out
    }
}

extension DeliverStore {
    /// Puts assets in a group (nil or empty: out of it). Groups show on every link of the project.
    func setGroup(_ group: String?, of ids: [UUID]) {
        let name = group.map { Deliver.clean($0, limit: Self.nameLimit) }.flatMap { $0.isEmpty ? nil : $0 }
        for id in ids where find(id)?.asset.group != name {
            update(asset: id) { $0.group = name }
            tell(.assetChanged(id))
        }
    }
}
