import Foundation

/// Where a card goes in a project and what of it is copied: the next card's folder (or the
/// person's own folder), nothing that's already in the project (same name, size and xxHash64),
/// and a new name for a different file whose name is taken, so nothing is ever written over.
enum OffloadProjectPlanner {
    struct Plan {
        /// Where the card goes, in each drive ("Festival/2026-07-12/A_Operator A/A004").
        var folder: String
        /// What's copied.
        var files: [OffloadFile]
        /// A file's path on the card, and the name it gets beside the others (C0001_A004.MP4).
        var renames: [String: String]
        /// Files already in the project: not copied again.
        var alreadyThere: Int
        /// The card's number (the next one, or later when that card's folder is already there).
        var card: Int
        /// The card's name ("A004").
        var label: String
    }

    /// Folders and files (relative to a drive, in lower case) that cards waiting to be copied
    /// will take: not on the drives yet, but not free either.
    struct Reserved: Sendable {
        var folders: Set<String> = []
        var files: Set<String> = []
    }

    /// Plans a card, reading the drives (and, for files that may already be there, the card):
    /// call it away from the main thread.
    static func plan(card: URL, files: [OffloadFile], project: OffloadProject, operator person: OffloadProject.Operator,
                     date: Date, camera: String = "", firstOffload: Date? = nil, reserved: Reserved = Reserved()) -> Plan {
        let letter = person.letter
        func render(_ template: String, _ number: Int) -> String {
            FolderTemplate.render(template, date: date, day: project.day(of: date, firstOffload: firstOffload), letter: letter, operator: person.name,
                                  camera: camera, card: number)
        }
        func folder(_ number: Int) -> String {
            var parts = [FolderTemplate.safe(project.name)]
            if project.dayFolder.on { parts.append(render(project.dayFolder.template, number)) }
            let own = render(project.operatorFolder, number)
            parts.append(own.isEmpty ? FolderTemplate.safe(letter) : own)
            if project.cardFolder.on { parts.append(render(project.cardFolder.template, number)) }
            return parts.filter { !$0.isEmpty }.joined(separator: "/")
        }
        let drives = project.drives.filter { FileManager.default.fileExists(atPath: $0) }
        func exists(_ path: String) -> Bool {
            drives.contains { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(path)) }
        }

        // The next number, past a card folder that's already there (a project moved, or kept twice).
        var number = max(project.nextCard[letter] ?? 1, 1)
        if project.cardFolder.on {
            func used(_ number: Int) -> Bool { exists(folder(number)) || reserved.folders.contains(folder(number).lowercased()) }
            while used(number), folder(number + 1) != folder(number), number < 100_000 { number += 1 }
        }
        let target = folder(number)
        let label = FolderTemplate.safe(letter) + String(format: "%03d", number)

        // What's in the project already, by name and size (from the main drive, or the first there).
        var index: [String: [String]] = [:]
        var root: String?
        if let drive = drives.first {
            let place = (drive as NSString).appendingPathComponent(FolderTemplate.safe(project.name))
            root = place
            for file in OffloadCenter.files(in: URL(fileURLWithPath: place, isDirectory: true)) {
                index[key((file.path as NSString).lastPathComponent, file.size), default: []].append(file.path)
            }
        }
        let hashes = KnownHashes()
        // Only "already there" when it's on every drive of the project, not on the main one alone
        // (a drive added later, or a copy that failed on one drive, would otherwise never get it).
        func onEveryDrive(_ path: String, _ size: Int64) -> Bool {
            drives.dropFirst().allSatisfy { drive in
                let place = ((drive as NSString).appendingPathComponent(FolderTemplate.safe(project.name)) as NSString).appendingPathComponent(path)
                return ((try? FileManager.default.attributesOfItem(atPath: place))?[.size] as? NSNumber)?.int64Value == size
            }
        }

        var planned: [OffloadFile] = []
        var renames: [String: String] = [:]
        var already = 0
        var taken: Set<String> = []
        // A name already on a drive, given to another file of this card, or kept for a card still to be copied.
        func isTaken(_ path: String) -> Bool {
            let full = (target as NSString).appendingPathComponent(path)
            return exists(full) || taken.contains(path.lowercased()) || reserved.files.contains(full.lowercased())
        }
        for file in files {
            let name = (file.path as NSString).lastPathComponent
            // The same file (name, size and checksum) anywhere in the project: not copied again.
            if let root, let candidates = index[key(name, file.size)]?.filter({ onEveryDrive($0, file.size) }), !candidates.isEmpty {
                let source = card.appendingPathComponent(file.path).path
                let ours = MHL.hash(source, kind: "xxhash64be", progress: { _ in }, stopped: { false })
                if let ours, candidates.contains(where: { hashes.hash(of: $0, in: root) == ours }) {
                    already += 1
                    continue
                }
            }
            // A different file where this one would go: given the card's name, never written over.
            var path = file.path
            if isTaken(path) {
                let folder = (file.path as NSString).deletingLastPathComponent
                let stem = (name as NSString).deletingPathExtension, kind = (name as NSString).pathExtension
                var attempt = 1
                repeat {
                    let renamed = stem + "_" + label + (attempt > 1 ? "_\(attempt)" : "") + (kind.isEmpty ? "" : "." + kind)
                    path = (folder as NSString).appendingPathComponent(renamed)
                    renames[file.path] = renamed
                    attempt += 1
                } while isTaken(path)
            }
            taken.insert(path.lowercased())
            planned.append(file)
        }
        return Plan(folder: target, files: planned, renames: renames, alreadyThere: already, card: number, label: label)
    }

    private static func key(_ name: String, _ size: Int64) -> String { name.lowercased() + "|" + String(size) }

    /// The xxHash64 of files in the project: from the MHL next to their card's copy (in hex, as
    /// MHL 1.1's xxhash64be and ASC MHL's xxh64 have it), or read.
    private final class KnownHashes {
        private var lists: [String: [String: String]] = [:]
        private var read: [String: String?] = [:]

        /// `path`: relative to the project's folder.
        func hash(of path: String, in root: String) -> String? {
            if let known = read[path] { return known }
            let file = (root as NSString).appendingPathComponent(path)
            var folder = (file as NSString).deletingLastPathComponent
            var found: String?
            // The MHL a copy left: in the file's folder or one above it, up to the project's.
            while found == nil, folder.hasPrefix(root) {
                let list = listed(in: folder)
                found = list[String(file.dropFirst(folder.count + 1))]
                if folder == root { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
            let hash = found ?? MHL.hash(file, kind: "xxhash64be", progress: { _ in }, stopped: { false })
            read[path] = hash
            return hash
        }

        private func listed(in folder: String) -> [String: String] {
            if let known = lists[folder] { return known }
            var hashes: [String: String] = [:]
            for item in MHL.items(in: URL(fileURLWithPath: folder, isDirectory: true)) ?? []
            where ["xxhash64be", "xxh64"].contains(item.kind) {
                hashes[item.path] = item.hash
            }
            lists[folder] = hashes
            return hashes
        }
    }
}
