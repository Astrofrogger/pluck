import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates Pluck itself from GitHub releases. Each release carries Pluck.zip and Pluck.zip.sha256;
/// the update is verified, unpacked, swapped in place of the running app, and relaunched.
@MainActor
@Observable
final class AppUpdater {
    static let repo = "Astrofrogger/pluck"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let checksum: URL
        let page: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available, installing, failed(String)
    }

    var status: Status = .idle
    var release: Release?
    var dismissedVersion: String?

    @ObservationIgnored private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Shown in the main window until installed or dismissed.
    var showsBanner: Bool {
        status == .available && release != nil && release?.version != dismissedVersion
    }

    func startAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard UserDefaults.standard.bool(forKey: Prefs.appAutoUpdate) else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard status != .checking, status != .installing else { return }
        status = .checking
        do {
            let latest = try await fetchLatest()
            if Self.isNewer(latest.version, than: currentVersion) {
                release = latest
                status = .available
            } else {
                release = nil
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // MARK: - GitHub

    private enum Failure: LocalizedError {
        case noRelease, checksumMismatch, badBundle, notWritable

        var errorDescription: String? {
            switch self {
            case .noRelease: String(localized: "No downloadable release was found.")
            case .checksumMismatch: String(localized: "The update didn’t match its published checksum, so it was discarded.")
            case .badBundle: String(localized: "The downloaded update isn’t a valid copy of Pluck.")
            case .notWritable: String(localized: "Pluck can’t replace itself here. Move it to the Applications folder and try again.")
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let page = (json["html_url"] as? String).flatMap(URL.init)
        else { throw Failure.noRelease }
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init)
        }
        guard let zip = asset("Pluck.zip"), let sum = asset("Pluck.zip.sha256"),
              TrustedHosts.isAllowed(zip, hosts: ["github.com"]), TrustedHosts.isAllowed(sum, hosts: ["github.com"])
        else { throw Failure.noRelease }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", zip: zip, checksum: sum, page: page)
    }

    // MARK: - Installing

    func installAndRelaunch() async {
        guard let release, status != .installing else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            status = .failed(Failure.notWritable.localizedDescription)
            return
        }

        status = .installing
        do {
            let newApp = try await download(release)
            relaunch(replacing: target, with: newApp)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ release: Release) async throws -> URL {
        async let sumTask = URLSession.shared.data(from: release.checksum)
        let (zipFile, _) = try await URLSession.shared.download(from: release.zip)
        let (sumData, _) = try await sumTask

        let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected.lowercased() else { throw Failure.checksumMismatch }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PluckUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, staging.path])

        let app = staging.appendingPathComponent("Pluck.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Failure.badBundle }
        return app
    }

    /// Hands off to a tiny shell script that waits for Pluck to quit, swaps the bundles and reopens it.
    private func relaunch(replacing target: URL, with newApp: URL) {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old" && mv "$2" "$2.old" && mv "$3" "$2" && rm -rf "$2.old"
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "pluck-update", "\(ProcessInfo.processInfo.processIdentifier)", target.path, newApp.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Failure.badBundle }
        }.value
    }
}
