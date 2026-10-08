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
    var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updaterLastChecked") }
    }

    @ObservationIgnored private var timer: Timer?

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

    func check(force: Bool = false) async {
        guard !isBusy else { return }
        status = .checking
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
            case .noAsset: "The latest release has no macOS build."
            case .checksumMissing: "The release has no checksum for the macOS build."
            case .checksumMismatch: "The download didn’t match its published checksum, so it was discarded."
            case .badBinary: "The downloaded yt-dlp didn’t run."
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
        async let sumsTask = URLSession.shared.data(from: release.checksums)
        let (tempFile, _) = try await URLSession.shared.download(from: release.binary)
        let (sumsData, _) = try await sumsTask

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

        guard await Self.runs(staged) else {
            try? fm.removeItem(at: staged)
            throw Failure.badBinary
        }
        if fm.fileExists(atPath: Self.binaryURL.path) {
            _ = try fm.replaceItemAt(Self.binaryURL, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: Self.binaryURL)
        }
    }

    private static func runs(_ url: URL) async -> Bool {
        await Task.detached {
            let p = Process()
            p.executableURL = url
            p.arguments = ["--version"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }
}
