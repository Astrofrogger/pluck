import AppKit
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The PDF next to each copy when an offload is done, for production: what was copied, where
/// to, how long it took, and every file with its picture, size and checksum.
enum OffloadReport {
    static func fileName(_ job: OffloadJob) -> String { "\(job.displayName) Report.pdf" }

    /// Written into every copy that's still connected.
    @MainActor static func write(_ job: OffloadJob) {
        Task {
            let first = job.targets.first { FileManager.default.fileExists(atPath: $0) }
            let pictures = await thumbnails(job, in: first)
            let data = pdf(job, pictures: pictures)
            for target in job.targets where FileManager.default.fileExists(atPath: target) {
                try? data.write(to: URL(fileURLWithPath: target).appendingPathComponent(fileName(job)), options: .atomic)
            }
        }
    }

    /// The report of a finished offload, from the first copy that's connected.
    static func url(_ job: OffloadJob) -> URL? {
        job.targets.map { URL(fileURLWithPath: $0).appendingPathComponent(fileName(job)) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Small pictures of the videos and photos (the first 300), from the copy.
    private static func thumbnails(_ job: OffloadJob, in folder: String?) async -> [String: NSImage] {
        guard let folder else { return [:] }
        var pictures: [String: NSImage] = [:]
        let media = job.files.filter { file in
            guard file.problem == nil, let type = UTType(filenameExtension: (file.path as NSString).pathExtension) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .image)
        }
        for file in media.prefix(300) {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(job.destination(of: file.path))
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 54), scale: 2, representationTypes: .thumbnail)
            if let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                pictures[file.path] = made.nsImage
            }
        }
        return pictures
    }

    // MARK: - The PDF

    @MainActor private static func pdf(_ job: OffloadJob, pictures: [String: NSImage]) -> Data {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ colour: NSColor = .black, after: CGFloat = 4) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style]))
        }
        add(String(localized: "Offload Report"), .systemFont(ofSize: 11, weight: .medium), .gray, after: 2)
        add(job.displayName, .systemFont(ofSize: 22, weight: .bold), after: 14)

        let finished = job.finished ?? .now
        let seconds = max(job.busy ?? finished.timeIntervalSince(job.started), 1)
        let size = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: Int64(Double(job.totalBytes) / seconds), countStyle: .file)
        let problems = job.problems.count
        var facts: [(String, String)] = [
            (String(localized: "Date"), finished.formatted(date: .long, time: .shortened)),
            (String(localized: "Source"), "\(job.sourceVolume) (\(job.source))"),
        ]
        for (target, volume) in zip(job.targets, job.rootVolumes) { facts.append((String(localized: "Copy"), "\(volume) (\(target))")) }
        facts += [
            (String(localized: "Files"), "\(job.files.count) · \(size)"),
            (String(localized: "Time"), Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                + " · " + String(localized: "\(speed)/s")),
            (String(localized: "Checksum"), "xxHash64 · " + String(localized: "every copy read back from the drive")),
            (String(localized: "Result"), problems == 0 ? String(localized: "Every file matches on every drive.")
                : String(localized: "\(problems) files couldn’t be copied.")),
        ]
        let factStyle = NSMutableParagraphStyle()
        factStyle.tabStops = [NSTextTab(textAlignment: .left, location: 90)]
        factStyle.headIndent = 90
        factStyle.paragraphSpacing = 3
        for (label, value) in facts {
            text.append(NSAttributedString(string: label + "\t", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                                .foregroundColor: NSColor.gray, .paragraphStyle: factStyle]))
            let colour: NSColor = label == String(localized: "Result") ? (problems == 0 ? .systemGreen : .systemOrange) : .black
            text.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: colour,
                                                                              .paragraphStyle: factStyle]))
        }
        text.append(NSAttributedString(string: "\n"))

        // Every file: picture, name, size, checksum, result.
        let table = NSTextTable()
        table.numberOfColumns = 5
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let columns: [CGFloat] = [62, width - 62 - 64 - 108 - 22, 64, 108, 22]
        func cell(_ content: NSAttributedString, row: Int, column: Int, header: Bool = false) {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setContentWidth(columns[column], type: .absoluteValueType)
            block.setWidth(3, type: .absoluteValueType, for: .padding)
            block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(NSColor(white: 0.85, alpha: 1), for: .maxY)
            if header { block.backgroundColor = NSColor(white: 0.95, alpha: 1) }
            block.verticalAlignment = .middleAlignment
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.alignment = column == 2 ? .right : .left
            let piece = NSMutableAttributedString(attributedString: content)
            piece.append(NSAttributedString(string: "\n"))
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            text.append(piece)
        }
        func plain(_ string: String, _ font: NSFont = .systemFont(ofSize: 8), _ colour: NSColor = .black) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: colour])
        }
        let headerFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        for (column, title) in ["", String(localized: "File"), String(localized: "Size"), "xxHash64", ""].enumerated() {
            cell(plain(title, headerFont, .gray), row: 0, column: column, header: true)
        }
        for (index, file) in job.files.enumerated() {
            let row = index + 1
            if let picture = pictures[file.path] {
                let attachment = NSTextAttachment()
                attachment.image = picture
                let ratio = picture.size.width > 0 ? picture.size.height / picture.size.width : 0.56
                attachment.bounds = CGRect(x: 0, y: 0, width: 56, height: min(56 * ratio, 40))
                cell(NSAttributedString(attachment: attachment), row: row, column: 0)
            } else {
                cell(plain(""), row: row, column: 0)
            }
            let name = NSMutableAttributedString(attributedString: plain(job.destination(of: file.path)))
            // Renamed so as not to write over another card's file with its name.
            if job.renames?[file.path] != nil { name.append(plain("\n" + String(localized: "On the card: \(file.path)"), .systemFont(ofSize: 7), .gray)) }
            if let problem = file.problem { name.append(plain("\n" + problem, .systemFont(ofSize: 7), .systemOrange)) }
            cell(name, row: row, column: 1)
            cell(plain(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)), row: row, column: 2)
            cell(plain(file.hash ?? "—", .monospacedSystemFont(ofSize: 7.5, weight: .regular)), row: row, column: 3)
            cell(plain(file.problem == nil ? "✓" : "!", .systemFont(ofSize: 9, weight: .bold), file.problem == nil ? .systemGreen : .systemOrange),
                 row: row, column: 4)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        text.append(NSAttributedString(string: "\n"))
        add(String(localized: "Made with Pluck \(version). The checksums are also in the MHL file next to this report."),
            .systemFont(ofSize: 8), .gray)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        view.backgroundColor = .white
        view.appearance = NSAppearance(named: .aqua)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        return data as Data
    }
}

// MARK: - Checking a copy later

/// A copy checked again against its MHL, later (before the card is formatted, or months on):
/// every file read back and compared, what's missing, and what's there that isn't on the list.
struct OffloadCheck: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
    var total: Int64 = 0
    var done: Int64 = 0
    var finished = false
    var matched = 0
    var changed: [String] = []
    var missing: [String] = []
    var extra: [String] = []
    /// Checksums Pluck can't work out (xxh3, xxh128, C4).
    var unchecked = 0
    var problem: String?

    var isGood: Bool { finished && problem == nil && changed.isEmpty && missing.isEmpty }
}

/// The files and checksums in a folder's MHL files: MHL 1.1 next to the files, or ASC MHL 2 in its
/// ascmhl folder.
enum MHL {
    struct Item {
        var path: String
        var size: Int64?
        var kind: String
        var hash: String
    }

    static func items(in folder: URL) -> [Item]? {
        let manager = FileManager.default
        var lists: [URL] = []
        let ascmhl = folder.appendingPathComponent("ascmhl")
        for place in [folder, ascmhl] {
            let found = (try? manager.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? []
            lists += found.filter { $0.pathExtension.lowercased() == "mhl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !lists.isEmpty else { return nil }
        var byPath: [String: Item] = [:]
        for list in lists {
            let reader = Reader()
            let parser = XMLParser(contentsOf: list)
            parser?.delegate = reader
            parser?.parse()
            for item in reader.items { byPath[item.path] = item }
        }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The hash kinds Pluck can check, in the order it prefers them.
    private static let kinds = ["xxhash64be", "xxhash64", "xxh64", "md5", "sha1", "xxh3", "xxh128", "c4"]

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var inHash = false
        private var fields: [String: String] = [:]
        private var size: Int64?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "hash" { inHash = true; fields = [:]; size = nil }
            if inHash, name == "path", let value = attributes["size"] { size = Int64(value) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "hash", inHash {
                inHash = false
                let path = fields["file"] ?? fields["path"]
                if let path, let kind = MHL.kinds.first(where: { fields[$0] != nil }), let hash = fields[kind] {
                    items.append(Item(path: path, size: size ?? fields["size"].flatMap { Int64($0) }, kind: kind, hash: hash.lowercased()))
                }
            } else if inHash, fields[name] == nil {
                fields[name] = value
            }
            text = ""
        }
    }

    /// A file's checksum of this kind, or nil when Pluck can't work it out.
    static func hash(_ path: String, kind: String, progress: (Int64) -> Void, stopped: () -> Bool) -> String? {
        guard ["xxhash64be", "xxhash64", "xxh64", "md5", "sha1"].contains(kind), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var xxh = XXH64(), md5 = Insecure.MD5(), sha1 = Insecure.SHA1()
        while !stopped(), let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty {
            switch kind {
            case "md5": md5.update(data: data)
            case "sha1": sha1.update(data: data)
            default: data.withUnsafeBytes { xxh.update($0) }
            }
            progress(Int64(data.count))
        }
        switch kind {
        case "md5": return md5.finalize().map { String(format: "%02x", $0) }.joined()
        case "sha1": return sha1.finalize().map { String(format: "%02x", $0) }.joined()
        default: return String(format: "%016llx", xxh.digest())
        }
    }
}
