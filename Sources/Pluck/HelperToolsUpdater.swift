import CryptoKit
import Foundation
import Observation

/// Keeps private copies of the helper tools yt-dlp relies on, next to Pluck's yt-dlp:
/// - ffmpeg + ffprobe from Martin Riedl's signed static builds (https://ffmpeg.martin-riedl.de),
///   for merging video and converting audio;
/// - Deno from its official GitHub releases, which yt-dlp needs to solve YouTube's JavaScript checks.
/// yt-dlp finds all of them through PATH.
@MainActor
@Observable
final class HelperToolsUpdater {
    var status: Updater.Status = .idle {
        didSet { onStatusChange?() }
    }
    @ObservationIgnored var onStatusChange: (() -> Void)?
    var ffmpegVersion: String? {
        didSet { UserDefaults.standard.set(ffmpegVersion, forKey: "ffmpegVersion") }
    }
    var denoVersion: String? {
        didSet { UserDefaults.standard.set(denoVersion, forKey: "denoVersion") }
    }

    @ObservationIgnored private var timer: Timer?

    static func path(_ tool: String) -> URL { Updater.directory.appendingPathComponent(tool) }
    static func isInstalled(_ tool: String) -> Bool { FileManager.default.isExecutableFile(atPath: path(tool).path) }
    static var ffmpegInstalled: Bool { isInstalled("ffmpeg") && isInstalled("ffprobe") }

    /// Developer ID teams that sign each tool; anything else is rejected.
    private static let signingTeams = ["ffmpeg": "KU3N25YGLU", "ffprobe": "KU3N25YGLU", "deno": "2H4KBF436B"]

    #if arch(arm64)
    private static let ffmpegArch = "arm64", denoTarget = "aarch64-apple-darwin"
    #else
    private static let ffmpegArch = "amd64", denoTarget = "x86_64-apple-darwin"
    #endif

    init() {
        ffmpegVersion = UserDefaults.standard.string(forKey: "ffmpegVersion")
        denoVersion = UserDefaults.standard.string(forKey: "denoVersion")
    }

    var isBusy: Bool { status == .checking || status == .downloading }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    func startAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard UserDefaults.standard.bool(forKey: Prefs.autoUpdate) else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check(force: Bool = false) async {
        guard !isBusy else { return }
        status = .checking
        var updated: [String] = []
        var errors: [String] = []

        do {
            if try await updateFFmpeg(force: force) { updated.append("ffmpeg \(ffmpegVersion ?? "")") }
        } catch {
            errors.append("ffmpeg: \(error.localizedDescription)")
        }
        do {
            if try await updateDeno(force: force) { updated.append("Deno \(denoVersion ?? "")") }
        } catch {
            errors.append("Deno: \(error.localizedDescription)")
        }

        if !errors.isEmpty {
            status = .failed(errors.joined(separator: "\n"))
        } else if !updated.isEmpty {
            status = .updated(updated.joined(separator: ", "))
        } else {
            status = .upToDate
        }
    }

    // MARK: - ffmpeg

    private final class StopRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Returns true if it installed something.
    private func updateFFmpeg(force: Bool) async throws -> Bool {
        // The "latest" link redirects to a versioned folder like .../arm64/1789931890_9.0.2/ffmpeg.zip
        let latest = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(Self.ffmpegArch)/release/ffmpeg.zip")!
        let (_, response) = try await URLSession.shared.data(from: latest, delegate: StopRedirects())
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: latest)?.absoluteURL,
              TrustedHosts.isAllowed(target, hosts: ["ffmpeg.martin-riedl.de"]),
              target.lastPathComponent == "ffmpeg.zip"
        else { throw Failure.noRelease }
        let folder = target.deletingLastPathComponent()
        let version = folder.lastPathComponent.split(separator: "_", maxSplits: 1).last.map(String.init)
            ?? folder.lastPathComponent

        if !force, Self.ffmpegInstalled, ffmpegVersion == version { return false }
        status = .downloading
        for tool in ["ffmpeg", "ffprobe"] {
            let zip = folder.appendingPathComponent("\(tool).zip")
            try await Self.install(tool, zip: zip, checksum: zip.appendingPathExtension("sha256"))
        }
        ffmpegVersion = version
        return true
    }

    // MARK: - Deno

    private func updateDeno(force: Bool) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/denoland/deno/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { throw Failure.noRelease }
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init)
        }
        let name = "deno-\(Self.denoTarget).zip"
        guard let zip = asset(name), let sum = asset("\(name).sha256sum"),
              TrustedHosts.isAllowed(zip, hosts: ["github.com"]), TrustedHosts.isAllowed(sum, hosts: ["github.com"])
        else { throw Failure.noRelease }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        if !force, Self.isInstalled("deno"), denoVersion == version { return false }
        status = .downloading
        try await Self.install("deno", zip: zip, checksum: sum)
        denoVersion = version
        return true
    }

    // MARK: - Shared install

    private enum Failure: LocalizedError {
        case noRelease, checksumMismatch, badBinary, badSignature

        var errorDescription: String? {
            switch self {
            case .noRelease: String(localized: "Couldn’t find the latest build.")
            case .checksumMismatch: String(localized: "The download didn’t match its published checksum, so it was discarded.")
            case .badBinary: String(localized: "The downloaded tool didn’t run.")
            case .badSignature: String(localized: "The download isn’t signed by its developer, so it was discarded.")
            }
        }
    }

    /// Downloads a zip containing `tool`, verifies it against a "<sha256>  <name>" checksum file,
    /// checks the binary runs, and swaps it into Pluck's tools folder.
    private static func install(_ tool: String, zip zipURL: URL, checksum: URL) async throws {
        async let sumTask = URLSession.shared.data(from: checksum)
        let (zipFile, _) = try await URLSession.shared.download(from: zipURL)
        let (sumData, _) = try await sumTask

        let expected = String(decoding: sumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected.lowercased() else { throw Failure.checksumMismatch }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PluckTool-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        guard await run("/usr/bin/ditto", ["-x", "-k", zipFile.path, staging.path]) else { throw Failure.badBinary }

        let binary = staging.appendingPathComponent(tool)
        guard let team = signingTeams[tool], CodeSignature.isSigned(binary, byTeam: team) else { throw Failure.badSignature }
        guard await run(binary.path, [tool == "deno" ? "--version" : "-version"]) else { throw Failure.badBinary }

        try fm.createDirectory(at: Updater.directory, withIntermediateDirectories: true)
        let destination = path(tool)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: binary)
        } else {
            try fm.moveItem(at: binary, to: destination)
        }
    }

    private static func run(_ tool: String, _ args: [String]) async -> Bool {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }
}
