import CryptoKit
import Foundation

/// The Editor's edit of a file (its cuts, the parts taken out, and the in and out range), kept
/// in Pluck's folder so closing the tab, quitting or a crash loses nothing. Matched to the file
/// by its size and date: a changed file starts fresh.
extension EditorModel {
    private struct SavedEdit: Codable {
        var size: Int
        var modified: Double
        var cuts: [Double]
        var removed: [Double]
        var inPoint: Double?
        var outPoint: Double?
    }

    private var editFile: URL {
        let name = SHA256.hash(data: Data(file.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Editor Edits/\(name).json")
    }

    /// The file's size and date, to know it's still the same file.
    private var fileStamp: (size: Int, modified: Double)? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    /// Brings back the edit saved for this file (when it's still the same file).
    func loadEdit() {
        guard let data = try? Data(contentsOf: editFile), let saved = try? JSONDecoder().decode(SavedEdit.self, from: data),
              let stamp = fileStamp, stamp.size == saved.size, abs(stamp.modified - saved.modified) < 1 else { return }
        restoringEdit = true
        cuts = saved.cuts.filter { $0 > 0 && $0 < duration }.sorted()
        removed = Set(saved.removed)
        inPoint = saved.inPoint
        outPoint = saved.outPoint
        restoringEdit = false
    }

    /// After any change to the edit: written a moment later (a drag is one write).
    func editChanged() {
        guard loaded, !restoringEdit else { return }
        editSaveTask?.cancel()
        editSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveEdit()
        }
    }

    /// Writes the edit now (or removes the file when there's nothing to keep).
    func saveEdit() {
        editSaveTask?.cancel()
        editSaveTask = nil
        guard loaded, let stamp = fileStamp else { return }
        guard !cuts.isEmpty || !removed.isEmpty || inPoint != nil || outPoint != nil else {
            try? FileManager.default.removeItem(at: editFile)
            return
        }
        let saved = SavedEdit(size: stamp.size, modified: stamp.modified, cuts: cuts, removed: Array(removed), inPoint: inPoint, outPoint: outPoint)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: editFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: editFile, options: .atomic)
    }
}
