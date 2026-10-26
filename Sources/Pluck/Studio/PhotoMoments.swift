import Foundation

/// Groups photos into moments (the same scene, shot close together) and decides which show on top.
/// It only orders and groups: no photo is ever dropped or hidden.
enum PhotoMoments {
    /// Beyond this many seconds a photo always starts a new moment.
    static let maxGap = 90.0
    /// Within this many seconds a photo joins unless the picture is very different.
    static let burstGap = 2.0
    /// How alike a photo must look (its feature print) to join a moment, and within a burst.
    static let joinDistance: Float = 0.45
    static let burstDistance: Float = 0.63
    /// With no feature print, photos this close in time are one moment.
    static let noPrintGap = 1.5
    /// How many of the moment's latest frames a photo is compared with.
    static let recent = 4

    /// The photos in moments, in capture order. Every photo lands in exactly one moment.
    /// A photo with no date is a moment of its own and doesn't split its neighbours.
    static func group(_ photos: [String], checks: [String: PhotoCheck]) -> [[String]] {
        // Dated photos are put in time order, in the places dated photos had.
        let slots = photos.indices.filter { checks[photos[$0]]?.taken != nil }
        let ordered = slots.map { photos[$0] }.enumerated().sorted {
            let a = checks[$0.element]?.taken ?? .distantPast, b = checks[$1.element]?.taken ?? .distantPast
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        var sequence = photos
        for (slot, path) in zip(slots, ordered) { sequence[slot] = path }

        var moments: [(first: Int, paths: [String])] = []
        var current: [String] = []
        var currentFirst = 0
        func close() {
            if !current.isEmpty { moments.append((currentFirst, current)) }
            current = []
        }
        for (position, path) in sequence.enumerated() {
            guard let taken = checks[path]?.taken else {
                moments.append((position, [path]))
                continue
            }
            if let last = current.last, let lastTaken = checks[last]?.taken, !joins(path, taken: taken, last: lastTaken, moment: current, checks: checks) {
                close()
            }
            if current.isEmpty { currentFirst = position }
            current.append(path)
        }
        close()
        return moments.sorted { $0.first < $1.first }.map(\.paths)
    }

    private static func joins(_ path: String, taken: Date, last: Date, moment: [String], checks: [String: PhotoCheck]) -> Bool {
        let gap = taken.timeIntervalSince(last)
        guard gap <= maxGap else { return false }
        if let print = checks[path]?.signals?.print, !print.isEmpty {
            let close = moment.suffix(recent).compactMap { checks[$0]?.signals?.print }.filter { !$0.isEmpty }
                .map { PhotoSignals.distance(print, $0) }.min()
            if let close { return close <= (gap <= burstGap ? burstDistance : joinDistance) }
        }
        return gap <= noPrintGap
    }

    // MARK: - What shows on top

    /// How many of a moment's photos show on top: a quarter, at least one.
    static func onTop(count: Int) -> Int { max(1, Int(ceil(Double(count) * 0.25))) }

    /// A moment split into its strongest quarter and the rest. Both are ordered by score, highest first.
    static func split(_ moment: [String], scores: [Double]) -> (top: [String], rest: [String]) {
        let order = moment.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        let sorted = order.map { moment[$0] }
        let count = min(onTop(count: moment.count), sorted.count)
        return (Array(sorted.prefix(count)), Array(sorted.dropFirst(count)))
    }

    /// What the grid lists: a collapsed moment shows its top photos, the last one carrying how many are stacked
    /// behind them. An expanded moment (keyed by its first photo's path) lists all its photos, best first.
    static func visible(_ moments: [[String]], ranker: PhotoRanker, checks: [String: PhotoCheck], expanded: Set<String>) -> [(path: String, stacked: Int)] {
        visible(moments, expanded: expanded) { split($0, scores: ranker.scores($0, checks: checks)) }
    }

    /// The same, with each moment's split given (the page keeps them, so opening a moment doesn't rank them all again).
    static func visible(_ moments: [[String]], expanded: Set<String>, parts split: ([String]) -> (top: [String], rest: [String])) -> [(path: String, stacked: Int)] {
        var shown: [(path: String, stacked: Int)] = []
        for moment in moments {
            guard let key = moment.first else { continue }
            let parts = split(moment)
            if expanded.contains(key) {
                shown += (parts.top + parts.rest).map { ($0, 0) }
            } else {
                shown += parts.top.map { ($0, 0) }
                if !parts.rest.isEmpty, !shown.isEmpty { shown[shown.count - 1].stacked = parts.rest.count }
            }
        }
        return shown
    }
}

// MARK: - What the Photo page lists

extension PhotoMoments {
    /// The photos the grid, filmstrip and arrow keys go through, and what each stack shows.
    struct Listing {
        /// The listed photos, in order.
        var paths: [String] = []
        /// A closed stack's last top photo: how many photos sit behind it.
        var stacked: [String: Int] = [:]
        /// An open moment's last photo: how many photos the moment has, to close it by.
        var opened: [String: Int] = [:]
        /// Every listed photo's moment (keyed by its first photo), for the moments of two or more photos.
        var moment: [String: String] = [:]
        /// Every photo of each moment of two or more, by moment key.
        var members: [String: [String]] = [:]
    }

    /// The list for the page: `photos` (already filtered) in moments, each showing its top photos, and the open ones in full.
    /// Photos with no check yet are in moments of their own, so none is ever left out.
    static func listing(_ photos: [String], ranker: PhotoRanker, checks: [String: PhotoCheck], expanded: Set<String>) -> Listing {
        listing(group(photos, checks: checks), ranker: ranker, checks: checks, expanded: expanded)
    }

    static func listing(_ moments: [[String]], ranker: PhotoRanker, checks: [String: PhotoCheck], expanded: Set<String>) -> Listing {
        listing(moments, expanded: expanded) { split($0, scores: ranker.scores($0, checks: checks)) }
    }

    static func listing(_ moments: [[String]], expanded: Set<String>, parts: ([String]) -> (top: [String], rest: [String])) -> Listing {
        let shown = visible(moments, expanded: expanded, parts: parts)
        var result = Listing(paths: shown.map(\.path))
        for item in shown where item.stacked > 0 { result.stacked[item.path] = item.stacked }
        for moment in moments {
            guard let key = moment.first, moment.count > 1 else { continue }
            result.members[key] = moment
            for path in moment { result.moment[path] = key }
        }
        // An open moment's photos are listed together, so its last listed photo carries the close badge.
        for key in expanded {
            guard let moment = result.members[key] else { continue }
            let own = Set(moment)
            if let last = result.paths.last(where: { own.contains($0) }) { result.opened[last] = moment.count }
        }
        return result
    }
}

/// Remembers the page's list between redraws, so 3,000 photos aren't grouped and ranked again for nothing.
/// The moments are redone only when the photos or their checks change, and each moment is ranked again only
/// when its photos or the ranking change (a style's model is slow on the main thread); opening or closing a
/// moment only rebuilds the list.
@MainActor
final class MomentsCache {
    private var photos: [String] = []
    private var checkCount = -1
    private var groups: [[String]] = []
    /// The chosen style and when it was trained (a style trained again has a new model).
    private var style: UUID?
    private var styleTrained: Date?
    private var styleKnown = false
    private var ranker = PhotoRanker.builtIn
    /// Each moment's top and rest, by its photos.
    private var splits: [[String]: (top: [String], rest: [String])] = [:]
    private var expanded: Set<String> = []
    private var listing: PhotoMoments.Listing?

    /// `open` holds photos of the moments opened (their first photo when opened): a moment stays open when
    /// new checks regroup it and its first photo changes.
    func listing(_ list: [String], checks: [String: PhotoCheck], style chosen: PhotoStyle?, expanded open: Set<String>) -> PhotoMoments.Listing {
        var changed = false
        if !styleKnown || style != chosen?.id || styleTrained != chosen?.trained {
            style = chosen?.id
            styleTrained = chosen?.trained
            styleKnown = true
            ranker = chosen.map { PhotoRanker(style: $0) } ?? .builtIn
            splits = [:]
            changed = true
        }
        if list != photos || checks.count != checkCount {
            photos = list
            checkCount = checks.count
            groups = PhotoMoments.group(list, checks: checks)
            changed = true
        }
        if let listing, !changed, open == expanded { return listing }
        expanded = open
        var kept: [[String]: (top: [String], rest: [String])] = [:]
        for moment in groups {
            kept[moment] = splits[moment] ?? PhotoMoments.split(moment, scores: ranker.scores(moment, checks: checks))
        }
        splits = kept
        let opened = open.isEmpty ? [] : Set(groups.compactMap { moment in moment.count > 1 && moment.contains(where: open.contains) ? moment.first : nil })
        let made = PhotoMoments.listing(groups, expanded: opened) { kept[$0] ?? (top: $0, rest: []) }
        listing = made
        return made
    }
}
