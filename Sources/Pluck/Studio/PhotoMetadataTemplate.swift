import ImageIO
import SwiftUI

/// Who made a photo and what it is: kept with the photo's record, written to its sidecar and into
/// exports (as XMP and IPTC), so other apps and websites see it.
struct PhotoMeta: Codable, Hashable {
    var creator: String?
    var copyright: String?
    var credit: String?
    var email: String?
    var website: String?
    var title: String?
    var description: String?
    var keywords: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creator = try? c.decodeIfPresent(String.self, forKey: .creator)
        copyright = try? c.decodeIfPresent(String.self, forKey: .copyright)
        credit = try? c.decodeIfPresent(String.self, forKey: .credit)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
    }

    var isEmpty: Bool { self == PhotoMeta() }

    /// The text fields, each with its name (for the editor and the tokens).
    static let fields: [(title: LocalizedStringKey, path: WritableKeyPath<PhotoMeta, String?>, prompt: String)] = [
        ("Creator", \.creator, "Anna Berg"),
        ("Copyright", \.copyright, "© {year} Northwind"),
        ("Credit", \.credit, "Northwind"),
        ("Email", \.email, "studio@example.com"),
        ("Website", \.website, "https://example.com"),
        ("Title", \.title, "{filename}"),
        ("Description", \.description, "{camera}, {date}"),
    ]

    /// These fields over `base`: what's filled in here wins, keywords are added.
    func over(_ base: PhotoMeta?) -> PhotoMeta {
        var result = base ?? PhotoMeta()
        for field in Self.fields {
            if let value = self[keyPath: field.path], !value.isEmpty { result[keyPath: field.path] = value }
        }
        for word in keywords where !result.keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            result.keywords.append(word)
        }
        return result
    }
}

/// A set of fields given to photos as they're imported. Kept in UserDefaults.
struct PhotoMetadataTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var meta = PhotoMeta()

    static let key = "photoMetadataTemplates"

    static var saved: [PhotoMetadataTemplate] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([PhotoMetadataTemplate].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// The fields with their tokens filled in for one photo: {year}, {date}, {camera}, {serial},
    /// {card} and {filename}, from its EXIF (the capture date, else the file's).
    static func expand(_ meta: PhotoMeta, file: URL, card: String?) -> PhotoMeta {
        let properties = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let taken: Date = {
            if let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let reader = DateFormatter()
                reader.locale = Locale(identifier: "en_US_POSIX")
                reader.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = reader.date(from: text) { return date }
            }
            return (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        }()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let camera = [tiff[kCGImagePropertyTIFFMake as String] as? String, tiff[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.reduce(into: [String]()) { parts, part in
                // "Canon" and "Canon EOS R5": the model alone.
                if let first = parts.first, part.lowercased().hasPrefix(first.lowercased()) { parts = [part] } else { parts.append(part) }
            }.joined(separator: " ")
        let serial = (exif["BodySerialNumber"] as? String) ?? (aux[kCGImagePropertyExifAuxSerialNumber as String] as? String) ?? ""
        let tokens = ["{year}": String(Calendar.current.component(.year, from: taken)), "{date}": day.string(from: taken),
                      "{camera}": camera, "{serial}": serial, "{card}": card ?? "", "{filename}": file.deletingPathExtension().lastPathComponent]
        func fill(_ text: String) -> String {
            tokens.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }.trimmingCharacters(in: .whitespaces)
        }
        var result = meta
        for field in PhotoMeta.fields {
            if let value = meta[keyPath: field.path] { result[keyPath: field.path] = fill(value).isEmpty ? nil : fill(value) }
        }
        result.keywords = meta.keywords.map(fill).filter { !$0.isEmpty }
        return result
    }

    /// The memory card a photo is on (its volume's name), if it's on one.
    static func card(of file: URL) -> String? {
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        return parts[2]
    }
}

extension PhotoMeta {
    /// Into a sidecar's XMP: the fields filled in here, and the keywords added to those there.
    /// What other apps wrote in the rest is kept.
    func write(into metadata: CGMutableImageMetadata, previous: PhotoMeta? = nil) {
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" as CFString, "Iptc4xmpCore" as CFString, nil)
        func set(_ path: String, _ value: String?, was: String?) {
            if let value, !value.isEmpty {
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
            } else if let was, !was.isEmpty {
                // Pluck wrote it before and it was taken away here.
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }
        func list(_ path: String, _ name: String, _ type: CGImageMetadataType, _ values: [String]) {
            guard !values.isEmpty, let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                                       name as CFString, type, values as CFArray) else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag)
        }
        if let creator, !creator.isEmpty {
            list("dc:creator", "creator", .arrayOrdered, [creator])
        } else if previous?.creator?.isEmpty == false {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:creator" as CFString)
        }
        var subjects: [String] = []
        while let word = CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:subject[\(subjects.count)]" as CFString) as String? {
            subjects.append(word)
        }
        // Keywords: those there, without the ones taken away here, and the new ones.
        let removed = (previous?.keywords ?? []).filter { word in !keywords.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        let kept = subjects.filter { word in !removed.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        let added = keywords.filter { word in !kept.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        if kept + added != subjects {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
            list("dc:subject", "subject", .arrayUnordered, kept + added)
        }
        set("dc:rights[x-default]", copyright, was: previous?.copyright)
        set("dc:title[x-default]", title, was: previous?.title)
        set("dc:description[x-default]", description, was: previous?.description)
        set("photoshop:Credit", credit, was: previous?.credit)
        set("Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiEmailWork", email, was: previous?.email)
        set("Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiUrlWork", website, was: previous?.website)
    }

    /// As an export's IPTC (over what the photo had).
    func iptc(over properties: [String: Any]) -> [String: Any] {
        var properties = properties
        var iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        if let creator, !creator.isEmpty { iptc[kCGImagePropertyIPTCByline as String] = [creator] }
        if let copyright, !copyright.isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright }
        if let credit, !credit.isEmpty { iptc[kCGImagePropertyIPTCCredit as String] = credit }
        if let title, !title.isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = title }
        if let description, !description.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = description }
        if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = keywords }
        var contact: [String: Any] = [:]
        if let email, !email.isEmpty { contact[kCGImagePropertyIPTCContactInfoEmails as String] = email }
        if let website, !website.isEmpty { contact[kCGImagePropertyIPTCContactInfoWebURLs as String] = website }
        if !contact.isEmpty { iptc[kCGImagePropertyIPTCCreatorContactInfo as String] = contact }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary as String] = iptc }
        // Also where Finder and the web look first.
        if let copyright, !copyright.isEmpty {
            var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCopyright as String] = copyright
            if let creator, !creator.isEmpty { tiff[kCGImagePropertyTIFFArtist as String] = creator }
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return properties
    }
}

// MARK: - Editing

/// The fields of a template (or of the chosen photos), as rows of a card.
struct PhotoMetaFields: View {
    @Binding var meta: PhotoMeta
    /// Templates show what the tokens are for.
    var tokens = false
    @State private var keywords = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PhotoMeta.fields, id: \.prompt) { field in
                CardField(label: Text(field.title)) {
                    TextField(field.title, text: Binding(get: { meta[keyPath: field.path] ?? "" },
                                                        set: { meta[keyPath: field.path] = $0.isEmpty ? nil : $0 }),
                              prompt: Text(verbatim: tokens || !field.prompt.contains("{") ? field.prompt : ""))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            CardField(label: Text("Keywords")) {
                TextField("Keywords", text: $keywords, prompt: Text("street, night, {camera}"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onChange(of: keywords) { _, text in
                        meta.keywords = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            }
            if tokens {
                Text("{year} {date} {camera} {serial} {card} {filename} are filled in for each photo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .onAppear { keywords = meta.keywords.joined(separator: ", ") }
    }
}

/// Makes or changes a metadata template.
struct PhotoTemplateSheet: View {
    @State var template: PhotoMetadataTemplate
    let save: (PhotoMetadataTemplate?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Text("Metadata Template").font(Design.Typography.sheetTitle)
            CardField(label: Text("Name")) {
                TextField("Name", text: $template.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            .font(.callout)
            PhotoMetaFields(meta: $template.meta, tokens: true)
            HStack {
                if PhotoMetadataTemplate.saved.contains(where: { $0.id == template.id }) {
                    Button("Delete", role: .destructive) { save(nil); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(template); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
    }
}

/// The Info tab's metadata: the shown photo's fields, changed for every photo chosen.
struct PhotoMetaSection: View {
    let paths: [String]
    let record: PhotoRecord
    @State private var draft = PhotoMeta()
    @State private var catalog = PhotoCatalog.shared

    var body: some View {
        SidebarSection(title: Text("Metadata")) {
            VStack(alignment: .leading, spacing: 8) {
                PhotoMetaFields(meta: $draft)
                    .id(record.meta)
                HStack {
                    Menu("Template") {
                        ForEach(PhotoMetadataTemplate.saved) { template in
                            Button(template.name) { apply { path, meta in
                                PhotoMetadataTemplate.expand(template.meta, file: URL(fileURLWithPath: PhotoCatalog.file(of: path)), card: nil).over(meta)
                            } }
                        }
                    }
                    .fixedSize()
                    .disabled(PhotoMetadataTemplate.saved.isEmpty)
                    .help("Fill in a template’s fields (made when importing)")
                    Spacer()
                    Button(paths.count > 1 ? String(localized: "Apply to \(paths.count)") : String(localized: "Apply")) {
                        // Only what was changed here, on each photo (their other fields stay theirs).
                        let was = record.meta ?? PhotoMeta(), now = draft
                        apply { _, meta in
                            var result = meta ?? PhotoMeta()
                            for field in PhotoMeta.fields where now[keyPath: field.path] != was[keyPath: field.path] {
                                result[keyPath: field.path] = now[keyPath: field.path]
                            }
                            let removed = was.keywords.filter { !now.keywords.contains($0) }
                            let added = now.keywords.filter { word in !result.keywords.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
                            result.keywords = result.keywords.filter { !removed.contains($0) } + added
                            return result
                        }
                    }
                    .disabled(draft == (record.meta ?? PhotoMeta()))
                    .help("Who made the photo and what it is: in its sidecar and in exports")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
        }
        .onAppear { draft = record.meta ?? PhotoMeta() }
        .onChange(of: record.meta) { _, meta in draft = meta ?? PhotoMeta() }
    }

    private func apply(_ make: (String, PhotoMeta?) -> PhotoMeta) {
        catalog.setMeta(Dictionary(uniqueKeysWithValues: paths.map { ($0, make($0, catalog.record($0).meta)) }))
    }
}
