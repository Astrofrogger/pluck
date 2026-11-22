import AppKit
import CoreText
import Foundation

/// Sign-off sheets (wf-deliver): every approval of a link, or of a client's projects, as a PDF and a CSV (asset, version,
/// who, when, note). Each row carries the approval proof's record hash (DeliverProof.record) over the same fields, made
/// with "Served by" `servedBy` and "Generated" = the approval's time, so the CSV's columns are enough to check it.
@MainActor
enum DeliverSignOff {
    static let servedBy = "Pluck sign-off"

    struct Row: Hashable {
        var project, asset, version, decision, name, email, time, link, note, file, sha256, hashOf, linkID, approval, record: String
    }

    /// A link's approvals, oldest first.
    static func approvals(link: UUID, store: DeliverStore) -> [Deliver.Approval] {
        guard let project = store.link(link)?.project else { return [] }
        return store.approvals(project).filter { $0.link == link }.sorted { $0.created < $1.created }
    }

    /// Every approval in the projects of a client (Archive's client, from each project's NAS folder), oldest first.
    static func approvals(client: String, store: DeliverStore) -> [Deliver.Approval] {
        store.projects.filter { DeliverProjectFile.client($0.id, store: store) == client }
            .flatMap { store.approvals($0.id) }.sorted { $0.created < $1.created }
    }

    static func rows(_ approvals: [Deliver.Approval], store: DeliverStore) -> [Row] {
        approvals.map { approval in
            let fields = DeliverProof.fields(approval, store: store, servedBy: servedBy, generated: approval.created)
            let value = { (key: String) in fields.first { $0.key == key }?.value ?? "" }
            return Row(project: value("project"), asset: value("asset"), version: value("version"), decision: value("decision"), name: value("name"),
                       email: value("email"), time: value("time"), link: value("linkTitle"), note: note(approval, store: store), file: value("file"),
                       sha256: value("sha256"), hashOf: value("hashOf"), linkID: value("link"), approval: approval.id.uuidString, record: DeliverProof.record(fields))
        }
    }

    /// The approver's own comment on that version written around the approval (10 minutes before to 2 after), if any.
    static func note(_ approval: Deliver.Approval, store: DeliverStore) -> String {
        store.comments(approval.asset, version: approval.version)
            .filter { $0.author == approval.author && $0.link == approval.link && !$0.isInternal
                && (-600...120).contains($0.created.timeIntervalSince(approval.created)) }
            .max { $0.created < $1.created }.map { String($0.text.prefix(300)) } ?? ""
    }

    /// Every field the record hashes is a column (with "Served by" and "Generated" as said above), so a row can be checked.
    static let columns = ["Project", "Asset", "Version", "Decision", "Name", "Email", "Time (UTC)", "Link", "Note", "File", "SHA-256", "Hash of", "Link id", "Approval id", "Record"]

    nonisolated static func csv(_ rows: [Row]) -> String {
        func cell(_ text: String) -> String {
            // (A leading = + - @, tab or return would run as a formula in a spreadsheet.)
            let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
            return safe.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : safe
        }
        let lines = [columns.map(cell)] + rows.map { [$0.project, $0.asset, $0.version, $0.decision, $0.name, $0.email, $0.time, $0.link, $0.note,
                                                       $0.file, $0.sha256, $0.hashOf, $0.linkID, $0.approval, $0.record].map(cell) }
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// A4 landscape pages: a title, then one row per approval with its record hash under it.
    static func pdf(title: String, rows: [Row], generated: Date = .now) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "Sign-off – \(title)"] as CFDictionary) else { return nil }
        let columns: [(String, CGFloat, KeyPath<Row, String>)] = [("Asset", 40, \.asset), ("Version", 230, \.version), ("Decision", 285, \.decision),
                                                                    ("Name", 405, \.name), ("Time (UTC)", 535, \.time), ("Note", 665, \.note)]
        var y: CGFloat = 0, page = 0
        func line(_ text: String, x: CGFloat, size: CGFloat, bold: Bool = false, mono: Bool = false, colour: NSColor = .black, width: CGFloat = 760) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            var ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour]))
            let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font]))
            if let cut = CTLineCreateTruncatedLine(ctLine, Double(width), .end, dots) { ctLine = cut }
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, context)
        }
        func newPage() {
            if page > 0 { context.endPDFPage() }
            page += 1
            context.beginPDFPage(nil)
            y = 595 - 50
            if page == 1 {
                line("Sign-off", x: 40, size: 22, bold: true)
                y -= 22
                line(title, x: 40, size: 12, colour: .darkGray)
                y -= 16
                line("\(rows.count) approval\(rows.count == 1 ? "" : "s") · generated \(DeliverProof.iso(generated))", x: 40, size: 9, colour: .darkGray)
                y -= 28
            }
            for (name, x, _) in columns { line(name, x: x, size: 9, colour: .darkGray) }
            y -= 18
        }
        newPage()
        for row in rows {
            if y < 60 { newPage() }
            for (index, (_, x, key)) in columns.enumerated() {
                let next = index + 1 < columns.count ? columns[index + 1].1 : 802
                line(row[keyPath: key], x: x, size: 10, width: next - x - 8)
            }
            y -= 13
            line("Record \(row.record)" + (row.sha256.isEmpty ? "" : " · SHA-256 \(row.sha256)"), x: 40, size: 7, mono: true, colour: .gray)
            y -= 20
        }
        y = 30
        line("Each record is the base64url SHA-256 of the approval proof's fields (Served by “\(servedBy)”, Generated = its time).", x: 40, size: 7, colour: .gray)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Writes "Sign-off – <title>.pdf" and ".csv" into a folder; their URLs.
    @discardableResult
    /// `exclusive`: never over a file already there (Archive a share, on the NAS).
    static func write(title: String, approvals: [Deliver.Approval], into folder: URL, store: DeliverStore, exclusive: Bool = false) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rows = rows(approvals, store: store)
        let name = "Sign-off – " + DeliverServer.safeName(title)
        let pdfURL = folder.appendingPathComponent(name + ".pdf"), csvURL = folder.appendingPathComponent(name + ".csv")
        guard let pdf = pdf(title: title, rows: rows) else { throw Deliver.Failure("internal") }
        let options: Data.WritingOptions = exclusive ? .withoutOverwriting : .atomic
        try pdf.write(to: pdfURL, options: options)
        try Data(csv(rows).utf8).write(to: csvURL, options: options)
        return [pdfURL, csvURL]
    }

    /// Asks where, then writes the sheet there (the PDF's name; the CSV beside it) and shows it in the Finder.
    static func save(title: String, approvals: [Deliver.Approval], store: DeliverStore = .shared) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "The sign-off sheet goes in this folder as a PDF and a CSV.")
        guard panel.runModal() == .OK, let folder = panel.url, let made = try? write(title: title, approvals: approvals, into: folder, store: store) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(made)
    }
}
