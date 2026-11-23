import AppKit
import Foundation

/// Missing Library files found again: "Locate…" for one, or a folder searched for all of them by
/// file name and size. The entry (tags, collections) and its transcript move with the file
/// (LibraryStore.relocate), and it's one undo.
@MainActor
enum LibraryRelink {
    struct Plan {
        /// Old path, the file that's there now.
        var matches: [(from: String, to: String)] = []
        /// More than one file fits (or two entries want the same one): the user chooses.
        var ambiguous: [(from: String, options: [String])] = []
        var notFound = 0
    }

    /// Pure: what fits what. Same name (any case) and, when the entry knows its size, the same
    /// size. `taken`: paths other entries already use (never a match).
    nonisolated static func plan(missing: [(path: String, size: Int64?)], found: [(path: String, size: Int64)], taken: Set<String>) -> Plan {
        var byName: [String: [(path: String, size: Int64)]] = [:]
        for file in found where !taken.contains(file.path) {
            byName[(file.path as NSString).lastPathComponent.lowercased(), default: []].append(file)
        }
        var chosen: [(from: String, options: [String])] = []
        var plan = Plan()
        for entry in missing {
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            let fits = (byName[name] ?? []).filter { entry.size == nil || $0.size == entry.size }.map(\.path)
            if fits.isEmpty { plan.notFound += 1 } else { chosen.append((entry.path, fits)) }
        }
        // (One file for two entries is a guess too.)
        var wanted: [String: Int] = [:]
        for pick in chosen where pick.options.count == 1 { wanted[pick.options[0], default: 0] += 1 }
        for pick in chosen {
            if pick.options.count == 1, wanted[pick.options[0]] == 1 { plan.matches.append((pick.from, pick.options[0])) }
            else { plan.ambiguous.append(pick) }
        }
        return plan
    }

    /// Files in a folder (all the way down) whose name is one of `names` (lowercase), with sizes.
    nonisolated static func scan(_ folder: URL, names: Set<String>) -> [(path: String, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(String, Int64)] = []
        for case let url as URL in walker where names.contains(url.lastPathComponent.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((url.path, Int64(values.fileSize ?? 0)))
        }
        return found
    }

    /// Entries now at their files; one undo.
    static func apply(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        for pair in pairs { LibraryStore.shared.relocate(from: pair.from, to: pair.to) }
        FileUndo.shared.record(String(localized: "Locate Files"), undo: pairs.map { .relocate($0.to, $0.from) })
    }

    /// Locate…: the user chooses where this one is now.
    static func locate(_ entry: LibraryStore.Entry, done: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Where is “\(entry.file.lastPathComponent)”?")
        panel.canChooseFiles = true
        panel.canChooseDirectories = entry.file.pathExtension.isEmpty
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Locate")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if LibraryStore.shared.entries.contains(where: { $0.path == url.path }) {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(url.lastPathComponent)” is already in the Library.")
            alert.runModal()
            return
        }
        apply([(entry.path, url.path)])
        done()
    }

    /// Find in Folder…: every missing item looked for in a folder the user chooses.
    static func findInFolder(_ missing: [LibraryStore.Entry], done: @escaping () -> Void) {
        guard !missing.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the folder to look in.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Search")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let names = Set(missing.map { $0.file.lastPathComponent.lowercased() })
        let taken = Set(LibraryStore.shared.entries.map(\.path))
        Task {
            let found = await Task.detached(priority: .userInitiated) { scan(folder, names: names) }.value
            var plan = plan(missing: missing.map { ($0.path, $0.size) }, found: found, taken: taken)
            var used = Set(plan.matches.map(\.to))
            var skipped = 0
            for ask in plan.ambiguous {
                let options = ask.options.filter { !used.contains($0) }
                if let pick = choose(for: ask.from, among: options) { plan.matches.append((ask.from, pick)); used.insert(pick) } else { skipped += 1 }
            }
            apply(plan.matches)
            done()
            let alert = NSAlert()
            alert.messageText = String(localized: "Found \(plan.matches.count) of \(missing.count) files.")
            var notes: [String] = []
            if plan.notFound > 0 { notes.append(String(localized: "\(plan.notFound) not in that folder.")) }
            if skipped > 0 { notes.append(String(localized: "\(skipped) skipped.")) }
            alert.informativeText = notes.joined(separator: " ")
            alert.runModal()
        }
    }

    /// Several files fit: the user picks one, or none (never a guess).
    private static func choose(for path: String, among options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = String(localized: "Which “\((path as NSString).lastPathComponent)”?")
        alert.informativeText = String(localized: "More than one file fits.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
        popup.addItems(withTitles: options.map { ($0 as NSString).abbreviatingWithTildeInPath })
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "Use This One"))
        alert.addButton(withTitle: String(localized: "Skip"))
        return alert.runModal() == .alertFirstButtonReturn ? options[popup.indexOfSelectedItem] : nil
    }
}

extension TranscriptStore {
    /// The file moved: its transcript (if any) follows, by the path it's matched with.
    static func move(from old: String, to new: String) {
        guard var transcript = find(forFile: old) else { return }
        transcript.filePath = new
        save(transcript)
    }
}
