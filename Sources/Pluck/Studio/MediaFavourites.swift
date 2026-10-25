import Foundation

/// The files and ranges marked as favourites, kept in Application Support/Pluck/Favourites.json.
@MainActor
@Observable
final class MediaFavourites {
    static let shared = MediaFavourites(file: {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pluck/Favourites.json")
    }())

    private let file: URL
    private(set) var all: [MediaSource] = []

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        if let saved = try? JSONDecoder().decode([MediaSource].self, from: data) {
            all = saved
        } else {
            // Can't be read: put aside rather than written over by the next favourite.
            let aside = file.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
        }
    }

    /// Adds it, or takes it away if it's one already.
    func toggle(_ source: MediaSource) {
        if let index = all.firstIndex(of: source) { all.remove(at: index) } else { all.append(source) }
        save()
    }

    /// Whether this file, or a range of it, is a favourite.
    func contains(path: String) -> Bool { all.contains { $0.path == path } }

    /// F: the in-to-out range of the file shown in a tab, or else the row chosen in the media
    /// panel. False when there is neither.
    func toggleCurrent(in project: ProjectModel?) -> Bool {
        if let project, let path = project.project.origin, let start = project.project.inPoint, let end = project.project.outPoint,
           let from = project.fileTime(at: start), let to = project.fileTime(at: max(end - 0.001, start)), to.time + 0.001 > from.time {
            toggle(MediaSource(path: path, span: from.time...(to.time + 0.001)))
            return true
        }
        guard let source = MediaSelection.shared.source else { return false }
        toggle(source)
        return true
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }
}
