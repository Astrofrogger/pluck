import AppKit

/// Edit Anywhere's connection log: the helpers' reports and the private network's state changes, so
/// the owner can send it when connecting goes wrong. Private and small: the last ~500 lines in
/// Edit Anywhere/connection.log, node ids cut to their first 8 characters, long lines cut.
enum ConnectionLog {
    static let keep = 500
    nonisolated(unsafe) static var file = PrivateNetwork.folder.appendingPathComponent("connection.log")
    private static let queue = DispatchQueue(label: "pluck.connection-log")

    /// Adds a line (in the background); `tag` says whose ("home", "office").
    static func add(_ tag: String, _ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(tag) \(redact(text))\n"
        queue.async { append(line) }
    }

    /// Waits until earlier lines are written (tests, copying).
    static func flush() { queue.sync {} }

    static func text() -> String {
        flush()
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    @MainActor static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text().isEmpty ? "(empty)" : text(), forType: .string)
    }

    /// Node ids (64 hex) cut to 8, and no line over 400 characters.
    static func redact(_ text: String) -> String {
        let cut = text.replacing(#/[0-9a-fA-F]{64}/#) { String($0.output.prefix(8)) + "…" }
        return String(cut.replacingOccurrences(of: "\n", with: " ").prefix(400))
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            fm.createFile(atPath: file.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
        // Rotated: past 1.2× the lines kept (or 1 MB), only the last `keep` stay.
        guard let data = try? Data(contentsOf: file) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > keep * 6 / 5 || data.count > 1_000_000 else { return }
        let kept = lines.suffix(keep).joined(separator: [0x0A]) + [0x0A]
        try? Data(kept).write(to: file, options: .atomic)
    }
}
