import Foundation

/// Something from the Edit page's libraries, dragged onto the timeline or double-clicked.
enum EditLibraryItem: Codable, Hashable {
    case transition(ProjectTransition.Kind)
    /// A motion template (by its id), rendered and laid over the picture.
    case title(templateID: String)
    /// A plain title, as the Titles panel adds.
    case plainTitle
    /// A look over five seconds.
    case adjustment
    /// The clip there, steadied.
    case stabilize

    private static let prefix = "pluck-library:"

    /// What a drag carries (plain text, so it needs no file type of its own).
    var payload: String {
        Self.prefix + (String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "")
    }

    init?(payload: String) {
        guard payload.hasPrefix(Self.prefix),
              let item = try? JSONDecoder().decode(EditLibraryItem.self, from: Data(payload.dropFirst(Self.prefix.count).utf8)) else { return nil }
        self = item
    }
}

extension ProjectModel {
    /// How near a cut a transition has to land to go on it (seconds).
    static let transitionReach = 1.5

    /// Puts a library item into the edit at a time on the timeline. True when the edit changed.
    @discardableResult
    func apply(_ item: EditLibraryItem, at seconds: Double) async -> Bool {
        switch item {
        case .transition(let kind):
            let cuts = offsets.enumerated().dropFirst()
            guard let (index, _) = cuts.min(by: { abs($0.element - seconds) < abs($1.element - seconds) }),
                  abs(offsets[index] - seconds) <= Self.transitionReach else { return false }
            setTransition(into: index, ProjectTransition(kind: kind, length: transition(into: index)?.length ?? 0.5))
            libraryProblem = nil
            return true
        case .plainTitle:
            addTitle(at: max(seconds, 0))
            return true
        case .title(let id):
            return placeTemplate(id, at: max(seconds, 0))
        case .adjustment:
            guard duration > 0 else { return false }
            let start = min(max(seconds, 0), duration)
            let end = min(start + 5, duration)
            guard end - start > frame else { return false }
            addAdjustment(over: start...end)
            return true
        case .stabilize:
            guard let (index, _) = clip(at: seconds), project.clips.indices.contains(index) else { return false }
            let clip = project.clips[index]
            set(clip.id) { clip in
                var look = clip.look ?? ClipLook()
                look.stabilize = true
                clip.look = look
            }
            Stabilizer.shared.start(clip.path)
            return true
        }
    }
}
