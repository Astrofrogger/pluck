import CryptoKit
import Foundation

/// Pluck's film: spektrafilm, Andrea Volpato's spectral film simulation, in darktable's native
/// port (pluck-spektra, a separate GPL program inside Pluck), with the film and paper data
/// darktable publishes (a 9 MB pack, each file checked, downloaded when someone asks for it on
/// the Photo page). Pluck sends it jobs. The data is CC BY-SA 4.0, credited on the Photo page.
///
/// Denoise runs in a separate Python engine (NumPy and scikit-image, through uv), downloaded
/// only when someone asks for it, with an optional AI denoiser on top.
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
        var bw: Bool? = false
    }

    /// One of the film's settings: its default and range, as darktable has them.
    struct Setting: Hashable {
        enum Kind: String { case number, flag, choice }
        let value: Double
        let min: Double
        let max: Double
        let kind: Kind
    }

    /// The film data pack.
    private(set) var state: State = .notInstalled
    /// While downloading: what's happening, and how far (0…1).
    private(set) var stage = ""
    private(set) var progress = 0.0
    private(set) var films: [Profile] = []
    private(set) var papers: [Profile] = []
    /// Every film setting, by name ("grain_amount"), with its default and range.
    private(set) var schema: [String: Setting] = [:]

    /// About what the download takes (shown before asking).
    static let downloadMB = 9
    static let diskMB = 10
    static let packRepository = "darktable-org/darktable-spektrafilm"
    /// The pack's commit the shipped tables were made from (scripts/film-tables.sh pins the same one).
    static let packCommit = "b15cfe18fb35ec15084f78c986b0ebc730338e6e"
    /// Whether the downloaded pack is the one the shipped tables were made from (nil: not known yet). Tables made for
    /// one photo from another pack can differ a little from the shipped ones: that's logged.
    static var packMatchesTables: Bool? {
        guard let shipped = FilmTables.shared.packSHA,
              let downloaded = try? String(contentsOf: pack.appendingPathComponent(".manifest-sha"), encoding: .utf8) else { return nil }
        return downloaded.trimmingCharacters(in: .whitespacesAndNewlines) == shipped
    }

    nonisolated static var folder: URL {
        // Tests use their own copy, never the one in Pluck's folder.
        if ScreenshotMode.scene != nil, let test = UserDefaults.standard.string(forKey: "PluckScreenshotEngine") {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Film Engine", isDirectory: true)
    }
    /// The film data (pack.json, spectra_lut.f32, profiles/).
    static var pack: URL { folder.appendingPathComponent("pack", isDirectory: true) }
    private static var packMarker: URL { pack.appendingPathComponent(".complete") }
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pluck-spektra")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The film's processes: one for previews, more for exporting several photos at once.
    @ObservationIgnored private var workers: [FilmWorker] = []

    /// How many photos to develop at the same time when exporting.
    static var exportWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(1, min(cores / 2, gigabytes / 4, 6))
    }

    private init() {
        // The shipped film tables list the stocks, so the pickers work without the helper's pack.
        films = FilmTables.shared.films
        papers = FilmTables.shared.papers
        if FileManager.default.fileExists(atPath: Self.packMarker.path) { state = .ready }
        // The earlier Python film engine has everything denoise needs.
        if FileManager.default.fileExists(atPath: Self.pythonMarker.path)
            || FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent("installed-v0.3.3").path) { denoiseEngine = .ready }
        checkDenoiser()
    }

    // MARK: - The film data

    /// Downloads darktable's spektrafilm data pack, checking every file against the manifest.
    func install() {
        guard state != .installing else { return }
        state = .installing
        progress = 0
        Task {
            do {
                try await downloadPack()
                state = .ready
                await loadProfiles()
                // Photos waiting for their advanced settings' tables can have them now.
                FilmAdvanced.shared.packArrived()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct Manifest: Decodable {
        struct Pack: Decodable {
            struct File: Decodable { let path: String; let size: Int; let sha256: String }
            let base: String
            let pack_format: Int
            let files: [File]
        }
        let packs: [Pack]
    }

    private func downloadPack() async throws {
        let raw = "https://raw.githubusercontent.com/\(Self.packRepository)/\(Self.packCommit)"
        stage = String(localized: "Getting the list of films…")
        let (data, _) = try await URLSession.shared.data(from: URL(string: raw + "/manifest.json")!)
        let manifestSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let shipped = FilmTables.shared.packSHA, shipped != manifestSHA {
            NSLog("Pluck film: the film data downloaded (%@) isn't what the shipped tables were made from (%@)", manifestSHA, shipped)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // The newest layout pluck-spektra reads (darktable's pack formats 2 and 3).
        guard let pack = manifest.packs.filter({ (2...3).contains($0.pack_format) }).last else {
            throw NSError(domain: "Pluck", code: 6, userInfo: [NSLocalizedDescriptionKey: String(localized: "There's no film data this version of Pluck can use.")])
        }
        let total = Double(pack.files.reduce(0) { $0 + $1.size })
        let staging = Self.folder.appendingPathComponent("pack-download", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var done = 0.0
        stage = String(localized: "Downloading the films and papers…")
        for file in pack.files {
            // Paths come from the manifest: nothing absolute, nothing that climbs out.
            guard !file.path.hasPrefix("/"), !file.path.contains(".."), file.size < 64 << 20 else { throw NSError(domain: "Pluck", code: 7) }
            let (body, _) = try await URLSession.shared.data(from: URL(string: "\(raw)/\(pack.base)/\(file.path)")!)
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            guard body.count == file.size, hash == file.sha256 else {
                throw NSError(domain: "Pluck", code: 8, userInfo: [NSLocalizedDescriptionKey: String(localized: "A film file didn’t match its published checksum, so it was discarded. Try again.")])
            }
            let target = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target)
            done += Double(file.size)
            progress = done / max(total, 1)
        }
        // The data's licence travels with it.
        if let (license, _) = try? await URLSession.shared.data(from: URL(string: raw + "/LICENSE")!) {
            try? license.write(to: staging.appendingPathComponent("LICENSE"))
        }
        try? manifestSHA.write(to: staging.appendingPathComponent(".manifest-sha"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: staging.appendingPathComponent(".complete").path, contents: Data())
        for worker in workers { worker.stop() }
        workers = []
        try? FileManager.default.removeItem(at: Self.pack)
        try FileManager.default.moveItem(at: staging, to: Self.pack)
        films = FilmTables.shared.films
        progress = 1
    }

    /// Removes the film data and the denoise engine (Settings).
    func uninstall() {
        stop()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notInstalled
        denoiseEngine = .notInstalled
        denoiser = .notInstalled
        denoiserUpdate = false
        films = FilmTables.shared.films
        papers = FilmTables.shared.papers
    }

    // MARK: - Running the film

    func stop() {
        for worker in workers { worker.stop() }
        workers = []
        for worker in pythonWorkers { worker.stop() }
        pythonWorkers = []
    }

    /// A worker for this job: 0 for previews; 1… for exports (started as needed).
    private func worker(_ index: Int) throws -> FilmWorker {
        guard let helper = Self.helper else {
            throw NSError(domain: "Pluck", code: 9, userInfo: [NSLocalizedDescriptionKey: String(localized: "The film engine isn't part of this build of Pluck.")])
        }
        while workers.count <= index { workers.append(FilmWorker(executable: helper, arguments: [], environment: [:])) }
        return workers[index]
    }

    private func ask(_ job: [String: Any], worker index: Int = 0) async throws -> [String: Any] {
        try await worker(index).ask(job)
    }

    func loadProfiles() async {
        guard films.isEmpty || schema.isEmpty else { return }
        // (The settings and their defaults come from the helper itself: no film data needed for those.)
        if films.isEmpty, state == .ready {
            guard let answer = try? await ask(["do": "profiles", "pack": Self.pack.path]),
                  let data = try? JSONSerialization.data(withJSONObject: answer),
                  let lists = try? JSONDecoder().decode([String: [Profile]].self, from: data) else { return }
            films = lists["film"] ?? []
            papers = lists["print"] ?? []
        }
        if schema.isEmpty, let raw = try? await ask(["do": "schema"]) {
            schema = raw.compactMapValues { value -> Setting? in
                guard let entry = value as? [String: Any], let def = (entry["default"] as? NSNumber)?.doubleValue,
                      let min = (entry["min"] as? NSNumber)?.doubleValue, let max = (entry["max"] as? NSNumber)?.doubleValue else { return nil }
                return Setting(value: def, min: min, max: max, kind: Setting.Kind(rawValue: entry["kind"] as? String ?? "") ?? .number)
            }
        }
    }

    /// Develops a picture on film: raw RGBA float in (linear sRGB, scene light), the same out
    /// (linear sRGB, the finished print or scan). `fullLongEdge` is the photo's own long side,
    /// so grain and halation keep their real size in a smaller preview.
    func render(_ input: URL, to output: URL, width: Int, height: Int, film: FilmSettings, fullLongEdge: Int, worker: Int = 0) async throws {
        var job: [String: Any] = ["do": "render", "pack": Self.pack.path, "input": input.path, "output": output.path,
                                  "width": width, "height": height, "film": film.film, "print": film.paper,
                                  "full_long_edge": fullLongEdge]
        // (The couplers' edge setting is Pluck's own: the helper always spreads them fully.)
        job["set"] = film.settings.filter { $0.key != "couplers_edge" }
        _ = try await ask(job, worker: worker)
    }

    /// Makes the film tables for one photo's advanced settings (format document §7) into `folder`: `film.pft`, and
    /// `paper.pft` and `pair.pft` unless the film is looked at without a print (`scan_film`). Made for this photo
    /// alone, so the pair carries its own scan and the scans have the finer grid.
    func tables(film: String, paper: String, settings: [String: Any], to folder: URL) async throws {
        let scanned = ((settings["scan_film"] as? NSNumber)?.doubleValue ?? 0) > 0.5
        for part in scanned ? ["film"] : ["film", "paper", "pair"] {
            var job: [String: Any] = ["do": "tables", "part": part, "pack": Self.pack.path, "film": film, "print": paper,
                                      "set": settings, "output": folder.appendingPathComponent("\(part).pft").path]
            if part == "pair" { job["own_scan"] = true }
            if part == "pair" || (part == "film" && scanned) { job["n_scan"] = 97 }
            _ = try await ask(job, worker: Self.tablesWorker)
        }
    }

    /// The tables have a worker of their own, so the big photo's helper film isn't kept waiting (exports use 1…6,
    /// the looks' film thumbnails 4).
    static let tablesWorker = 7

    // MARK: - Denoise engine (Python, on request)

    private(set) var denoiseEngine: State = .notInstalled
    private(set) var denoiseProgress = 0.0
    static let denoiseEngineDownloadMB = 120
    static let uvVersion = "0.13.0"
    @ObservationIgnored private var pythonWorkers: [FilmWorker] = []
    private static var python: URL { folder.appendingPathComponent("venv/bin/python") }
    private static var pythonMarker: URL { folder.appendingPathComponent("installed-denoise-v1") }
    /// The denoiser (Pluck's own script; the downloaded Python runs it).
    private static var bridge: URL? { Bundle.main.url(forResource: "pluck_denoise", withExtension: "py", subdirectory: "FilmEngine") }

    /// Downloads uv, then Python, NumPy, scikit-image and OpenImageIO into Pluck's folder.
    func installDenoiseEngine() {
        guard denoiseEngine != .installing else { return }
        denoiseEngine = .installing
        denoiseProgress = 0
        Task {
            do {
                try await runPythonInstall()
                denoiseEngine = .ready
            } catch {
                denoiseEngine = .failed(error.localizedDescription)
            }
        }
    }

    private func runPythonInstall() async throws {
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arch = ProcessInfo.processInfo.machineHardwareName == "arm64" ? "aarch64" : "x86_64"
        let uv = folder.appendingPathComponent("uv-\(arch)-apple-darwin/uv").path
        if !FileManager.default.isExecutableFile(atPath: uv) {
            let archive = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-\(arch)-apple-darwin.tar.gz")!
            let (download, _) = try await URLSession.shared.download(from: archive)
            let tarball = folder.appendingPathComponent("uv.tar.gz")
            try? FileManager.default.removeItem(at: tarball)
            try FileManager.default.moveItem(at: download, to: tarball)
            try await run("/usr/bin/tar", ["xzf", tarball.path, "-C", folder.path])
            try? FileManager.default.removeItem(at: tarball)
        }
        denoiseProgress = 0.05
        let environment = ["UV_CACHE_DIR": folder.appendingPathComponent("cache").path,
                           "UV_PYTHON_INSTALL_DIR": folder.appendingPathComponent("python").path]
        let start = Self.size(of: folder)
        let watcher = Task {
            while !Task.isCancelled {
                let mb = Double(Self.size(of: folder) - start) / 1_048_576
                denoiseProgress = min(0.05 + 0.9 * mb / 350, 0.97)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        try await run(uv, ["venv", "--python", "3.13", folder.appendingPathComponent("venv").path, "-q", "--allow-existing"], environment: environment)
        try await run(uv, ["pip", "install", "-q", "--python", Self.python.path, "numpy~=2.4", "scipy~=1.17", "scikit-image~=0.26",
                           "OpenImageIO~=3.1.11"], environment: environment)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("cache"))
        FileManager.default.createFile(atPath: Self.pythonMarker.path, contents: Data())
        denoiseProgress = 1
    }

    private func python(_ index: Int) -> FilmWorker {
        while pythonWorkers.count <= index {
            pythonWorkers.append(FilmWorker(executable: Self.python, arguments: ["-u", Self.bridge?.path ?? ""],
                                            environment: ["MPLCONFIGDIR": Self.folder.appendingPathComponent("matplotlib").path]))
        }
        return pythonWorkers[index]
    }

    // MARK: - AI denoise (optional)

    enum AddOn: Equatable { case notInstalled, installing, ready, failed(String) }

    /// The AI denoiser: a Bayer RAW's own mosaic is cleaned by DRUNet (MIT) after rawpy (MIT, LibRaw LGPL-2.1/CDDL)
    /// reads it; other photos by SCUNet (Apache 2.0), a network trained on real camera noise, through spandrel (MIT).
    /// Both run with PyTorch on the GPU. An extra for the photo engine, on request.
    private(set) var denoiser: AddOn = .notInstalled
    private(set) var denoiserProgress = 0.0
    /// Installed before the RAW part came (version 1): it still works, as before, until updated.
    private(set) var denoiserUpdate = false
    // PyTorch and spandrel (88), SCUNet (72), DRUNet (131) and rawpy (2).
    static let denoiserDownloadMB = 293
    static let denoiserDiskMB = 620
    /// What updating version 1 fetches: DRUNet and rawpy.
    static let denoiserUpdateMB = 133
    static let denoiserWeights = URL(string: "https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth")!
    static let denoiserWeightsSize: Int64 = 71_982_841
    static var denoiserModel: URL { folder.appendingPathComponent("models/scunet_color_real_psnr.pth") }
    static let rawDenoiserWeights = URL(string: "https://github.com/cszn/KAIR/releases/download/v1.0/drunet_color.pth")!
    static let rawDenoiserWeightsSize: Int64 = 130_579_305
    static var rawDenoiserModel: URL { folder.appendingPathComponent("models/drunet_color.pth") }
    private static var denoiserMarker: URL { folder.appendingPathComponent("installed-denoiser-v1") }
    nonisolated private static var rawDenoiserMarker: URL { folder.appendingPathComponent("installed-denoiser-v2") }

    /// Whether the AI denoiser has its RAW part (any thread: the photo's renderer asks).
    nonisolated static var rawDenoiseInstalled: Bool { FileManager.default.fileExists(atPath: rawDenoiserMarker.path) }

    func checkDenoiser() {
        guard denoiser != .installing else { return }
        let old = FileManager.default.fileExists(atPath: Self.denoiserMarker.path)
        denoiser = old || Self.rawDenoiseInstalled ? .ready : .notInstalled
        denoiserUpdate = old && !Self.rawDenoiseInstalled
    }

    /// Gets the AI denoiser, or its RAW part when version 1 is there (what's there already isn't fetched again).
    func installDenoiser() {
        guard denoiseEngine == .ready, denoiser != .installing else { return }
        let update = denoiserUpdate
        denoiser = .installing
        denoiserProgress = 0
        Task {
            do {
                try await runDenoiserInstall(expectedMB: update ? Self.denoiserUpdateMB : Self.denoiserDiskMB)
                denoiser = .ready
                denoiserUpdate = false
            } catch {
                // (Version 1 still works.)
                denoiser = update ? .ready : .failed(error.localizedDescription)
                if update { denoiserProblem = error.localizedDescription }
            }
        }
    }

    /// Why the last update didn't finish (version 1 kept working).
    private(set) var denoiserProblem: String?

    private func runDenoiserInstall(expectedMB: Int) async throws {
        let folder = Self.folder
        let arch = ProcessInfo.processInfo.machineHardwareName == "arm64" ? "aarch64" : "x86_64"
        let uv = folder.appendingPathComponent("uv-\(arch)-apple-darwin/uv").path
        let environment = ["UV_CACHE_DIR": folder.appendingPathComponent("cache").path,
                           "UV_PYTHON_INSTALL_DIR": folder.appendingPathComponent("python").path]
        let start = Self.size(of: folder)
        let watcher = Task {
            while !Task.isCancelled {
                let mb = Double(Self.size(of: folder) - start) / 1_048_576
                denoiserProgress = min(0.9 * mb / Double(expectedMB), 0.9)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        try await run(uv, ["pip", "install", "-q", "--python", Self.python.path, "torch~=2.8", "spandrel~=0.4", "rawpy~=0.26", "tifffile>=2024.1"],
                      environment: environment)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("cache"))
        // The networks' weights, each checked by its exact size (one already there isn't fetched again).
        for (url, size, file) in [(Self.denoiserWeights, Self.denoiserWeightsSize, Self.denoiserModel),
                                  (Self.rawDenoiserWeights, Self.rawDenoiserWeightsSize, Self.rawDenoiserModel)] {
            if (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == size { continue }
            let (download, _) = try await URLSession.shared.download(from: url)
            let got = (try? FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.int64Value
            guard got == size else {
                try? FileManager.default.removeItem(at: download)
                throw NSError(domain: "Pluck", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "The AI denoiser didn’t download completely. Try again.")])
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: download, to: file)
        }
        for worker in pythonWorkers { worker.stop() }  // they load torch the next time
        pythonWorkers = []
        FileManager.default.createFile(atPath: Self.denoiserMarker.path, contents: Data())
        FileManager.default.createFile(atPath: Self.rawDenoiserMarker.path, contents: Data())
        denoiserProgress = 1
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

    /// Takes all the noise out of a linear TIFF, into a linear half-float OpenEXR (the Amount is mixed in later, live).
    func denoise(_ input: URL, to output: URL, ai: Bool = false, worker: Int = 1) async throws {
        var job: [String: Any] = ["do": "denoise", "input": input.path, "output": output.path, "version": 2]
        if ai { job["weights"] = Self.denoiserModel.path }
        _ = try await python(worker).ask(job)
    }

    /// Takes the noise out of a Bayer RAW's own mosaic (AI): writes the clean mosaic and the untouched one as DNGs,
    /// with Apple's lens correction as fitted from `lens` (its half-size decodes without and with it). False: not a
    /// Bayer RAW (X-Trans and others), for the other denoiser.
    func denoiseRaw(_ input: URL, clean: URL, noisy: URL, lens: [URL], worker: Int = 1) async throws -> Bool {
        let answer = try await python(worker).ask(["do": "denoise_raw", "input": input.path, "output": clean.path, "noisy": noisy.path,
                                                   "weights": Self.rawDenoiserModel.path, "lens": lens.map(\.path)])
        return answer["ok"] as? Bool == true
    }

    /// The raw denoiser's own check (tests): its transform's round trip and noise fit, true when all hold.
    func rawDenoiseSelfTest() async throws -> Bool {
        try await python(1).ask(["do": "selftest_raw"])["ok"] as? Bool == true
    }

    /// The denoiser's own check (tests): how far its exposure curve's round trip is off, at worst (relative).
    func denoiseRoundTrip() async throws -> Double {
        // (A clean picture that isn't kept within the photo, the black blotches' cause, counts as failed.)
        let answer = try await python(1).ask(["do": "selftest"])
        return answer["settled"] as? Bool == true ? answer["roundtrip"] as? Double ?? 1 : 1
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

/// A photo's film: the stock, the paper it's printed on, and any setting changed from its
/// default (by darktable's name for it, "grain_amount").
struct FilmSettings: Codable, Hashable {
    var film = "kodak_portra_400"
    var paper = "kodak_portra_endura"
    var changed: [String: SettingValue] = [:]

    var settings: [String: Any] { changed.mapValues(\.json) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        film = try c.decodeIfPresent(String.self, forKey: .film) ?? "kodak_portra_400"
        paper = try c.decodeIfPresent(String.self, forKey: .paper) ?? "kodak_portra_endura"
        // Settings from the Python engine had dotted names ("camera.exposure_compensation_ev"):
        // the few with a counterpart carry over, the rest start from the film's own defaults.
        var settings = try c.decodeIfPresent([String: SettingValue].self, forKey: .changed) ?? [:]
        let renamed = ["camera.exposure_compensation_ev": "exposure_ev", "enlarger.y_filter_shift": "filter_y",
                       "enlarger.m_filter_shift": "filter_m", "film_render.halation.halation_amount": "halation_amount",
                       "film_render.dir_couplers.amount": "couplers_amount", "camera.diffusion_filter.strength": "diffusion_strength",
                       "camera.film_format_mm": "film_format_mm"]
        for (old, new) in renamed { if let value = settings[old] { settings[new] = value } }
        if case .number(let exposure)? = settings["enlarger.print_exposure"], exposure > 0 { settings["print_exposure_ev"] = .number(log2(exposure)) }
        for (old, new) in ["film_render.grain.active": "grain_on", "film_render.halation.active": "halation_on",
                           "camera.diffusion_filter.active": "diffusion_on"] {
            if case .flag(let on)? = settings[old] { settings[new] = .number(on ? 1 : 0) }
        }
        changed = settings.filter { !$0.key.contains(".") }
    }
}

/// One of the engine's processes (the film helper, or Python for denoise), started on first use
/// and kept: the film's tables stay built between renders. Jobs go one at a time.
@MainActor
final class FilmWorker {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    private func start() throws {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
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

    /// How many jobs were sent, all workers together (tests).
    static var asked = 0

    /// Sends a job and waits for its answer line.
    func ask(_ job: [String: Any]) async throws -> [String: Any] {
        Self.asked += 1
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
