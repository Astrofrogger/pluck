import Foundation

/// Offload → Sync: a finished offload's copies opened in Sync Cameras (its first copy that's here),
/// only the files whose checksum passed on every drive, each card a camera named after the card.
extension CameraSync {
    /// The offload's checked clips, each with the folder holding its card's folder (so the card's
    /// folder is what groups it), and the card folder → the name its camera gets.
    static func offloadItems(_ job: OffloadJob) -> (items: [(file: URL, root: URL)], names: [String: String]) {
        let fm = FileManager.default
        guard let target = job.targets.first(where: { fm.fileExists(atPath: $0) }) else { return ([], [:]) }
        let card = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        let root = card.deletingLastPathComponent()
        let items = job.files.filter { $0.problem == nil && !$0.done.isEmpty && !$0.done.contains(false) }.compactMap { file -> (file: URL, root: URL)? in
            let url = card.appendingPathComponent(job.destination(of: file.path))
            guard wanted(url), !url.lastPathComponent.hasPrefix("._"), fm.fileExists(atPath: url.path) else { return nil }
            return (url, root)
        }
        let name = job.card ?? (job.name.isEmpty ? job.sourceVolume : job.displayName)
        return (items, [card.path: name])
    }

    /// Cameras whose clips all come from one named card folder take its name ("A004"); cameras found by
    /// serial or a RED/Blackmagic letter, and sound recorders, keep theirs.
    static func name(_ cameras: inout [SyncCamera], cards: [String: String]) {
        guard !cards.isEmpty else { return }
        let named = cameras.indices.filter { cameras[$0].key.hasPrefix("folder:") || cameras[$0].key.hasPrefix("card:") }
        let folderOf = Dictionary(uniqueKeysWithValues: named.map { c in
            (c, Set(cameras[c].clips.map { clip in cards.keys.first { clip.path.hasPrefix($0 + "/") } }))
        })
        for c in named {
            guard let folders = folderOf[c], folders.count == 1, let folder = folders.first ?? nil, let name = cards[folder],
                  // (One card holding two cameras' files: they keep their own names.)
                  folderOf.values.filter({ $0 == folders }).count == 1 else { continue }
            cameras[c].name = name
        }
    }
}
