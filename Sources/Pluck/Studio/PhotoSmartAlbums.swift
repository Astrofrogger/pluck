import SwiftUI
import UniformTypeIdentifiers

/// An album that fills itself: every photo that meets its rules (all of them, or any).
struct SmartAlbum: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]
}

/// One rule of a smart album. One shape for every kind, so the sheet can switch kinds in place:
/// each kind reads only what it needs.
struct SmartRule: Codable, Identifiable, Hashable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case rating, flag, label, keyword, date, camera, lens, fileType, edited, faces, person
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .rating: "Rating"
            case .flag: "Flag"
            case .label: "Colour Label"
            case .keyword: "Keyword"
            case .date: "Date Taken"
            case .camera: "Camera"
            case .lens: "Lens"
            case .fileType: "File Type"
            case .edited: "Edited"
            case .faces: "Faces"
            case .person: "Person"
            }
        }
    }

    var id = UUID()
    var field = Field.rating
    /// Rating: the stars; with `exact`, exactly that many, else at least.
    var number = 3
    var exact: Bool?
    /// Flag ("pick", "reject", "none"), label, keyword, camera, lens (contains), file type ("raw",
    /// "jpeg", "heic", "dng"), date ("year", "month", "between"), person (its id).
    var text = ""
    var from: Date?
    var to: Date?
    /// Edited, faces: whether it is (true) or isn't.
    var yes: Bool?

    /// What a photo is, for the rules (gathered once per photo).
    struct Facts {
        var record: PhotoRecord
        var fact: PhotoFact?
        var check: PhotoCheck?
        var labels: [String] = []
        var people: Set<UUID> = []
    }

    func matches(_ path: String, _ facts: Facts, now: Date = .now) -> Bool {
        let record = facts.record
        switch field {
        case .rating: return exact == true ? record.rating == number : record.rating >= number
        case .flag: return record.flag.rawValue == (text.isEmpty ? "pick" : text)
        case .label: return record.label == (text.isEmpty ? PhotoInspector.labels[0] : text)
        case .keyword:
            guard !text.isEmpty else { return true }
            let want = PhotoIndex.normalized(text)
            return ((record.meta?.keywords ?? []) + facts.labels).contains { PhotoIndex.normalized($0).contains(want) }
        case .camera: return contains(facts.fact?.camera)
        case .lens: return contains(facts.fact?.lens)
        case .fileType: return Self.fileType(of: path) == (text.isEmpty ? "raw" : text)
        case .edited: return record.isEdited == (yes ?? true)
        case .faces: return (!(facts.check?.faces ?? []).isEmpty || !facts.people.isEmpty) == (yes ?? true)
        case .person: return UUID(uuidString: text).map(facts.people.contains) ?? false
        case .date:
            guard let taken = facts.fact?.taken ?? facts.check?.taken else { return false }
            let calendar = Calendar.current
            switch text {
            case "month": return taken >= calendar.date(byAdding: .day, value: -30, to: now)! && taken <= now
            case "between":
                let start = calendar.startOfDay(for: from ?? .distantPast)
                let end = to.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? .distantFuture
                return taken >= start && taken < end
            default: return calendar.isDate(taken, equalTo: now, toGranularity: .year)
            }
        }
    }

    private func contains(_ value: String?) -> Bool {
        guard !text.isEmpty else { return value != nil }
        return value.map { PhotoIndex.normalized($0).contains(PhotoIndex.normalized(text)) } ?? false
    }

    /// "raw", "dng", "jpeg", "heic" or "other", from the file's name.
    nonisolated static func fileType(of path: String) -> String {
        let ext = URL(fileURLWithPath: PhotoCatalog.file(of: path)).pathExtension.lowercased()
        switch ext {
        case "dng": return "dng"
        case "jpg", "jpeg": return "jpeg"
        case "heic", "heif", "hif": return "heic"
        default: return UTType(filenameExtension: ext)?.conforms(to: .rawImage) == true ? "raw" : "other"
        }
    }
}

extension SmartAlbum {
    // A rule that can't be read (a kind from a newer Pluck) is left out, not the whole album.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        matchAll = (try? c.decode(Bool.self, forKey: .matchAll)) ?? true
        rules = ((try? c.decode([Lossy<SmartRule>].self, forKey: .rules)) ?? []).compactMap(\.value)
    }
}

extension SmartRule {
    // Each value on its own (one that can't be read keeps its default); only the kind must be known.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(Field.self, forKey: .field)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        number = (try? c.decode(Int.self, forKey: .number)) ?? 3
        exact = try? c.decodeIfPresent(Bool.self, forKey: .exact)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        from = try? c.decodeIfPresent(Date.self, forKey: .from)
        to = try? c.decodeIfPresent(Date.self, forKey: .to)
        yes = try? c.decodeIfPresent(Bool.self, forKey: .yes)
    }
}

/// The smart albums' photos, worked out again only when something they look at has changed.
@MainActor
final class SmartAlbumCache {
    static let shared = SmartAlbumCache()
    private var results: [UUID: (key: Key, paths: [String])] = [:]

    private struct Key: Equatable {
        var album: SmartAlbum
        var catalog: Int
        var facts: Int
        var checks: Int
        var people: Int
        var photos: Int
        var labels: Int
    }

    func photos(_ album: SmartAlbum, from all: [String]) -> [String] {
        let catalog = PhotoCatalog.shared
        let key = Key(album: album, catalog: catalog.revision, facts: PhotoFacts.shared.revision, checks: PhotoChecks.shared.checks.count,
                      people: PhotoPeople.shared.revision, photos: all.count, labels: PhotoIndex.shared.count)
        if let known = results[album.id], known.key == key { return known.paths }
        let now = Date.now
        let paths = all.filter { path in
            let file = PhotoCatalog.file(of: path)
            let facts = SmartRule.Facts(record: catalog.record(path), fact: PhotoFacts.shared.fact(path), check: PhotoChecks.shared.check(file),
                                        labels: PhotoIndex.shared.entries[file]?.labels ?? [], people: PhotoPeople.shared.people(in: path))
            let met = album.rules.lazy.map { $0.matches(path, facts, now: now) }
            return album.rules.isEmpty ? false : album.matchAll ? met.allSatisfy { $0 } : met.contains(true)
        }
        results[album.id] = (key, paths)
        return paths
    }
}

// MARK: - The sheet

/// Makes or changes a smart album: its name, whether all or any rules must match, the rules.
struct SmartAlbumSheet: View {
    @State var album: SmartAlbum
    let save: (SmartAlbum) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people = PhotoPeople.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Text("Smart Album").font(Design.Studio.sectionTitle)
            Form {
                Section {
                    TextField("Name", text: $album.name)
                    Picker("Match", selection: $album.matchAll) {
                        Text("All Rules").tag(true)
                        Text("Any Rule").tag(false)
                    }
                }
                Section("Rules") {
                    ForEach($album.rules) { $rule in
                        HStack {
                            // A new kind starts afresh (a flag's "pick" means nothing to a label).
                            Picker("Rule", selection: Binding(get: { rule.field }, set: { rule = SmartRule(id: rule.id, field: $0) })) {
                                ForEach(SmartRule.Field.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            value($rule)
                            Spacer(minLength: 0)
                            Button {
                                album.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove Rule")
                            .accessibilityLabel(Text("Remove Rule"))
                        }
                    }
                    Button("Add Rule", systemImage: "plus") { album.rules.append(SmartRule()) }
                        .buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(StudioFlatButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if album.name.trimmingCharacters(in: .whitespaces).isEmpty { album.name = String(localized: "Smart Album") }
                    // Dates as shown: an untouched date picker shows today.
                    for i in album.rules.indices where album.rules[i].field == .date && album.rules[i].text == "between" {
                        album.rules[i].from = album.rules[i].from ?? .now
                        album.rules[i].to = album.rules[i].to ?? .now
                    }
                    // A person menu left as it was shows the first person.
                    for i in album.rules.indices where album.rules[i].field == .person && album.rules[i].text.isEmpty {
                        album.rules[i].text = people.shown.first?.id.uuidString ?? ""
                    }
                    save(album)
                    dismiss()
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(album.rules.isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
    }

    /// The controls for a rule's kind.
    @ViewBuilder private func value(_ rule: Binding<SmartRule>) -> some View {
        switch rule.wrappedValue.field {
        case .rating:
            Picker("Test", selection: Binding(get: { rule.wrappedValue.exact == true }, set: { rule.wrappedValue.exact = $0 ? true : nil })) {
                Text(verbatim: "≥").tag(false)
                Text(verbatim: "=").tag(true)
            }
            .labelsHidden().fixedSize()
            Picker("Stars", selection: rule.number) {
                ForEach(0...5, id: \.self) { stars in Text(stars == 0 ? "No Stars" : String(repeating: "★", count: stars)).tag(stars) }
            }
            .labelsHidden().fixedSize()
        case .flag:
            choice(rule, [("pick", String(localized: "Pick")), ("reject", String(localized: "Rejected")), ("none", String(localized: "Not Flagged"))])
        case .label:
            choice(rule, PhotoInspector.labels.map { ($0, PhotoInspector.labelTitle($0)) })
        case .keyword, .camera, .lens:
            TextField("Contains", text: rule.text, prompt: Text("Contains"))
                .labelsHidden()
        case .fileType:
            choice(rule, [("raw", "RAW"), ("jpeg", "JPEG"), ("heic", "HEIC"), ("dng", "DNG")])
        case .edited, .faces:
            Picker("Is", selection: Binding(get: { rule.wrappedValue.yes ?? true }, set: { rule.wrappedValue.yes = $0 ? nil : false })) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }
            .labelsHidden().fixedSize()
        case .person:
            if people.shown.isEmpty {
                Text("No people found yet").foregroundStyle(.secondary)
            } else {
                choice(rule, people.shown.map { ($0.id.uuidString, people.title($0)) })
            }
        case .date:
            choice(rule, [("year", String(localized: "This Year")), ("month", String(localized: "Last 30 Days")), ("between", String(localized: "Between"))])
            if rule.wrappedValue.text == "between" {
                DatePicker("From", selection: Binding(get: { rule.wrappedValue.from ?? .now }, set: { rule.wrappedValue.from = $0 }), displayedComponents: .date)
                    .labelsHidden()
                DatePicker("To", selection: Binding(get: { rule.wrappedValue.to ?? .now }, set: { rule.wrappedValue.to = $0 }), displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    /// A menu of choices for the rule's text; the first is taken when none is chosen yet.
    private func choice(_ rule: Binding<SmartRule>, _ options: [(String, String)]) -> some View {
        Picker("Value", selection: Binding(get: { options.contains { $0.0 == rule.wrappedValue.text } ? rule.wrappedValue.text : options.first?.0 ?? "" },
                                           set: { rule.wrappedValue.text = $0 })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
