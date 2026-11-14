import Foundation

/// The Photo page's files on disk: one writer for all of them, a file that can't be read kept aside, and everything saved at
/// once when Pluck quits.
enum PhotoSaving {
    /// One queue for every write, so a later save never lands before an earlier one.
    nonisolated static let writer = DispatchQueue(label: "Pluck.PhotoSaving", qos: .utility)

    /// Writes in the background, after any write asked for before it.
    nonisolated static func write(_ url: URL, _ make: @escaping () -> Data?) {
        writer.async { store(url, make) }
    }

    /// Writes now (and waits), after any write asked for before it.
    nonisolated static func writeNow(_ url: URL, _ make: () -> Data?) {
        writer.sync { store(url, make) }
    }

    nonisolated private static func store(_ url: URL, _ make: () -> Data?) {
        guard let data = make() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// A file that's there but couldn't be read (or only in part) is kept beside it under a new name, so the next save
    /// never replaces it with less. `move`: taken away (nothing of it was read); else copied. False when it couldn't be kept.
    @discardableResult
    nonisolated static func setAside(_ url: URL, move: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        let kept = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (unreadable \(stamp)).\(url.pathExtension)")
        do {
            if move { try FileManager.default.moveItem(at: url, to: kept) } else { try FileManager.default.copyItem(at: url, to: kept) }
            return true
        } catch {
            return false
        }
    }

    /// Everything the Photo page keeps, written now (call when Pluck quits: a save waiting a moment would be lost).
    @MainActor static func saveAllNow() {
        PhotoCatalog.shared.saveNow()
        PhotoCatalog.shared.writeWaitingSidecars()
        PhotoPeople.shared.saveNow()
        PhotoFacts.shared.saveNow()
    }
}

/// Decodes what it can: an element that can't be read (a newer kind, a damaged value) is left out instead of failing the
/// whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
