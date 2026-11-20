import SwiftUI

/// A Rec.709 viewing look on proxies of log footage, per shared folder (Off by default). Pluck writes its own .cube from
/// the published log curves and gamut primaries (no manufacturer LUT files), applied before the proxy is scaled.
/// Automatic reads metadata only (ffprobe tags, Sony's XML) and never guesses. Originals stay untouched; the proxy keeps
/// its name and timecode, and says which look it has (its "comment" tag), which the manifest passes on (`look`).
enum OfficeLook: String, CaseIterable, Identifiable, Sendable {
    case off, automatic, slog3, vlog, logc3, logc4, clog3
    var id: String { rawValue }

    static let settingsKey = "editAnywhereLooks"
    /// The proxies' tag: "pluck-look:slog3-709".
    static let tagPrefix = "pluck-look:"

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .automatic: String(localized: "Automatic")
        case .slog3: "S-Log3"
        case .vlog: "V-Log"
        case .logc3: "LogC3"
        case .logc4: "LogC4"
        case .clog3: "C-Log3"
        }
    }

    /// The manifest's name of the look ("slog3-709").
    var name: String { rawValue + "-709" }

    // MARK: - Settings (per share id, on the office Mac)

    static func setting(_ share: String) -> OfficeLook {
        (UserDefaults.standard.dictionary(forKey: settingsKey)?[share] as? String).flatMap(OfficeLook.init) ?? .off
    }

    static func set(_ look: OfficeLook, for share: String) {
        var all = UserDefaults.standard.dictionary(forKey: settingsKey) ?? [:]
        all[share] = look == .off ? nil : look.rawValue
        UserDefaults.standard.set(all, forKey: settingsKey)
    }

    // MARK: - Curves: log code value (0…1, full range) → scene linear (0.18 = mid grey)

    func linear(_ y: Double) -> Double {
        switch self {
        case .slog3:
            return y >= 171.2102946929 / 1023 ? pow(10, (y * 1023 - 420) / 261.5) * 0.19 - 0.01 : (y * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
        case .vlog:
            return y < 0.181 ? (y - 0.125) / 5.6 : pow(10, (y - 0.598206) / 0.241514) - 0.00873
        case .logc3:
            // EI 800.
            return y > 5.367655 * 0.010591 + 0.092809 ? (pow(10, (y - 0.385537) / 0.247190) - 0.052272) / 5.555556 : (y - 0.092809) / 5.367655
        case .logc4:
            let a = (pow(2.0, 18) - 16) / 117.45, b = (1023.0 - 95) / 1023, c = 95.0 / 1023
            let s = (7 * log(2.0) * pow(2, 7 - 14 * c / b)) / (a * b), t = (pow(2, 14 * (-c / b) + 6) - 64) / a
            return y >= 0 ? (pow(2, 14 * (y - c) / b + 6) - 64) / a : y * s + t
        case .clog3:
            let x: Double
            if y < 0.097465473 { x = -(pow(10, (0.12783901 - y) / 0.36726845) - 1) / 14.98325 }
            else if y <= 0.15277891 { x = (y - 0.12512219) / 1.9754798 }
            else { x = (pow(10, (y - 0.12240537) / 0.36726845) - 1) / 14.98325 }
            return x * 0.9
        case .off, .automatic:
            return y
        }
    }

    /// The camera gamut's primaries (CIE xy; all D65).
    var primaries: [(Double, Double)] {
        switch self {
        case .slog3: [(0.766, 0.275), (0.225, 0.800), (0.089, -0.087)]   // S-Gamut3.Cine
        case .vlog: [(0.730, 0.280), (0.165, 0.840), (0.100, -0.030)]    // V-Gamut
        case .logc3: [(0.684, 0.313), (0.221, 0.848), (0.0861, -0.102)]  // ARRI Wide Gamut 3
        case .logc4: [(0.7347, 0.2653), (0.1424, 0.8576), (0.0991, -0.0308)] // ARRI Wide Gamut 4
        case .clog3: [(0.74, 0.27), (0.17, 1.14), (0.08, -0.10)]         // Cinema Gamut
        case .off, .automatic: Self.rec709
        }
    }

    static let rec709: [(Double, Double)] = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
    static let d65 = (0.3127, 0.3290)

    typealias Matrix = [[Double]]

    /// RGB → XYZ from primaries and white (the usual construction).
    static func toXYZ(_ p: [(Double, Double)]) -> Matrix {
        let columns = p.map { [$0.0 / $0.1, 1, (1 - $0.0 - $0.1) / $0.1] }
        let m: Matrix = (0..<3).map { r in (0..<3).map { c in columns[c][r] } }
        let white = [d65.0 / d65.1, 1, (1 - d65.0 - d65.1) / d65.1]
        let s = multiply(invert(m), white)
        return (0..<3).map { r in (0..<3).map { c in m[r][c] * s[c] } }
    }

    static func multiply(_ a: Matrix, _ v: [Double]) -> [Double] { a.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } } }
    static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix { (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0) { $0 + a[r][$1] * b[$1][c] } } } }

    static func invert(_ m: Matrix) -> Matrix {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        func c(_ r: Int, _ k: Int) -> Double {
            let rows = (0..<3).filter { $0 != r }, cols = (0..<3).filter { $0 != k }
            return ((r + k) % 2 == 0 ? 1 : -1) * (m[rows[0]][cols[0]] * m[rows[1]][cols[1]] - m[rows[0]][cols[1]] * m[rows[1]][cols[0]])
        }
        return (0..<3).map { r in (0..<3).map { k in c(k, r) / det } }
    }

    /// Camera gamut → Rec.709.
    var gamut: Matrix { Self.multiply(Self.invert(Self.toXYZ(Self.rec709)), Self.toXYZ(primaries)) }

    /// Display: a soft shoulder above 0.5 (so highlights roll off), then the BT.709 curve.
    static func display(_ x: Double) -> Double {
        let toned = x <= 0.5 ? max(x, 0) : 1 - 0.5 * exp(-(x - 0.5) / 0.5)
        return toned < 0.018 ? 4.5 * toned : 1.099 * pow(toned, 0.45) - 0.099
    }

    /// One log code value triple → Rec.709 display values.
    func apply(_ rgb: [Double]) -> [Double] {
        Self.multiply(gamut, rgb.map(linear)).map { min(max(Self.display($0), 0), 1) }
    }

    /// The .cube (33 points, red fastest, as ffmpeg's lut3d reads it).
    func cube(size: Int = 33) -> String {
        var lines = ["TITLE \"Pluck \(label) to Rec.709 (viewing only)\"", "LUT_3D_SIZE \(size)"]
        lines.reserveCapacity(size * size * size + 2)
        let step = 1 / Double(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let out = apply([Double(r) * step, Double(g) * step, Double(b) * step])
            lines.append(String(format: "%.6f %.6f %.6f", out[0], out[1], out[2]))
        } } }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The .cube on disk (written once per look).
    func file() -> URL? {
        let url = OfficeProxies.root.deletingLastPathComponent().appendingPathComponent("Looks/\(name).cube")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? cube().write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    // MARK: - Which curve a file is in (metadata only)

    /// The look for a file under this setting: a chosen curve as is; Automatic from metadata, else none.
    static func look(for file: URL, setting: OfficeLook, ffprobe: String?) -> OfficeLook? {
        switch setting {
        case .off: return nil
        case .automatic: return detect(file, ffprobe: ffprobe)
        default: return RemoteEditHost.isRawClip(file, directory: RemoteEditHost.isDirectory(file)) ? nil : setting
        }
    }

    /// From words in the file's metadata (tags, Sony's sidecar M01.XML or the XML in the file).
    static func detect(_ file: URL, ffprobe: String?) -> OfficeLook? {
        guard !RemoteEditHost.isRawClip(file, directory: RemoteEditHost.isDirectory(file)) else { return nil }
        var text = ""
        if let ffprobe {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", file.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                text += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
            }
        }
        let base = file.deletingPathExtension()
        for sidecar in [base.path + "M01.XML", base.path + "M01.xml", base.path + ".XML", base.path + ".xml"] {
            if let xml = try? String(contentsOfFile: sidecar, encoding: .utf8) { text += xml }
        }
        // Sony keeps its XML (NRT metadata) inside MP4s too, near the start or the end: only its gamma line is read.
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            var raw = ""
            try? handle.seek(toOffset: 0)
            raw += String(decoding: (try? handle.read(upToCount: 1 << 20)) ?? Data(), as: UTF8.self)
            if size > 2 << 20 {
                try? handle.seek(toOffset: size - (1 << 20))
                raw += String(decoding: (try? handle.read(upToCount: 1 << 20)) ?? Data(), as: UTF8.self)
            }
            text += raw.matches(of: #/CaptureGammaEquation value="([^"]{1,40})"/#).map { " " + $0.1 }.joined()
        }
        return detect(text: text)
    }

    /// The look a proxy was made with (its tag), for the manifest.
    static func tagged(_ proxy: URL, ffprobe: String?) -> String? {
        guard let ffprobe else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-show_entries", "format_tags=comment", "-of", "default=noprint_wrappers=1:nokey=1", proxy.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return text.hasPrefix(tagPrefix) ? String(text.dropFirst(tagPrefix.count)) : nil
    }

    static func detect(text: String) -> OfficeLook? {
        let words = text.lowercased().replacingOccurrences(of: "_", with: "-")
        let found: [(OfficeLook, [String])] = [
            (.slog3, ["s-log3", "slog3"]), (.vlog, ["v-log", "vlog"]), (.logc4, ["logc4", "log-c4", "log c4"]),
            (.logc3, ["logc3", "log-c3", "log c3"]), (.clog3, ["c-log3", "clog3", "canon log 3"])]
        var hits = found.filter { _, names in names.contains { words.contains($0) } }.map(\.0)
        // (ARRI's older cameras just say "LogC": that's LogC3.)
        if hits.isEmpty, words.contains("logc") || words.contains("log-c") { hits = [.logc3] }
        // (Two curves named: not sure, so none.)
        return hits.count == 1 ? hits[0] : nil
    }
}

/// Proxies › Viewing look: per shared folder, with the warning. (Studio, office Mac.)
struct ViewingLookList: View {
    @State private var archive = OfficeArchive.shared
    @State private var changed = 0
    /// The folder whose look just changed: offered to remake the proxies already made.
    @State private var offer: String?
    private var proxies: OfficeProxies { OfficeProxies.shared }

    var body: some View {
        if !archive.folders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Viewing look").font(Design.Studio.sectionTitle)
                ForEach(archive.folders, id: \.self) { folder in
                    let id = OfficeProxies.id(folder)
                    HStack {
                        Text(verbatim: folder.lastPathComponent).font(Design.Studio.body).lineLimit(1)
                        Spacer()
                        Picker("Viewing look", selection: Binding(get: { _ = changed; return OfficeLook.setting(id) },
                                                                 set: { OfficeLook.set($0, for: id); changed += 1; offer = id })) {
                            ForEach(OfficeLook.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    let waiting = proxies.remaking.filter { $0.share == id }.count
                    if waiting > 0 {
                        Text("Remaking \(waiting) proxies with the new look…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    } else if offer == id {
                        HStack {
                            Text("Remake the proxies already made? One at a time; originals stay as they are.")
                                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Not Now") { offer = nil }.buttonStyle(StudioFlatButtonStyle(height: 26))
                            Button("Remake") {
                                offer = nil
                                Task { await proxies.remake(id) }
                            }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
                        }
                    }
                }
                Text("Only for cutting. Grades made on these proxies won’t match the render. Grade at the office or turn this off.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).fixedSize(horizontal: false, vertical: true)
                Text("Applies to proxies made from now on. Originals stay as they are.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
    }
}
