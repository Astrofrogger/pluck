import Foundation

/// spektrafilm, Andrea Volpato's spectral film simulation, as a separate program next to Pluck.
/// It isn't part of Pluck: it's downloaded (with Python and its libraries, through uv) only when
/// someone asks for it on the Photo page, into its own folder, and runs as its own process that
/// Pluck sends jobs to. Film and paper profiles are CC BY-SA 4.0, credited on the Photo page.
@MainActor
@Observable
final class FilmEngine {
    static let shared = FilmEngine()

    enum State: Equatable {
        case notInstalled, installing, ready, failed(String)
    }

    struct Profile: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let type: String
        let use: String
        /// The paper a film is made to be printed on.
        let print: String?
    }

    private(set) var state: State = .notInstalled
    /// While installing: what's happening, and how far (0…1).
    private(set) var stage = ""
    private(set) var progress = 0.0
    private(set) var films: [Profile] = []
    private(set) var papers: [Profile] = []
    /// Every setting spektrafilm has, with its default ("camera.exposure_compensation_ev": 0).
    private(set) var schema: [String: SettingValue] = [:]

    /// About what the download and the install take (shown before asking).
    static let downloadMB = 200
    static let diskMB = 550
    static let uvVersion = "0.13.0"
    static let spektrafilmVersion = "v0.3.3"

    static var folder: URL {
        // Tests use their own engine, never the one in Pluck's folder.
        if ScreenshotMode.scene != nil, let test = UserDefaults.standard.string(forKey: "PluckScreenshotEngine") {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Film Engine", isDirectory: true)
    }
    private static var python: URL { folder.appendingPathComponent("venv/bin/python") }
    private static var marker: URL { folder.appendingPathComponent("installed-\(spektrafilmVersion)") }
    private static var bridge: URL? { Bundle.main.url(forResource: "pluck_film", withExtension: "py", subdirectory: "FilmEngine") }

    /// The engine's processes: one for previews, more for exporting several photos at once.
    @ObservationIgnored private var workers: [FilmWorker] = []

    /// How many photos to develop at the same time when exporting: a render keeps about four
    /// cores busy and needs a few GB of memory at full size.
    static var exportWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(1, min(cores / 4, gigabytes / 8, 4))
    }

    private init() {
        if FileManager.default.fileExists(atPath: Self.marker.path) { state = .ready }
    }

    // MARK: - Installing

    /// Downloads uv, then Python, spektrafilm and its libraries into Pluck's folder.
    func install() {
        guard state != .installing else { return }
        state = .installing
        progress = 0
        Task {
            do {
                try await runInstall()
                state = .ready
                await loadProfiles()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func runInstall() async throws {
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 1. uv, the Python installer (a single program).
        stage = String(localized: "Downloading the installer…")
        let arch = ProcessInfo.processInfo.machineHardwareName == "arm64" ? "aarch64" : "x86_64"
        let archive = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-\(arch)-apple-darwin.tar.gz")!
        let (download, _) = try await URLSession.shared.download(from: archive)
        let tarball = folder.appendingPathComponent("uv.tar.gz")
        try? FileManager.default.removeItem(at: tarball)
        try FileManager.default.moveItem(at: download, to: tarball)
        try await run("/usr/bin/tar", ["xzf", tarball.path, "-C", folder.path])
        try? FileManager.default.removeItem(at: tarball)
        let uv = folder.appendingPathComponent("uv-\(arch)-apple-darwin/uv").path
        progress = 0.05

        // 2. Python, spektrafilm and its libraries (the bulk), with progress from what's on disk.
        let environment = ["UV_CACHE_DIR": folder.appendingPathComponent("cache").path,
                           "UV_PYTHON_INSTALL_DIR": folder.appendingPathComponent("python").path]
        let watcher = Task {
            while !Task.isCancelled {
                let mb = Double(Self.size(of: folder)) / 1_048_576
                progress = min(0.05 + 0.9 * mb / Double(Self.diskMB + 450), 0.97)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        stage = String(localized: "Downloading Python…")
        try await run(uv, ["venv", "--python", "3.13", folder.appendingPathComponent("venv").path, "-q", "--allow-existing"], environment: environment)
        stage = String(localized: "Downloading spektrafilm…")
        let python = Self.python.path
        try await run(uv, ["pip", "install", "-q", "--python", python, "--no-deps",
                           "spektrafilm @ https://github.com/andreavolpato/spektrafilm/archive/refs/tags/\(Self.spektrafilmVersion).tar.gz"],
                      environment: environment)
        stage = String(localized: "Downloading its libraries…")
        // spektrafilm's own runtime libraries (its GUI's aren't needed).
        try await run(uv, ["pip", "install", "-q", "--python", python, "numpy~=2.4", "scipy~=1.17", "colour-science~=0.4.6",
                           "scikit-image~=0.26", "matplotlib~=3.10", "opt-einsum~=3.4.0", "numba~=0.64", "OpenImageIO~=3.1.11",
                           "pyfftw~=0.15.0", "rawpy~=0.26.1", "exiv2~=0.18.1", "lensfunpy~=1.18.0"], environment: environment)
        // The download cache isn't needed any more.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("cache"))
        stage = String(localized: "Getting the film engine ready…")
        progress = 0.98
        FileManager.default.createFile(atPath: Self.marker.path, contents: Data())
        progress = 1
    }

    /// Removes the engine (Settings, or to reinstall).
    func uninstall() {
        stop()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notInstalled
        films = []
        papers = []
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let text = String(decoding: message, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
                throw NSError(domain: "Pluck", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? String(localized: "The film engine couldn’t be installed.") : text])
            }
        }.value
    }

    nonisolated private static func size(of folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in walker {
            total += (try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
        }
        return total
    }

    // MARK: - Running

    func stop() {
        for worker in workers { worker.stop() }
        workers = []
    }

    /// A worker for this job: 0 for previews; 1… for exports (started as needed).
    private func worker(_ index: Int) -> FilmWorker {
        while workers.count <= index {
            workers.append(FilmWorker(python: Self.python, bridge: Self.bridge, folder: Self.folder))
        }
        return workers[index]
    }

    private func ask(_ job: [String: Any], worker index: Int = 0) async throws -> [String: Any] {
        try await worker(index).ask(job)
    }

    func loadProfiles() async {
        guard state == .ready, films.isEmpty else { return }
        guard let answer = try? await ask(["do": "profiles"]),
              let data = try? JSONSerialization.data(withJSONObject: answer),
              let lists = try? JSONDecoder().decode([String: [Profile]].self, from: data) else { return }
        films = lists["film"] ?? []
        papers = lists["print"] ?? []
        if let raw = try? await ask(["do": "schema"]) {
            schema = raw.compactMapValues(SettingValue.init)
        }
    }

    /// Renders a linear sRGB TIFF through the film and paper into a 16-bit sRGB TIFF.
    func render(_ input: URL, to output: URL, film: FilmSettings, preview: Bool, maxSize: Int = 1400, worker: Int = 0) async throws {
        var job: [String: Any] = ["do": "render", "input": input.path, "output": output.path, "film": film.film, "print": film.paper,
                                  "preview": preview, "max_size": maxSize]
        job["set"] = film.settings
        _ = try await ask(job, worker: worker)
    }

    /// Takes the noise out of a linear TIFF (strength 0…1), into a linear half-float TIFF.
    func denoise(_ input: URL, to output: URL, strength: Double, worker: Int = 1) async throws {
        _ = try await ask(["do": "denoise", "input": input.path, "output": output.path, "strength": strength], worker: worker)
    }
}

/// A spektrafilm setting's value, as it travels in JSON.
enum SettingValue: Codable, Hashable {
    case number(Double), flag(Bool), text(String), numbers([Double])

    init?(_ any: Any) {
        if let value = any as? Bool, CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() { self = .flag(value) }
        else if let value = any as? Double { self = .number(value) }
        else if let value = any as? Int { self = .number(Double(value)) }
        else if let value = any as? String { self = .text(value) }
        else if let value = any as? [Double] { self = .numbers(value) }
        else if let value = any as? [Int] { self = .numbers(value.map(Double.init)) }
        else { return nil }
    }

    var json: Any {
        switch self {
        case .number(let value): value
        case .flag(let value): value
        case .text(let value): value
        case .numbers(let value): value
        }
    }
}

/// A photo's film: the stock, the paper it's printed on, and any spektrafilm setting changed
/// from its default (by its path, "camera.exposure_compensation_ev").
struct FilmSettings: Codable, Hashable {
    var film = "kodak_portra_400"
    var paper = "kodak_portra_endura"
    var changed: [String: SettingValue] = [:]

    var settings: [String: Any] { changed.mapValues(\.json) }
}

/// One of the engine's processes, started on first use and kept (Python and its compiled code
/// take a few seconds to start; after that a preview takes about a second). Jobs go one at a time.
@MainActor
final class FilmWorker {
    private let python: URL
    private let bridge: URL?
    private let folder: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(python: URL, bridge: URL?, folder: URL) {
        self.python = python
        self.bridge = bridge
        self.folder = folder
    }

    private func start() throws {
        guard process == nil else { return }
        guard let bridge else { throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey: "pluck_film.py is missing"]) }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", bridge.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["MPLCONFIGDIR": folder.appendingPathComponent("matplotlib").path,
                                                                           "NUMBA_CACHE_DIR": folder.appendingPathComponent("numba").path]) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.process = nil }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Sends a job and waits for its answer line.
    func ask(_ job: [String: Any]) async throws -> [String: Any] {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        try start()
        guard let input, let output else { throw NSError(domain: "Pluck", code: 2) }
        var line = try JSONSerialization.data(withJSONObject: job)
        line.append(0x0A)
        input.write(line)
        let answer = await Task.detached { () -> Data in
            var data = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if chunk.last == 0x0A { break }
            }
            return data
        }.value
        guard let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any] else {
            stop()
            throw NSError(domain: "Pluck", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "The film engine stopped.")])
        }
        if let error = object["error"] as? String { throw NSError(domain: "Pluck", code: 4, userInfo: [NSLocalizedDescriptionKey: error]) }
        return object
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
