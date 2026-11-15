import AppKit
import CoreText
import CryptoKit
import Foundation

/// Approval proofs (§13.8): one A4 page in English, made with CoreText (full Unicode), cached in Review/proofs/<id>.pdf.
/// Its last line, "Record", is the base64url SHA-256 of the canonical JSON of the fields above it (keys sorted,
/// UTF-8, no spaces), so anyone can check the PDF against the server's record.
@MainActor
enum DeliverProof {
    static func folder(_ store: DeliverStore) -> URL { store.root.appendingPathComponent("proofs", isDirectory: true) }

    static func fileName(_ approval: Deliver.Approval, asset: Deliver.Asset) -> String {
        "Approval – \(asset.name) v\(approval.versionNumber ?? asset.versions.first { $0.id == approval.version }?.number ?? 1).pdf"
    }

    /// The record's fields (the PDF shows these, in this order).
    static func fields(_ approval: Deliver.Approval, store: DeliverStore, servedBy: String, generated: Date) -> [(key: String, label: String, value: String)] {
        let found = store.find(approval.asset)
        let asset = found?.asset, project = found.flatMap { store.project($0.project) }
        let link = approval.link.flatMap(store.link)
        let number = approval.versionNumber ?? asset?.versions.first { $0.id == approval.version }?.number ?? 1
        var rows: [(String, String, String)] = [
            ("project", "Project", project?.name ?? ""),
            ("asset", "Asset", asset?.name ?? ""),
            ("version", "Version", "v\(number)"),
            ("file", "File", approval.file ?? ""),
            ("sha256", "SHA-256", approval.sha256 ?? ""),
            ("hashOf", "Hash of", approval.hashOf ?? "original"),
            ("decision", "Decision", approval.decision == .approve ? "Approved" : "Changes requested"),
            ("name", "Name", approval.author),
        ]
        if let email = approval.email, !email.isEmpty { rows.append(("email", "Email", email)) }
        rows += [
            ("time", "Time", iso(approval.created)),
            ("linkTitle", "Link", link?.title ?? ""),
            ("link", "Link id", approval.link?.uuidString ?? ""),
            ("approval", "Approval id", approval.id.uuidString),
            ("servedBy", "Served by", servedBy),
            ("generated", "Generated", iso(generated)),
        ]
        return rows.map { (key: $0.0, label: $0.1, value: $0.2) }
    }

    nonisolated static func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(identifier: "UTC")
        return format.string(from: date)
    }

    /// base64url SHA-256 of the canonical JSON (keys sorted, no spaces, slashes as they are).
    nonisolated static func record(_ fields: [(key: String, label: String, value: String)]) -> String {
        // The host's canonical form (proof.rs): version as a number, decision as its wire value.
        let object = Dictionary(fields.map { field -> (String, Any) in
            switch field.key {
            case "version": (field.key, Int(field.value.dropFirst()) ?? 1)
            case "decision": (field.key, field.value == "Approved" ? "approve" : "changes")
            default: (field.key, field.value)
            }
        }) { a, _ in a }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return DeliverKeys.base64url(Data(SHA256.hash(data: data)))
    }

    /// The cached PDF, made once. A version without its hash yet: `notReady` while it's made.
    static func file(for approval: Deliver.Approval, store: DeliverStore, servedBy: String) throws -> URL {
        let url = folder(store).appendingPathComponent("\(approval.id.uuidString).pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var approval = approval
        if approval.sha256 == nil, let version = store.find(approval.asset)?.asset.versions.first(where: { $0.id == approval.version }), let sha = version.sha256 {
            approval.sha256 = sha
            approval.hashOf = "original"
        }
        guard approval.sha256 != nil else {
            hashSoon(asset: approval.asset, version: approval.version, store: store)
            throw Deliver.Failure("notReady", progress: 0)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let pdf = make(approval, store: store, servedBy: servedBy) else { throw Deliver.Failure("internal") }
        try pdf.write(to: url, options: .atomic)
        return url
    }

    static func make(_ approval: Deliver.Approval, store: DeliverStore, servedBy: String, generated: Date = .now) -> Data? {
        let rows = fields(approval, store: store, servedBy: servedBy, generated: generated)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextTitle as String: fileName(approval, asset: store.find(approval.asset)?.asset ?? .init(name: "", kind: .video, versions: [.init(number: 1, path: "", size: 0)])),
                                       kCGPDFContextSubject as String: record(rows)] as CFDictionary) else { return nil }
        context.beginPDFPage(nil)
        var y: CGFloat = 842 - 72
        func line(_ text: String, size: CGFloat, bold: Bool = false, mono: Bool = false, x: CGFloat = 60, colour: NSColor = .black) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
            let ctLine = CTLineCreateWithAttributedString(string)
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, context)
        }
        line(approval.decision == .approve ? "Approval" : "Changes requested", size: 24, bold: true)
        y -= 44
        for row in rows {
            line(row.label, size: 10, colour: .darkGray)
            if row.key == "sha256", row.value.count == 64 {
                line(String(row.value.prefix(32)), size: 10, mono: true, x: 160)
                y -= 14
                line(String(row.value.suffix(32)) + (approval.hashOf == "copy" ? "  of the review copy" : ""), size: 10, mono: true, x: 160)
            } else if row.key != "hashOf" {
                line(row.value, size: 11, mono: ["link", "approval", "time", "generated"].contains(row.key), x: 160)
            } else {
                y += 22   // (shown with the hash)
            }
            y -= 22
        }
        y -= 12
        line("Record", size: 10, colour: .darkGray)
        line(record(rows), size: 9, mono: true, x: 160)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Hashes

    private static var hashing: Set<UUID> = []

    /// The original's SHA-256 (16 MiB reads), or the review copy's when there's no original here (`hashOf: copy`),
    /// into the version and its approvals still without one.
    static func hashSoon(asset: UUID, version: UUID, store: DeliverStore) {
        guard !hashing.contains(version), let (project, found) = store.find(asset), let made = found.versions.first(where: { $0.id == version }) else { return }
        hashing.insert(version)
        let original = store.original(made)
        let copy = store.copies(version).appendingPathComponent("1080/media.m4s")
        Task {
            defer { hashing.remove(version) }
            var sha: String?, of = "original"
            if let original { sha = await DeliverUploads.sha256(original) }
            if sha == nil, FileManager.default.fileExists(atPath: copy.path) { sha = await DeliverUploads.sha256(copy); of = "copy" }
            guard let sha else { return }
            if of == "original" { store.update(version: version, of: asset) { $0.sha256 = sha } }
            for approval in store.approvals(project) where approval.version == version && approval.sha256 == nil {
                store.update(approval: approval.id, in: project) { $0.sha256 = sha; $0.hashOf = of }
            }
        }
    }
}
