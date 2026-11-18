import Foundation

/// §13.0's merge rules, shared by every sync path: M picks a copy by `(rev, at, by)`, highest first (a full tie:
/// a tombstone beats an object), and MC merges a comment's replies on top of M's winner.
protocol DeliverRevised {
    var rev: Int? { get set }
    var at: Date? { get set }
    var by: String? { get set }
}

extension Deliver.Project: DeliverRevised {}
extension Deliver.Folder: DeliverRevised {}
extension Deliver.Asset: DeliverRevised {}
extension Deliver.ShareLink: DeliverRevised {}
extension Deliver.Comment: DeliverRevised {}

enum DeliverMerge {
    /// A copy's place under rule M (an object without a rev is rev 0, from before syncing).
    struct Stamp: Comparable {
        var rev: Int, at: Date, by: String
        static func < (a: Stamp, b: Stamp) -> Bool { (a.rev, a.at, a.by) < (b.rev, b.at, b.by) }
        init(rev: Int, at: Date, by: String) { self.rev = rev; self.at = at; self.by = by }
        init(_ object: some DeliverRevised) { self.init(rev: object.rev ?? 0, at: object.at ?? .distantPast, by: object.by ?? "") }
        init(_ tombstone: Deliver.Tombstone) { self.init(rev: tombstone.rev, at: tombstone.at, by: tombstone.by) }
        /// Dates compare in whole seconds, as they're written.
        var rounded: Stamp { Stamp(rev: rev, at: Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded()), by: by) }
    }

    /// Rule M: whether the incoming copy replaces the stored one (nil stored: it's new, so yes).
    static func incomingWins(stored: Stamp?, storedTombstone: Bool = false, incoming: Stamp, incomingTombstone: Bool = false) -> Bool {
        guard let stored = stored?.rounded else { return true }
        let incoming = incoming.rounded
        if incoming == stored { return incomingTombstone && !storedTombstone }
        return incoming > stored
    }

    /// Rule MC: M's winner as the base; replies = both sides' union by id, minus both sides' deleted replies.
    static func comment(stored: Deliver.Comment, incoming: Deliver.Comment) -> Deliver.Comment {
        // (A full tie is the same revision: the incoming copy, which is what a host from before revisions sends changed.)
        var base = Stamp(incoming).rounded >= Stamp(stored).rounded ? incoming : stored
        let deleted = Set((stored.deletedReplies ?? []) + (incoming.deletedReplies ?? []))
        var seen = Set<UUID>(), replies: [Deliver.Comment.Reply] = []
        // Internal stays internal: a copy that lost the flag (an older Pluck) never makes a team-only reply public.
        let hidden = Set((stored.replies + incoming.replies).filter(\.isInternal).map(\.id))
        for var reply in base.replies + stored.replies + incoming.replies where !deleted.contains(reply.id) && seen.insert(reply.id).inserted {
            if hidden.contains(reply.id) { reply.internal = true }
            replies.append(reply)
        }
        base.replies = replies.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        base.deletedReplies = deleted.isEmpty ? nil : deleted.sorted { $0.uuidString < $1.uuidString }
        return base
    }

    /// A comment tombstone (a "deleted" entry with its rev) beats every comment with `rev ≤` its own.
    static func tombstoneBeats(_ tombstoneRev: Int, _ comment: Deliver.Comment) -> Bool { (comment.rev ?? 0) <= tombstoneRev }

    /// This Mac's id in `by` (made once).
    @MainActor static var device: String {
        let key = "reviewDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// The next revision of a changed object: `max(seen) + 1`, now, by this Mac.
    @MainActor static func bump<T: DeliverRevised>(_ object: inout T, by: String? = nil) {
        object.rev = (object.rev ?? 0) + 1
        object.at = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded())
        object.by = by ?? device
    }
}
