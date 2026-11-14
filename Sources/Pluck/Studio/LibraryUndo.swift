import AppKit
import SwiftUI

// Undo and redo for the Library's file actions, and what to do when a name is taken where
// files go. Every action is a list of steps that can each be turned back: a move (a rename, a
// file put back from the Trash) or a move to the Trash. Nothing is ever deleted for good.

/// One change to a file that can be turned back.
enum FileStep: Equatable {
    /// Moved or renamed on the same drive (out of the Trash too).
    case move(URL, URL)
    /// To the Trash (where it went is the way back).
    case trash(URL)
    /// Only the Library's entries move (the file has already, or will next).
    case relocate(String, String)
}

/// The Library's undo history for files (⌘Z, ⇧⌘Z while the Library is in front).
@MainActor
@Observable
final class FileUndo {
    static let shared = FileUndo()

    struct Action {
        let name: String
        /// Done in order, they turn the action back.
        let steps: [FileStep]
    }

    private(set) var undoStack: [Action] = []
    private(set) var redoStack: [Action] = []
    /// Library entries of files now in the Trash (by their path there): back with them.
    @ObservationIgnored private var parked: [LibraryStore.Entry] = []
    /// What a Replace sent to the Trash for a checked copy still under way (by the copy's path):
    /// part of that copy's undo once it's done.
    @ObservationIgnored var pendingReplaced: [String: [FileStep]] = [:]
    /// Steps recorded while a group is open (one undo for all of them).
    @ObservationIgnored private var collecting: [FileStep]?
    private static let kept = 100

    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// An action done: `steps` turn it back.
    func record(_ name: String, undo steps: [FileStep]) {
        guard !steps.isEmpty else { return }
        // (In a group: later steps are turned back first.)
        if collecting != nil { collecting!.insert(contentsOf: steps, at: 0); return }
        undoStack.append(Action(name: name, steps: steps))
        if undoStack.count > Self.kept { undoStack.removeFirst() }
        redoStack = []
        // (Pluck's own changes don't wake the folder watchers.)
        reloadPanes()
    }

    /// Everything recorded inside is one undo, named `name`.
    func grouped(_ name: String, _ body: () -> Void) {
        let outer = collecting == nil
        if outer { collecting = [] }
        body()
        if outer, let steps = collecting {
            collecting = nil
            record(name, undo: steps)
        }
    }

    /// The steps done, and recorded as one undo; what turns them back.
    @discardableResult
    func perform(_ name: String, _ steps: [FileStep]) throws -> [FileStep] {
        let back = try run(steps)
        record(name, undo: back)
        return back
    }

    /// The last action turned back; nil, or why it couldn't be.
    @discardableResult
    func undo() -> String? {
        guard let action = undoStack.popLast() else { return nil }
        do {
            redoStack.append(Action(name: action.name, steps: try run(action.steps)))
            reloadPanes()
            return nil
        } catch {
            // (Kept, with its files' entries, to try again once what stood in the way is gone.)
            undoStack.append(action)
            reloadPanes()
            return String(localized: "“\(action.name)” can’t be undone: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func redo() -> String? {
        guard let action = redoStack.popLast() else { return nil }
        do {
            undoStack.append(Action(name: action.name, steps: try run(action.steps)))
            reloadPanes()
            return nil
        } catch {
            redoStack.append(action)
            reloadPanes()
            return String(localized: "“\(action.name)” can’t be redone: \(error.localizedDescription)")
        }
    }

    /// ⌘Z or ⇧⌘Z: typing in a field undoes the typing instead.
    static func key(redo: Bool) -> String? {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
            return nil
        }
        return redo ? shared.redo() : shared.undo()
    }

    /// Steps done in order; what turns them back (last first). One failing: those done are turned back.
    func run(_ steps: [FileStep]) throws -> [FileStep] {
        var back: [FileStep] = []
        do {
            for step in steps { back.insert(try apply(step), at: 0) }
        } catch {
            for step in back { _ = try? apply(step) }
            throw error
        }
        return back
    }

    private func apply(_ step: FileStep) throws -> FileStep {
        let fm = FileManager.default
        switch step {
        case .move(let from, let to):
            // (Only the case changed: the same file on most Mac drives.)
            if fm.fileExists(atPath: to.path), from.path.lowercased() != to.path.lowercased() {
                throw FileProblem(String(localized: "\(to.lastPathComponent) is already in \(to.deletingLastPathComponent().lastPathComponent)."))
            }
            // (Never across drives: that's a copy, and checked; undo only ever renames. A drive
            // that doesn't say which it is gets the benefit of the doubt.)
            let key = URLResourceKey.volumeIdentifierKey
            let here = (try? from.resourceValues(forKeys: [key]))?.volumeIdentifier as AnyObject?
            let there = (try? to.deletingLastPathComponent().resourceValues(forKeys: [key]))?.volumeIdentifier as AnyObject?
            if let here, let there, !here.isEqual(there) {
                throw FileProblem(String(localized: "\(to.deletingLastPathComponent().lastPathComponent) is on another drive."))
            }
            try fm.moveItem(at: from, to: to)
            follow(from.path, to.path)
            FinderThumbnails.shared.refresh(from)
            return .move(to, from)
        case .trash(let url):
            var place: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &place)
            guard let place = place as URL? else { throw FileProblem(String(localized: "\(url.lastPathComponent) couldn’t go to the Trash.")) }
            follow(url.path, place.path)
            return .move(place, url)
        case .relocate(let from, let to):
            follow(from, to)
            return .relocate(to, from)
        }
    }

    nonisolated static func inTrash(_ path: String) -> Bool { path.contains("/.Trash/") || path.contains("/.Trashes/") }

    /// The Library's entries for a file (or what's in a folder) go where it went: kept aside
    /// while it's in the Trash, back when it's put back.
    private func follow(_ old: String, _ new: String) {
        let library = LibraryStore.shared
        let fromTrash = Self.inTrash(old), toTrash = Self.inTrash(new)
        if !fromTrash, !toTrash { library.relocate(from: old, to: new); return }
        func under(_ path: String) -> Bool { path == old || path.hasPrefix(old + "/") }
        let leaving = fromTrash ? parked.filter { under($0.path) } : library.entries.filter { under($0.path) }
        guard !leaving.isEmpty else { return }
        if fromTrash { parked.removeAll { under($0.path) } } else { library.remove(leaving) }
        let arriving = leaving.map { entry in
            var entry = entry
            entry.path = new + entry.path.dropFirst(old.count)
            return entry
        }
        if toTrash {
            parked += arriving
            // (Only as many as the undo history could still bring back.)
            if parked.count > 5000 { parked.removeFirst(parked.count - 5000) }
        } else { arriving.forEach(library.insert) }
    }

    private func reloadPanes() {
        for pane in FinderWorkspace.shared.panes { pane.reload() }
    }

    // MARK: Checked copies

    /// A checked copy in the Library is done (moved: `trashed`, each original's place in the
    /// Trash): the Library's entries follow a move, and it's one undo.
    func copyFinished(_ job: OffloadJob, trashed: [String: URL]) {
        guard let root = job.roots.first else { return }
        let pairs: [(from: String, to: String)] = job.name.isEmpty
            ? job.files.map { ((job.source as NSString).appendingPathComponent($0.path), (root as NSString).appendingPathComponent(job.destination(of: $0.path))) }
            : [(job.source, (root as NSString).appendingPathComponent(job.name))]
        var steps: [FileStep] = []
        for pair in pairs where FileManager.default.fileExists(atPath: pair.to) {
            let copy = URL(fileURLWithPath: pair.to), original = URL(fileURLWithPath: pair.from)
            // (A duplicate beside its original is in the Library too.)
            if trashed.isEmpty, copy.deletingLastPathComponent().path == original.deletingLastPathComponent().path { FinderFiles.addLibraryCopy(of: original, at: copy) }
            if let place = trashed[pair.from] {
                LibraryStore.shared.relocate(from: pair.from, to: pair.to)
                steps += [.move(place, original), .relocate(pair.to, pair.from), .trash(copy)]
            } else {
                steps.append(.trash(copy))
            }
            // (What Replace sent to the Trash comes back once the copy has gone there.)
            steps += pendingReplaced.removeValue(forKey: pair.to) ?? []
        }
        record(trashed.isEmpty ? String(localized: "Copy") : String(localized: "Move"), undo: steps)
    }

    /// A checked copy stopped for good: what Replace sent to the Trash can still be put back.
    func copyCancelled(_ job: OffloadJob) {
        record(String(localized: "Replace"), undo: Self.destinations(job).flatMap { pendingReplaced.removeValue(forKey: $0) ?? [] })
    }

    /// A checked copy asked for (`keys`: where its files go): what Replace sent to the Trash for
    /// those no copy started for (a problem, no room) is its own undo, so it can be put back.
    func copyStarted(_ keys: [String]) {
        let running = Set(OffloadCenter.shared.jobs.filter { $0.finished == nil }.flatMap(Self.destinations))
        record(String(localized: "Replace"), undo: keys.filter { !running.contains($0) }.flatMap { pendingReplaced.removeValue(forKey: $0) ?? [] })
    }

    private static func destinations(_ job: OffloadJob) -> [String] {
        guard let root = job.roots.first else { return [] }
        return job.name.isEmpty ? job.files.map { (root as NSString).appendingPathComponent(job.destination(of: $0.path)) }
            : [(root as NSString).appendingPathComponent(job.name)]
    }
}

// MARK: - A name taken where files go

/// Copying or moving into a folder that already has that name: Keep Both ("name 2"), Replace
/// (the one there goes to the Trash), or Skip; Apply to All answers the rest.
@MainActor
enum FileClash {
    enum Choice { case keepBoth, replace, skip }

    /// Asks about one name (`more`: others are still to come); the choice, and whether it's for all.
    static var ask: (_ name: String, _ folder: String, _ more: Bool) -> (Choice, Bool) = { name, folder, more in
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” is already in “\(folder)”.")
        alert.informativeText = String(localized: "Replace sends the one there to the Trash.")
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.showsSuppressionButton = more
        alert.suppressionButton?.title = String(localized: "Apply to all")
        let answer = alert.runModal()
        let choice: Choice = answer == .alertFirstButtonReturn ? .keepBoth : answer == .alertSecondButtonReturn ? .replace : .skip
        return (choice, alert.suppressionButton?.state == .on)
    }

    /// What goes, and the new names of those kept beside one already there. Replaced ones go to
    /// the Trash now: recorded in the open undo group, or (`deferred`: a checked copy still to
    /// run) kept for that copy's undo. Problems (a Replace that couldn't be done) go in `notes`.
    static func plan(_ items: [URL], into folder: URL, deferred: Bool = false) -> (items: [URL], names: [URL: String], notes: [String]) {
        let fm = FileManager.default
        let folderName = fm.displayName(atPath: folder.path)
        var taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let clashing = items.filter { item in
            item.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path
                && taken.contains(item.lastPathComponent.lowercased())
        }
        var kept: [URL] = [], names: [URL: String] = [:], notes: [String] = []
        var always: Choice?
        var left = clashing.count
        for item in items {
            guard clashing.contains(item) else { kept.append(item); continue }
            left -= 1
            let choice: Choice
            if let always { choice = always } else {
                let (answer, all) = ask(item.lastPathComponent, folderName, left > 0)
                choice = answer
                if all { always = answer }
            }
            switch choice {
            case .skip: continue
            case .keepBoth:
                let name = freeName(item.lastPathComponent, taken: taken)
                taken.insert(name.lowercased())
                names[item] = name
                kept.append(item)
            case .replace:
                let there = folder.appendingPathComponent(item.lastPathComponent)
                // (Not the folder it's in: that would take it to the Trash too.)
                if FinderPane.isInside(item, there) {
                    notes.append(String(localized: "\(item.lastPathComponent) is inside the one it would replace."))
                    continue
                }
                do {
                    if deferred {
                        let back = try FileUndo.shared.run([.trash(there)])
                        FileUndo.shared.pendingReplaced[there.standardizedFileURL.path, default: []] += back
                    } else {
                        try FileUndo.shared.perform(String(localized: "Replace"), [.trash(there)])
                    }
                    kept.append(item)
                } catch {
                    notes.append(error.localizedDescription)
                }
            }
        }
        return (kept, names, notes)
    }

    /// Finder's name beside one already there: "name 2.ext", "name 3.ext"…
    nonisolated static func freeName(_ name: String, taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}

/// Edit ▸ Undo and Redo for the Library's files (the keys are held by the Library page itself).
struct LibraryUndoCommands: View {
    @State private var undo = FileUndo.shared
    @State private var nav = StudioNavigator.shared

    var body: some View {
        let here = nav.page == .library
        Button(undo.undoName.map { String(localized: "Undo \($0) in Library") } ?? String(localized: "Undo in Library")) { show(undo.undo()) }
            .disabled(!here || undo.undoName == nil)
        Button(undo.redoName.map { String(localized: "Redo \($0) in Library") } ?? String(localized: "Redo in Library")) { show(undo.redo()) }
            .disabled(!here || undo.redoName == nil)
    }

    private func show(_ problem: String?) {
        guard let problem else { return }
        let alert = NSAlert()
        alert.messageText = problem
        alert.runModal()
    }
}

// MARK: - Files moved outside Pluck

/// Who each Library file is (a bookmark, which follows a file renamed or moved on its drive),
/// so an entry whose file moved outside Pluck follows it instead of going missing.
@MainActor
enum LibraryIdentity {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/library-identity.plist")
    }

    /// Each file's identity noted (once), entries whose files moved follow them; the paths still missing.
    static func check(_ entries: [LibraryStore.Entry]) async -> Set<String> {
        let paths = entries.map(\.path), store = file
        let (moves, gone) = await Task.detached(priority: .utility) { () -> ([(String, String)], Set<String>) in
            let fm = FileManager.default
            var marks = (try? Data(contentsOf: store)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Data] } ?? [:]
            let known = Set(paths)
            var moves: [(String, String)] = [], gone = Set<String>()
            for path in paths {
                if fm.fileExists(atPath: path) {
                    if marks[path] == nil { marks[path] = try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                    continue
                }
                var stale = false
                // (Not a file in the Trash, or one another entry has already.)
                if let mark = marks[path],
                   let found = try? URL(resolvingBookmarkData: mark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                   found.path != path, !known.contains(found.path), !FileUndo.inTrash(found.path), fm.fileExists(atPath: found.path) {
                    moves.append((path, found.path))
                    marks[found.path] = (try? found.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? mark
                } else {
                    gone.insert(path)
                }
            }
            let kept = known.union(moves.map(\.1))
            marks = marks.filter { kept.contains($0.key) }
            if let data = try? PropertyListSerialization.data(fromPropertyList: marks, format: .binary, options: 0) {
                try? fm.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: store, options: .atomic)
            }
            return (moves, gone)
        }.value
        for (old, new) in moves { LibraryStore.shared.relocate(from: old, to: new) }
        return gone
    }
}
