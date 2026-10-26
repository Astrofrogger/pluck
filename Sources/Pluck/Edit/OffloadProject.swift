import Foundation

/// A shoot offloaded card by card: the drives it goes to, the people filming (each with a camera
/// letter), how its folders are named, and the cameras it has seen, so each card goes into the
/// right person's folder under the next card number.
struct OffloadProject: Codable, Identifiable, Hashable {
    /// Someone filming, with the letter their camera's cards get (A, B, C…).
    struct Operator: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var letter: String
    }

    /// A folder that's there or not, and how it's named.
    struct FolderRule: Codable, Hashable {
        var on: Bool
        var template: String
    }

    var id = UUID()
    var name: String
    /// Where every card is copied, the main drive first.
    var drives: [String] = []
    /// Where the whole project is backed up later.
    var backups: [String] = []
    var operators: [Operator] = []
    var dayFolder = FolderRule(on: true, template: "{date:yyyy-MM-dd}")
    var operatorFolder = "{letter}_{operator}"
    var cardFolder = FolderRule(on: true, template: "{letter}{card:000}")
    /// A camera's ID or serial (see CameraCard.key) and whose camera it is.
    var cameras: [String: UUID] = [:]
    /// Who the last card was for (preselected when a card doesn't say which camera it's from).
    var lastOperator: UUID?
    /// The next card's number, per letter (it runs on across days).
    var nextCard: [String: Int] = [:]
    var created = Date.now

    func person(_ id: UUID?) -> Operator? { operators.first { $0.id == id } }

    /// When the first card of this project was offloaded (nil while there is none).
    func firstOffload(in jobs: [OffloadJob]) -> Date? {
        jobs.filter { $0.project == id }.map(\.started).min()
    }

    /// The day of the shoot a date is: the day the first card was offloaded is day 1 (the
    /// date itself, while there isn't one yet).
    func day(of date: Date, firstOffload: Date? = nil) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstOffload ?? date), to: calendar.startOfDay(for: date)).day ?? 0
        return max(days, 0) + 1
    }

    /// Whose camera a card is from, or that Pluck has to ask (with who to suggest).
    enum Match: Equatable {
        case known(UUID)
        case ask(preselected: UUID?)
    }

    /// A camera seen before is its operator's; one not seen before is asked once; a card that
    /// doesn't say which camera it's from is asked every time, never guessed.
    func match(_ card: CameraCard) -> Match {
        if let key = card.key, let id = cameras[key], person(id) != nil { return .known(id) }
        // A camera letter on the card suggests who it is (still asked).
        if let letter = card.letter, let named = operators.first(where: { $0.letter.caseInsensitiveCompare(letter) == .orderedSame }) {
            return .ask(preselected: named.id)
        }
        return .ask(preselected: person(lastOperator)?.id)
    }

    /// A card was offloaded for this operator: their camera is known from now on.
    mutating func remember(_ card: CameraCard, for id: UUID) {
        if let key = card.key { cameras[key] = id }
        lastOperator = id
    }

    /// The first letter no one has yet.
    var freeLetter: String {
        let taken = Set(operators.map { $0.letter.uppercased() })
        return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init).first { !taken.contains($0) } ?? "Z"
    }
}

/// Folder names from a template: `{date:yyyy-MM-dd}` (any date pattern), `{day}`, `{letter}`,
/// `{operator}`, `{camera}`, `{card:000}` (as many digits as zeros), and any other text as it is.
enum FolderTemplate {
    static let tokens = ["{date:yyyy-MM-dd}", "{day}", "{letter}", "{operator}", "{camera}", "{card:000}"]

    static func render(_ template: String, date: Date, day: Int, letter: String, operator: String, camera: String, card: Int) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let token = rest[rest.index(after: open)..<close]
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : nil
            switch parts.first?.lowercased() ?? "" {
            case "date":
                let format = DateFormatter()
                format.calendar = Calendar(identifier: .gregorian)
                format.dateFormat = argument ?? "yyyy-MM-dd"
                result += format.string(from: date)
            case "day": result += padded(day, argument)
            case "letter": result += letter
            case "operator": result += `operator`
            case "camera": result += camera
            case "card": result += padded(card, argument)
            default: result += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return safe(result)
    }

    /// A number with as many digits as the zeros given ("000": 004).
    private static func padded(_ number: Int, _ zeros: String?) -> String {
        let digits = zeros?.filter { $0 == "0" }.count ?? 0
        let text = String(number)
        return String(repeating: "0", count: max(digits - text.count, 0)) + text
    }

    /// Without what a file name can't hold (slashes, colons, control characters), and not hidden.
    static func safe(_ name: String) -> String {
        let cleaned = String(name.map { "/\\:".contains($0) || $0.isASCII && $0.asciiValue! < 32 ? "-" : $0 })
        var trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed
    }
}

/// Every offload project, kept next to Offload's jobs, and the one cards go into.
@MainActor
@Observable
final class OffloadProjects {
    static let shared = OffloadProjects()

    private(set) var projects: [OffloadProject] = []
    /// The project cards go into (nil: an offload to any folder, as without projects).
    var active: UUID? {
        didSet { UserDefaults.standard.set(active?.uuidString, forKey: Self.activeKey) }
    }

    var current: OffloadProject? { project(active) }

    private static let activeKey = "offloadProject"

    nonisolated static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Offload Projects.json")
    }

    private init() {
        projects = (try? JSONDecoder().decode([OffloadProject].self, from: Data(contentsOf: Self.file))) ?? []
        let saved = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        active = projects.contains { $0.id == saved } ? saved : nil
    }

    func project(_ id: UUID?) -> OffloadProject? { projects.first { $0.id == id } }

    /// Kept (a new one added, or the one with its ID replaced).
    func save(_ project: OffloadProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        write()
    }

    func remove(_ id: UUID) {
        projects.removeAll { $0.id == id }
        if active == id { active = nil }
        write()
    }

    /// One project changed where it's kept.
    func change(_ id: UUID, _ change: (inout OffloadProject) -> Void) {
        guard var project = project(id) else { return }
        change(&project)
        save(project)
    }

    private func write() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(projects).write(to: Self.file, options: .atomic)
    }
}
