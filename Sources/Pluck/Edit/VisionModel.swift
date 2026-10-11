import CryptoKit
import Foundation

/// An open vision-language model (Qwen) for describing shots with an editor's eye, sharper than
/// Apple's on-device model. It runs on this Mac's GPU in a small helper (pluck-vision, built with
/// MLX for Apple silicon), so nothing is uploaded. The model isn't part of the app: it's
/// downloaded once, from a pinned revision, and its files are checked.
enum VisionModel {
    struct Choice: Sendable, Identifiable, Hashable {
        var name: String
        var repository: String
        var revision: String
        /// Download size, and the memory the Mac needs to run it alongside everything else.
        var size: Int64
        var memory: Int64
        var id: String { repository }
        var folder: URL { VisionModel.models.appendingPathComponent(repository.split(separator: "/").last.map(String.init) ?? name, isDirectory: true) }
    }

    /// Best first: unless the user picks one, the first this Mac has room for is used. All are
    /// open (Apache 2.0) and run in 4-bit.
    static let choices: [Choice] = [
        Choice(name: "Qwen3.8 27B", repository: "mlx-community/Qwen3.8-27B-4bit",
               revision: "10c35caafbb80f7dc6a7a432cdd11af10a6d4818", size: 16_081_490_933, memory: 32 << 30),
        Choice(name: "Qwen3.6 35B-A3B", repository: "mlx-community/Qwen3.6-35B-A3B-4bit",
               revision: "38740b847e4cb78f352aba30aa41c76e08e6eb46", size: 20_429_167_693, memory: 32 << 30),
        Choice(name: "Gemma 4 26B-A4B", repository: "mlx-community/gemma-4-26b-a4b-it-4bit",
               revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d", size: 15_373_587_005, memory: 32 << 30),
        Choice(name: "Qwen3.5 9B", repository: "mlx-community/Qwen3.5-9B-MLX-4bit",
               revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631", size: 5_977_074_591, memory: 16 << 30),
        Choice(name: "Qwen3.5 4B", repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
               revision: "32f3e8ecf65426fc3306969496342d504bfa13f3", size: 3_061_131_350, memory: 8 << 30),
    ]

    /// What each one is good at, for the menu in Settings.
    static func detail(_ choice: Choice) -> String {
        switch choice.repository {
        case choices[0].repository: String(localized: "The sharpest descriptions, the slowest (about 5 seconds a shot).")
        case choices[1].repository: String(localized: "Nearly as sharp and about four times quicker.")
        case choices[2].repository: String(localized: "Google’s model: nearly as sharp and about four times quicker.")
        case choices[3].repository: String(localized: "Smaller, for Macs with 16 GB of memory.")
        default: String(localized: "Smallest, for Macs with 8 GB of memory. Less precise.")
        }
    }

    static func fits(_ choice: Choice) -> Bool { ProcessInfo.processInfo.physicalMemory >= UInt64(choice.memory) }

    static var models: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Models", isDirectory: true)
    }

    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pluck-vision")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The model for this Mac (nil on Intel Macs, without the helper, or with too little memory).
    static var best: Choice? {
        guard Stems.isAppleSilicon, helper != nil else { return nil }
        return choices.first(where: fits)
    }

    /// The one picked in Settings (if it fits this Mac), otherwise the best.
    static var selected: Choice? {
        guard let best else { return nil }
        let picked = UserDefaults.standard.string(forKey: Prefs.visionModel)
        return choices.first { $0.repository == picked && fits($0) } ?? best
    }

    static var unavailableReason: String? {
        guard Stems.isAppleSilicon else { return String(localized: "Needs a Mac with Apple silicon.") }
        guard helper != nil else { return String(localized: "Not part of this build of Pluck.") }
        return best == nil ? String(localized: "Needs a Mac with 8 GB of memory or more.") : nil
    }

    static func isInstalled(_ choice: Choice) -> Bool {
        FileManager.default.fileExists(atPath: choice.folder.appendingPathComponent(".complete").path)
    }

    /// The installed model Find Shots and Derush use (the user can turn it off in Settings).
    static var ready: Choice? {
        guard UserDefaults.standard.object(forKey: Prefs.visionModelEnabled) as? Bool ?? true,
              let selected, isInstalled(selected) else { return nil }
        return selected
    }

    static func remove(_ choice: Choice) {
        try? FileManager.default.removeItem(at: choice.folder)
    }

    enum Failure: LocalizedError {
        case download, checksum, helper(String)
        var errorDescription: String? {
            switch self {
            case .download: String(localized: "The model couldn’t be downloaded. Check your internet connection and try again.")
            case .checksum: String(localized: "A downloaded model file didn’t match its published checksum, so it was discarded.")
            case .helper(let detail): String(localized: "The vision model couldn’t run: \(detail)")
            }
        }
    }

    private struct RemoteFile: Decodable {
        struct LFS: Decodable { var oid: String }
        var type: String
        var path: String
        var size: Int64?
        var lfs: LFS?
    }

    /// Downloads the model into place (a temporary folder first, so a half download never counts
    /// as installed; files already there from an interrupted download are kept). `progress` gets 0…1.
    static func install(_ choice: Choice, progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled(choice) { return }
        guard let listURL = URL(string: "https://huggingface.co/api/models/\(choice.repository)/tree/\(choice.revision)") else { throw Failure.download }
        let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
        guard (listResponse as? HTTPURLResponse)?.statusCode == 200,
              let files = try? JSONDecoder().decode([RemoteFile].self, from: listData).filter({ $0.type == "file" && !$0.path.hasPrefix(".") })
        else { throw Failure.download }
        let staging = models.appendingPathComponent(".download-" + choice.folder.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Double(files.compactMap(\.size).reduce(0, +))
        var done = 0.0
        for file in files {
            let target = staging.appendingPathComponent(file.path)
            let size = Double(file.size ?? 0)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
               (attributes[.size] as? Int64) == file.size {
                done += size
                progress(done / max(total, 1))
                continue
            }
            guard let url = URL(string: "https://huggingface.co/\(choice.repository)/resolve/\(choice.revision)/\(file.path)") else { throw Failure.download }
            let base = done
            // Progress as it goes, and a file interrupted halfway carries on next time.
            let temp: URL
            do {
                temp = try await ToolDownloads.download(url, limit: 24 * 3600) { written, _ in
                    progress(min((base + Double(written)) / max(total, 1), 1))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.download
            }
            // A wrong answer from the server (an error page) is caught by the size and checksum.
            if let expected = file.size,
               let got = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value,
               got != expected {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.download
            }
            if let expected = file.lfs?.oid, try sha256(of: temp) != expected {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.checksum
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            done += size
            progress(done / max(total, 1))
        }
        FileManager.default.createFile(atPath: staging.appendingPathComponent(".complete").path, contents: Data(choice.revision.utf8))
        try? FileManager.default.removeItem(at: choice.folder)
        try FileManager.default.moveItem(at: staging, to: choice.folder)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The running helper: started on the first picture, kept while pictures keep coming, and
/// stopped after a minute without any (the model holds a lot of memory).
actor VisionRunner {
    static let shared = VisionRunner()

    private var process: Process?
    private var input: FileHandle?
    private var lines: LineReader?
    private var running: VisionModel.Choice?
    private var lastUse = Date.distantPast
    /// One picture at a time (Find Shots and Derush can both ask).
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Reads the helper's answers line by line.
    private final class LineReader: @unchecked Sendable {
        private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
        init(_ handle: FileHandle) { iterator = handle.bytes.lines.makeAsyncIterator() }
        func next() async throws -> String? { try await iterator.next() }
    }

    private struct Answer: Decodable {
        var ready: Bool?
        var text: String?
        var error: String?
    }

    /// The model's answer about one picture (a JPEG or PNG file).
    func describe(_ image: URL, instructions: String, prompt: String, maxTokens: Int = 220) async throws -> String {
        guard let choice = VisionModel.ready, let helper = VisionModel.helper else { throw VisionModel.Failure.helper("not installed") }
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
        if process?.isRunning != true || running?.repository != choice.repository {
            try await start(helper, choice)
        }
        lastUse = .now
        let request: [String: Any] = ["image": image.path, "prompt": prompt, "instructions": instructions, "maxTokens": maxTokens]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try input?.write(contentsOf: data)
        let answer = try await next()
        if let error = answer.error { throw VisionModel.Failure.helper(error) }
        scheduleStop()
        return answer.text ?? ""
    }

    private func start(_ helper: URL, _ choice: VisionModel.Choice) async throws {
        stop()
        let process = Process()
        process.executableURL = helper
        process.arguments = [choice.folder.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        lines = LineReader(stdout.fileHandleForReading)
        running = choice
        let first = try await next()
        guard first.ready == true else {
            stop()
            throw VisionModel.Failure.helper(first.error ?? "didn’t start")
        }
    }

    private func next() async throws -> Answer {
        while let line = try await lines?.next() {
            if let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) { return answer }
        }
        stop()
        throw VisionModel.Failure.helper("stopped")
    }

    private func scheduleStop() {
        Task {
            try? await Task.sleep(for: .seconds(60))
            if Date.now.timeIntervalSince(lastUse) >= 59 { stop() }
        }
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        lines = nil
        running = nil
    }
}
