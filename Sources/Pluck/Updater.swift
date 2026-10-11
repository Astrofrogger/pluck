import CryptoKit
import Foundation
import Observation

/// Keeps a private copy of the official yt-dlp macOS build in Application Support and updates it
/// from GitHub releases. Homebrew's yt-dlp can't update itself, so this is what makes
/// "always the latest version" possible.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle, checking, downloading, upToDate, updated(String), failed(String)
    }

    var status: Status = .idle {
        didSet { onStatusChange?() }
    }
    @ObservationIgnored var onStatusChange: (() -> Void)?
    var installedVersion: String?
    /// While downloading: bytes so far and the total (0 if unknown).
    var progress: (done: Int64, total: Int64)?
    var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updaterLastChecked") }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var work: Task<Void, Never>?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pluck/bin", isDirectory: true)
    }()

    static var binaryURL: URL { directory.appendingPathComponent("yt-dlp") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binaryURL.path) }

    private var useNightly: Bool { UserDefaults.standard.bool(forKey: Prefs.nightly) }
    private var repo: String { useNightly ? "yt-dlp/yt-dlp-nightly-builds" : "yt-dlp/yt-dlp" }

    init() {
        lastChecked = UserDefaults.standard.object(forKey: "updaterLastChecked") as? Date
        installedVersion = UserDefaults.standard.string(forKey: "updaterVersion")
    }

    /// Checks on launch and then daily while the app is open.
    func startAutomaticChecks() {
        guard UserDefaults.standard.bool(forKey: Prefs.autoUpdate) else {
            timer?.invalidate()
            timer = nil
            return
        }
        Task { await check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    var isBusy: Bool { status == .checking || status == .downloading }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// "yt-dlp: 34% (12 of 37 MB)", for showing a download as it goes.
    static func progressText(_ tool: String, done: Int64, total: Int64) -> String {
        let got = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        guard total > 0 else { return String(localized: "\(tool): \(got)") }
        let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return String(localized: "\(tool): \(Int(Double(done) / Double(total) * 100))% (\(got) of \(all))")
    }

    /// Stops a check or download (a half-done download carries on next time).
    func stop() {
        work?.cancel()
    }

    func check(force: Bool = false) async {
        guard !isBusy else { return }
        let task = Task { await run(force: force) }
        work = task
        await task.value
        work = nil
    }

    private func run(force: Bool) async {
        status = .checking
        progress = nil
        defer { progress = nil }
        do {
            let latest = try await latestRelease()
            lastChecked = .now
            if !force, Self.isInstalled, installedVersion == latest.tag {
                status = .upToDate
                return
            }
            status = .downloading
            try await install(latest)
            installedVersion = latest.tag
            UserDefaults.standard.set(latest.tag, forKey: "updaterVersion")
            status = .updated(latest.tag)
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private struct Release {
        let tag: String
        let binary: URL
        let checksums: URL
    }

    private enum Failure: LocalizedError {
        case noAsset, checksumMissing, checksumMismatch, badBinary

        var errorDescription: String? {
            switch self {
            case .noAsset: String(localized: "The latest release has no macOS build.")
            case .checksumMissing: String(localized: "The release has no checksum for the macOS build.")
            case .checksumMismatch: String(localized: "The download didn’t match its published checksum, so it was discarded.")
            case .badBinary: String(localized: "The downloaded yt-dlp didn’t run.")
            }
        }
    }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { throw Failure.noAsset }
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init)
        }
        guard let binary = asset("yt-dlp_macos"), TrustedHosts.isAllowed(binary, hosts: ["github.com"])
        else { throw Failure.noAsset }
        guard let sums = asset("SHA2-256SUMS"), TrustedHosts.isAllowed(sums, hosts: ["github.com"])
        else { throw Failure.checksumMissing }
        return Release(tag: tag, binary: binary, checksums: sums)
    }

    private func install(_ release: Release) async throws {
        let (sumsData, _) = try await URLSession.shared.data(from: release.checksums)
        let tempFile = try await ToolDownloads.download(release.binary) { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }

        // SHA2-256SUMS lines look like "<hex>  yt-dlp_macos".
        let expected = String(decoding: sumsData, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .first { $0.count == 2 && $0[1] == "yt-dlp_macos" }?[0]
        guard let expected else { throw Failure.checksumMissing }

        let digest = SHA256.hash(data: try Data(contentsOf: tempFile, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            try? FileManager.default.removeItem(at: tempFile)
            throw Failure.checksumMismatch
        }

        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let staged = Self.directory.appendingPathComponent("yt-dlp.new")
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: tempFile, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)

        guard try await ToolDownloads.runs(staged.path, ["--version"], name: "yt-dlp") else {
            try? fm.removeItem(at: staged)
            throw Failure.badBinary
        }
        if fm.fileExists(atPath: Self.binaryURL.path) {
            _ = try fm.replaceItemAt(Self.binaryURL, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: Self.binaryURL)
        }
    }
}

/// Downloads and checks for Pluck's tools (yt-dlp, ffmpeg, Deno), made for slow and flaky
/// connections: progress as it goes, a stalled download gives up instead of hanging, and an
/// interrupted one (a stall, Stop, quitting Pluck) carries on where it stopped next time.
enum ToolDownloads {
    enum Failure: LocalizedError {
        case stalled, tooSlow, didntStart(String)
        var errorDescription: String? {
            switch self {
            case .stalled: String(localized: "The download stopped (no data for 30 seconds). Check the internet connection and try again; it carries on where it stopped.")
            case .tooSlow: String(localized: "The download took over half an hour. Try again to carry on where it stopped, or try on a faster connection.")
            case .didntStart(let tool): String(localized: "The downloaded \(tool) didn’t start within a minute. Security software may be holding it back.")
            }
        }
    }

    /// Where half-done downloads wait to be carried on.
    private static func resumeFile(for url: URL) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key)
    }

    /// Downloads `url` to a temporary file; `progress` gets bytes so far and the total (0 if unknown).
    /// `limit` caps the whole download (half an hour for the tools; longer for big models).
    static func download(_ url: URL, limit: TimeInterval = 30 * 60, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let resume = resumeFile(for: url)
        let saved = try? Data(contentsOf: resume)
        try? FileManager.default.removeItem(at: resume)
        do {
            return try await attempt(url, resumeData: saved, limit: limit, progress: progress)
        } catch let error as URLError where saved != nil && error.code != .timedOut && error.code != .cancelled {
            // The server can't carry on (the file changed): from the start.
            return try await attempt(url, resumeData: nil, limit: limit, progress: progress)
        }
    }

    private static func attempt(_ url: URL, resumeData: Data?, limit: TimeInterval,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let began = Date.now
        let delegate = Delegate(report: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = limit
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.finish = { continuation.resume(with: $0) }
                    task.resume()
                }
            } onCancel: {
                task.cancel(byProducingResumeData: { data in
                    if let data { try? data.write(to: resumeFile(for: url)) }
                })
            }
        } catch let error as URLError {
            if let data = error.downloadTaskResumeData { try? data.write(to: resumeFile(for: url)) }
            switch error.code {
            // The whole download's limit, or a stretch without any data.
            case .timedOut where Date.now.timeIntervalSince(began) > limit - 60: throw Failure.tooSlow
            case .timedOut: throw Failure.stalled
            case .cancelled: throw CancellationError()
            default: throw error
            }
        }
    }

    /// Runs a downloaded tool once to see it works, giving it a minute.
    static func runs(_ path: String, _ arguments: [String], name: String) async throws -> Bool {
        let result = await Task.detached { () -> Bool? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let deadline = Date.now.addingTimeInterval(60)
            while process.isRunning, Date.now < deadline { usleep(100_000) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            return process.terminationStatus == 0
        }.value
        guard let result else { throw Failure.didntStart(name) }
        return result
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64, Int64) -> Void
        var finish: ((Result<URL, Error>) -> Void)?
        private let lock = NSLock()
        init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

        private func done(_ result: Result<URL, Error>) {
            lock.lock()
            let finish = self.finish
            self.finish = nil
            lock.unlock()
            finish?(result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                        expectedTotalBytes: Int64) {
            report(fileOffset, max(expectedTotalBytes, 0))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file only lasts until this returns: moved somewhere that stays.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("PluckDownload-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                done(.success(kept))
            } catch {
                done(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { done(.failure(error)) }
        }
    }
}
