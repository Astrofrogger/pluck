import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates Pluck itself from GitHub releases. Each release is two disk images, one per edition (see
/// Edition): Pluck.dmg and Pluck-Studio.dmg. The download is checked against the SHA-256 GitHub
/// records for it, the app copied out of the image, swapped in place of the running app, and
/// relaunched. Switching edition is the same, with the other edition's image.
@MainActor
@Observable
final class AppUpdater {
    static let repo = "Astrofrogger/pluck"

    struct Release: Equatable {
        let version: String
        let notes: String
        /// The download: the edition's disk image (or, from releases before 1.17.3, a zip).
        let file: URL
        /// Its SHA-256, from GitHub's own record of the file (hex), or the address of a
        /// published .sha256 file for the old zips.
        let digest: String?
        let checksum: URL?
        let page: URL
        var isDiskImage: Bool { file.pathExtension.lowercased() == "dmg" }
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available, installing, failed(String)
    }

    var status: Status = .idle
    var release: Release?
    var dismissedVersion: String?
    /// A new version to offer in a window of its own (once per version).
    var prompt: Release?
    private static let promptedKey = "updatePromptedVersion"

    /// While installing: where it's got to, and what's coming ("Pluck 3.1.0", "Pluck Studio").
    enum Step: Equatable { case downloading, checking, unpacking, relaunching }
    private(set) var step: Step?
    private(set) var installing: String?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0
    @ObservationIgnored private var installTask: Task<URL, Error>?
    /// Being made ready to swap in when Pluck quits (not now).
    private(set) var forQuit = false
    /// Ready: the version that's swapped in when Pluck quits.
    private(set) var readyForQuit: String?
    @ObservationIgnored private var pending: (target: URL, app: URL)?

    /// How far the download is (0…1), once its size is known.
    var downloaded: Double? {
        guard step == .downloading, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }

    /// What's new in it, without the release page's download table and headings.
    static func whatsNew(_ notes: String) -> String {
        let part = notes.components(separatedBy: "### Download").first ?? notes
        return part.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Screenshots: an update made ready to go in when Pluck quits.
    func pretendReady(_ version: String) {
        status = .available
        readyForQuit = version
    }

    /// Screenshots: a new version offered, as if just found.
    func pretendAvailable(_ version: String, notes: String) {
        let page = URL(string: "https://github.com/\(Self.repo)/releases")!
        release = Release(version: version, notes: notes, file: page, digest: nil, checksum: nil, page: page)
        status = .available
        prompt = release
    }

    /// Screenshots: the bar as if this much of an update had come in.
    func pretendInstalling(_ name: String, received: Int64, of expected: Int64) {
        status = .installing
        installing = name
        step = .downloading
        self.received = received
        self.expected = expected
    }

    /// Stops the download (what came in so far is kept, so the next try carries on from there).
    func cancelInstall() { installTask?.cancel() }

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
                // Offered in a window the first time it's found (the banner stays until it's in).
                if UserDefaults.standard.string(forKey: Self.promptedKey) != latest.version, latest.version != dismissedVersion {
                    UserDefaults.standard.set(latest.version, forKey: Self.promptedKey)
                    prompt = latest
                }
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
        case noRelease, checksumMismatch, badBundle, notWritable, noEdition

        var errorDescription: String? {
            switch self {
            case .noRelease: String(localized: "No downloadable release was found.")
            case .checksumMismatch: String(localized: "The update didn’t match its published checksum, so it was discarded.")
            case .badBundle: String(localized: "The downloaded update isn’t a valid copy of Pluck.")
            case .notWritable: String(localized: "Pluck can’t replace itself here. Move it to the Applications folder and try again.")
            case .noEdition: String(localized: "That version of Pluck isn’t available to download yet.")
            }
        }
    }

    /// The latest release, with the download of the edition asked for (this one by default).
    func fetchLatest(studio: Bool = Edition.isStudio) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let page = (json["html_url"] as? String).flatMap(URL.init)
        else { throw Failure.noRelease }
        func entry(_ name: String) -> [String: Any]? { assets.first { $0["name"] as? String == name } }
        func asset(_ name: String) -> URL? { (entry(name)?["browser_download_url"] as? String).flatMap(URL.init) }
        let body = json["body"] as? String ?? ""
        var version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        // Releases are just the two disk images: Pluck.dmg and Pluck-Studio.dmg. GitHub records
        // each file's SHA-256, which the download is checked against.
        let image = studio ? "Pluck-Studio.dmg" : "Pluck.dmg"
        if let url = asset(image), TrustedHosts.isAllowed(url, hosts: ["github.com"]),
           let digest = (entry(image)?["digest"] as? String).flatMap(Self.sha256Hex) {
            // A release can carry an edition unchanged (a Studio-only release keeps basic Pluck as
            // it was); the release notes say, out of sight, which version of each it holds.
            if let own = Self.editionVersion(in: body, studio: studio) { version = own }
            return Release(version: version, notes: Self.visibleNotes(body), file: url, digest: digest, checksum: nil, page: page)
        }

        // Before 1.17.3: zips with .sha256 files, and editions.json.
        let names = studio ? ["Pluck-Studio.zip", "Pluck.zip"] : ["Pluck-Basic.zip"]
        guard let name = names.first(where: { asset($0) != nil && asset($0 + ".sha256") != nil }) else {
            throw studio ? Failure.noRelease : Failure.noEdition
        }
        guard let zip = asset(name), let sum = asset(name + ".sha256"),
              TrustedHosts.isAllowed(zip, hosts: ["github.com"]), TrustedHosts.isAllowed(sum, hosts: ["github.com"])
        else { throw Failure.noRelease }
        if let manifest = asset("editions.json"), TrustedHosts.isAllowed(manifest, hosts: ["github.com"]),
           let (data, response) = try? await URLSession.shared.data(from: manifest),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let editions = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let own = editions[studio ? "studio" : "basic"], !own.isEmpty {
            version = own
        }
        return Release(version: version, notes: Self.visibleNotes(body), file: zip, digest: nil, checksum: sum, page: page)
    }

    /// "sha256:ab12…" → "ab12…".
    private static func sha256Hex(_ digest: String) -> String? {
        guard digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        return hex.count == 64 ? String(hex) : nil
    }

    /// The edition's version from the release notes' hidden line
    /// "<!-- pluck-editions studio=1.18.0 basic=1.17.3 -->".
    static func editionVersion(in notes: String, studio: Bool) -> String? {
        guard let range = notes.range(of: #"<!--\s*pluck-editions[^>]*-->"#, options: .regularExpression) else { return nil }
        let line = notes[range]
        let key = studio ? "studio=" : "basic="
        guard let start = line.range(of: key) else { return nil }
        let value = line[start.upperBound...].prefix { $0.isNumber || $0 == "." }
        return value.isEmpty ? nil : String(value)
    }

    /// The notes without hidden lines, for showing.
    private static func visibleNotes(_ notes: String) -> String {
        notes.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Installing

    /// Replaces this edition with the other one (latest version) and relaunches. Downloads,
    /// the Library and settings stay: both editions are the same app to macOS.
    func switchEdition() async {
        guard status != .installing else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            status = .failed(Failure.notWritable.localizedDescription)
            return
        }
        await install(Edition.isStudio ? "Pluck" : "Pluck Studio", target: target) {
            let other = try await self.fetchLatest(studio: !Edition.isStudio)
            return try await self.download(other)
        }
    }

    func installAndRelaunch() async {
        if let pending {
            step = .relaunching
            status = .installing
            installing = readyForQuit.map { "\(Edition.name) \($0)" }
            relaunch(replacing: pending.target, with: pending.app)
            return
        }
        guard let release, status != .installing else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            status = .failed(Failure.notWritable.localizedDescription)
            return
        }

        await install("\(Edition.name) \(release.version)", target: target) { try await self.download(release) }
    }

    /// Downloads and checks the update now, and swaps it in when Pluck quits (without opening it
    /// again): nothing stops for it.
    func installWhenQuitting() async {
        guard let release, status != .installing else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            status = .failed(Failure.notWritable.localizedDescription)
            return
        }
        forQuit = true
        defer { forQuit = false }
        await install("\(Edition.name) \(release.version)", target: target, later: release.version) { try await self.download(release) }
    }

    /// Pluck quitting: the update made ready, swapped in (Pluck isn't opened again).
    func installPendingOnQuit() {
        guard let pending else { return }
        self.pending = nil
        swap(pending.target, with: pending.app, reopen: false)
    }

    /// Gets the new app (downloaded, checked, unpacked), then swaps it in and relaunches. A
    /// cancelled download goes back to where it was.
    private func install(_ name: String, target: URL, later: String? = nil, get: @escaping @MainActor () async throws -> URL) async {
        status = .installing
        installing = name
        step = .downloading
        received = 0
        expected = 0
        let task = Task { try await get() }
        installTask = task
        defer { installTask = nil }
        do {
            let newApp = try await task.value
            if let later {
                // Kept until Pluck quits.
                pending = (target, newApp)
                readyForQuit = later
                step = nil
                installing = nil
                status = .available
                return
            }
            step = .relaunching
            relaunch(replacing: target, with: newApp)
        } catch {
            step = nil
            installing = nil
            if task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                status = release != nil ? .available : .idle
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func download(_ release: Release) async throws -> URL {
        let downloaded = try await ToolDownloads.download(release.file, limit: 2 * 3600) { received, total in
            Task { @MainActor in
                self.received = received
                self.expected = total
            }
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        step = .checking

        let expected: String
        if let digest = release.digest {
            expected = digest
        } else if let checksum = release.checksum {
            let (sumData, _) = try await URLSession.shared.data(from: checksum)
            expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        } else {
            expected = ""
        }
        let actual = SHA256.hash(data: try Data(contentsOf: downloaded, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected else { throw Failure.checksumMismatch }

        step = .unpacking
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PluckUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        if release.isDiskImage {
            // Opened out of sight, the app copied out, and closed again.
            let mount = staging.appendingPathComponent("image", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/hdiutil", ["attach", downloaded.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            do {
                try await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("Pluck.app").path, staging.appendingPathComponent("Pluck.app").path])
            } catch {
                try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                throw error
            }
            try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        } else {
            try await Self.run("/usr/bin/ditto", ["-x", "-k", downloaded.path, staging.path])
        }

        let app = staging.appendingPathComponent("Pluck.app")
        guard Bundle(url: app)?.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "be.wideopen.pluck") else { throw Failure.badBundle }
        return app
    }

    /// Hands off to a tiny shell script that waits for Pluck to quit, swaps the bundles and reopens it.
    private func relaunch(replacing target: URL, with newApp: URL) {
        pending = nil
        do {
            try startSwap(target, with: newApp, reopen: true)
            NSApp.terminate(nil)
        } catch {
            step = nil
            installing = nil
            status = .failed(error.localizedDescription)
        }
    }

    private func swap(_ target: URL, with newApp: URL, reopen: Bool) {
        try? startSwap(target, with: newApp, reopen: reopen)
    }

    /// The script that swaps the bundles once this Pluck has gone (and opens the new one if asked).
    private func startSwap(_ target: URL, with newApp: URL, reopen: Bool) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old" && mv "$2" "$2.old" && mv "$3" "$2" && rm -rf "$2.old"
        \(reopen ? "open \"$2\"" : "true")
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "pluck-update", "\(ProcessInfo.processInfo.processIdentifier)", target.path, newApp.path]
        try p.run()
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Failure.badBundle }
        }.value
    }
}
