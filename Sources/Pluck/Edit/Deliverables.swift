import AppKit
import Foundation

/// One edit, all deliverables: from a finished video, every version a client asks for: other
/// aspect ratios framed on the people in each shot, loudness for where it's going, subtitle
/// files in several languages, and everything named the way the client wants.
enum Deliverables {
    enum Format: String, CaseIterable, Identifiable, Sendable, Codable {
        case landscape, vertical, square, portrait
        var id: String { rawValue }

        var size: (width: Int, height: Int) {
            switch self {
            case .landscape: (1920, 1080)
            case .vertical: (1080, 1920)
            case .square: (1080, 1080)
            case .portrait: (1080, 1350)
            }
        }

        var aspect: Double { Double(size.width) / Double(size.height) }

        /// Watched on phones, mostly without sound: these get burned-in subtitles.
        var isSocial: Bool { self != .landscape }

        /// Room under burned-in subtitles, clear of the apps' buttons and captions.
        var subtitleMargin: Double {
            switch self {
            case .landscape: 0.06
            case .vertical: 0.24
            case .square: 0.09
            case .portrait: 0.14
            }
        }

        var label: String {
            switch self {
            case .landscape: String(localized: "16:9 Landscape")
            case .vertical: String(localized: "9:16 Vertical")
            case .square: String(localized: "1:1 Square")
            case .portrait: String(localized: "4:5 Portrait")
            }
        }

        /// In file names.
        var tag: String {
            switch self {
            case .landscape: "16x9"
            case .vertical: "9x16"
            case .square: "1x1"
            case .portrait: "4x5"
            }
        }
    }

    enum Loudness: String, CaseIterable, Identifiable, Sendable {
        case keep, online, ebu, atsc
        var id: String { rawValue }

        var label: String {
            switch self {
            case .keep: String(localized: "Keep as it is")
            case .online: String(localized: "Online: YouTube, Instagram, TikTok (−14 LUFS)")
            case .ebu: String(localized: "Broadcast, Europe: EBU R128 (−23 LUFS)")
            case .atsc: String(localized: "Broadcast, US: ATSC A/85 (−24 LKFS)")
            }
        }

        /// Integrated loudness and true peak.
        var target: (integrated: Double, peak: Double)? {
            switch self {
            case .keep: nil
            case .online: (-14, -1)
            case .ebu: (-23, -1)
            case .atsc: (-24, -2)
            }
        }
    }

    struct Naming: Sendable {
        var template = "{name}_{format}"
        var client = ""
        var project = ""
        var version = 1

        static let tokens = ["{name}", "{client}", "{project}", "{format}", "{lang}", "{version}", "{date}"]

        /// The file name (without extension). Empty fields leave no stray separators behind.
        func name(source: String, format: String, language: String?) -> String {
            var text = template
            if language != nil, !text.contains("{lang}") { text += "_{lang}" }
            let date = Date.now.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)",
                                                    timeZone: .current, calendar: Calendar(identifier: .gregorian)))
            let values = ["{name}": source, "{client}": client, "{project}": project, "{format}": format,
                          "{lang}": language ?? "", "{version}": String(format: "v%02d", version), "{date}": date]
            for (token, value) in values { text = text.replacingOccurrences(of: token, with: value) }
            // Separators left around empty fields: "Client__v01" → "Client_v01".
            while let range = text.range(of: #"([_\-. ])[_\-. ]+"#, options: .regularExpression) {
                text.replaceSubrange(range, with: String(text[range].first!))
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
            return Folders.sanitize(text.isEmpty ? source : text)
        }
    }

    struct Options: Sendable {
        var formats: [Format] = [.landscape, .vertical]
        var loudness: Loudness = .online
        var subtitles = true
        /// Languages to translate the subtitles into, besides the spoken one.
        var translations: [Locale.Language] = []
        var naming = Naming()
        var language: Locale?
        /// Subtitles burned into the social versions (9:16, 1:1, 4:5): nil for none, "" for
        /// the spoken language, or a translation's identifier.
        var burnIn: String?
    }

    // MARK: - Loudness

    /// The file's loudness as ffmpeg's loudnorm measures it (first pass).
    static func measure(_ file: URL, target: (integrated: Double, peak: Double), ffmpeg: String) async -> [String: String]? {
        let log = await ToolOutput.run(ffmpeg, ["-nostdin", "-hide_banner", "-i", file.path, "-vn", "-af",
            String(format: "loudnorm=I=%.1f:TP=%.1f:LRA=11:print_format=json", target.integrated, target.peak - 0.5), "-f", "null", "-"])
        guard let open = log.range(of: "{", options: .backwards), let close = log.range(of: "}", options: .backwards),
              open.lowerBound < close.lowerBound,
              let json = try? JSONSerialization.jsonObject(with: Data(log[open.lowerBound...close.lowerBound].utf8)) as? [String: String]
        else { return nil }
        return json
    }

    /// The second pass: a precise, linear gain to the target (no pumping), back at 48 kHz.
    static func loudnessFilter(target: (integrated: Double, peak: Double), measured: [String: String]) -> String {
        let value = { (key: String) in measured[key] ?? "0" }
        // Half a dB below the peak limit: AAC encoding adds a little on top.
        return String(format: "loudnorm=I=%.1f:TP=%.1f:LRA=11:", target.integrated, target.peak - 0.5)
            + "measured_I=\(value("input_i")):measured_TP=\(value("input_tp")):measured_LRA=\(value("input_lra")):"
            + "measured_thresh=\(value("input_thresh")):offset=\(value("target_offset")):linear=true:print_format=none,aresample=48000"
    }

    // MARK: - Framing

    /// The filter graph for one format (input [0:v], output [out]). Narrower than the source:
    /// each shot cropped on its people or subject (switched exactly on the cuts); shots with
    /// titles, and anything wider than the source, shown whole over a blurred fill.
    static func filterGraph(source: (width: Int, height: Int), format: Format, shots: [Shorts.Shot], commandFile: URL) throws -> String {
        let (tw, th) = format.size
        let sourceAspect = Double(source.width) / Double(source.height)
        let fill = "scale=\(tw):\(th):force_original_aspect_ratio=increase,crop=\(tw):\(th),gblur=sigma=36,eq=brightness=-0.12:saturation=1.1"
        let fitted = "scale=\(tw):\(th):force_original_aspect_ratio=decrease:flags=lanczos"
        if abs(sourceAspect - format.aspect) / format.aspect < 0.03 {
            // Same shape: scale (and pad the last few pixels).
            return "[0:v]\(fitted),pad=\(tw):\(th):(ow-iw)/2:(oh-ih)/2,setsar=1[out]"
        }
        if format.aspect > sourceAspect {
            // Wider than the source (a vertical video to 16:9): whole, over a blurred fill.
            return "[0:v]split=2[f1][f2];[f1]\(fill)[bg];[f2]\(fitted)[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1[out]"
        }
        let cropWidth = (Double(source.height) * format.aspect).rounded(.down)
        let fraction = cropWidth / Double(source.width)
        let x = { (centre: Double) in min(max((centre - fraction / 2) * Double(source.width), 0), Double(source.width) - cropWidth).rounded() }
        var positions: [(Double, Double)] = []
        var last = 0.5
        for shot in shots {
            if case .crop(let centre) = shot.framing { last = centre }
            positions.append((shot.start, x(last)))
        }
        try positions.map { String(format: "%.3f crop@frame x %.0f;", $0.0, $0.1) }.joined(separator: "\n")
            .write(to: commandFile, atomically: true, encoding: .utf8)
        let cropped = "sendcmd=f=\(FFmpegFilter.path(commandFile)),crop@frame=w=\(Int(cropWidth)):h=\(source.height):x=\(Int(positions.first?.1 ?? 0)):y=0,scale=\(tw):\(th):flags=lanczos,setsar=1"
        let fits = shots.filter { $0.framing == .fit }
        guard !fits.isEmpty else { return "[0:v]\(cropped)[out]" }
        let enable = fits.map { String(format: "between(t\\,%.3f\\,%.3f)", $0.start, $0.end - 0.001) }.joined(separator: "+")
        return "[0:v]split=3[c][f1][f2];[c]\(cropped)[cropped];[f1]\(fill)[bg];[f2]\(fitted)[fg];"
            + "[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1[whole];[cropped][whole]overlay=enable='\(enable)'[out]"
    }
}

// MARK: - The job

extension AIStudio {
    /// Makes every deliverable into a "(deliverables)" folder next to the video.
    func makeDeliverables(_ item: DownloadItem, options: Deliverables.Options) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                guard let size = await videoSize(file) else { throw Converting.Failure.noVideo }
                guard let ffmpegPath = toolPath("ffmpeg") else { throw Converting.Failure.noFFmpeg }
                var duration = 0.0
                if let ffprobe = toolPath("ffprobe") { duration = await Converting.probe(file, ffprobe: ffprobe)?.duration ?? 0 }
                guard duration > 0 else { throw Converting.Failure.noVideo }
                let source = file.deletingPathExtension().lastPathComponent
                let folder = Converting.outputFolder(in: file.deletingLastPathComponent(), name: source + String(localized: " (deliverables)"))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-deliverables-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                var made: [URL] = []

                // Loudness: measured once, applied the same to every version.
                var audioFilter: String?
                if let target = options.loudness.target {
                    item.aiStatus = String(localized: "Measuring loudness…")
                    if let measured = await Deliverables.measure(file, target: target, ffmpeg: ffmpegPath) {
                        audioFilter = Deliverables.loudnessFilter(target: target, measured: measured)
                    }
                }

                // Subtitles first (the social versions may burn them in): the spoken language,
                // then each translation.
                var tracks: [(id: String, cues: [Transcript.Cue])] = []
                if options.subtitles || options.burnIn != nil, #available(macOS 26, *), LocalAI.canTranscribe {
                    let transcript = try await existingOrNewTranscript(for: item, file: file, language: options.language)
                    let cues = transcript.cues()
                    let spoken = Locale(identifier: transcript.language)
                    tracks.append(("", cues))
                    var missing: [String] = []
                    for target in options.translations where target.languageCode != spoken.language.languageCode {
                        item.aiStatus = String(localized: "Translating subtitles…")
                        item.aiProgress = nil
                        guard await OnDeviceTranslation.isInstalled(from: spoken, to: target) else {
                            missing.append(TranslationTargetsMenu.name(of: target))
                            continue
                        }
                        tracks.append((target.minimalIdentifier, try await OnDeviceTranslation.translate(cues, from: spoken, to: target)))
                    }
                    if options.subtitles {
                        for track in tracks {
                            let language = track.id.isEmpty ? spoken.language : Locale.Language(identifier: track.id)
                            let code = (language.languageCode?.identifier ?? "orig").uppercased()
                            let url = folder.appendingPathComponent(options.naming.name(source: source, format: "", language: code))
                                .appendingPathExtension("srt")
                            try Transcript.srt(track.cues).write(to: url, atomically: true, encoding: .utf8)
                            made.append(url)
                        }
                    }
                    if !missing.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Some subtitle languages weren’t made")
                        alert.informativeText = String(localized: "Download these languages in System Settings → General → Language & Region → Translation Languages, then try again: \(missing.formatted(.list(type: .and))).")
                        alert.runModal()
                    }
                }
                let burned = options.burnIn.flatMap { choice in tracks.first { $0.id == choice } }?.cues
                let design = CaptionDesign.load(CaptionDesign.subtitlesKey)

                // Cuts once; the framing per shot depends on the format's width.
                let cuts = await Shorts.cuts(in: file, from: 0, to: duration, ffmpeg: ffmpegPath)
                for (index, format) in options.formats.enumerated() {
                    item.aiStatus = String(localized: "Framing \(format.label) (\(index + 1) of \(options.formats.count))…")
                    item.aiProgress = nil
                    let cropFraction = Double(size.1) * format.aspect / Double(size.0)
                    let shots = cropFraction < 0.97
                        ? await Shorts.shots(file, from: 0, to: duration, cuts: cuts, cropFraction: cropFraction)
                        : [Shorts.Shot(start: 0, end: duration, framing: .crop(0.5))]
                    var graph = try Deliverables.filterGraph(source: (size.0, size.1), format: format, shots: shots,
                                                             commandFile: work.appendingPathComponent("\(format.rawValue).txt"))
                    if format.isSocial, let burned {
                        let captions = work.appendingPathComponent("\(format.rawValue).ass")
                        try Captions.subtitles(burned, width: format.size.width, height: format.size.height, design: design,
                                               bottom: format.subtitleMargin).write(to: captions, atomically: true, encoding: .utf8)
                        graph = String(graph.dropLast("[out]".count)) + "[framed];[framed]\(Captions.filter(captions))[out]"
                    }
                    item.aiStatus = String(localized: "Writing \(format.label) (\(index + 1) of \(options.formats.count))…")
                    item.aiProgress = 0
                    let name = options.naming.name(source: source, format: format.tag, language: nil)
                    let output = Converting.outputURL(folder: folder.path, name: name, fileExtension: "mp4")
                    var args = ["-y", "-v", "error", "-progress", "pipe:1", "-nostats", "-i", file.path,
                                "-filter_complex", graph, "-map", "[out]", "-map", "0:a?",
                                "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p"]
                    if let audioFilter { args += ["-af", audioFilter] }
                    args += ["-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart", output.path]
                    try await ffmpeg(args, failure: Converting.Failure.noVideo, duration: duration, item: item)
                    made.append(output)
                }

                item.aiStatus = nil
                item.aiProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting(made.isEmpty ? [folder] : made)
            } catch {
                item.aiStatus = nil
                item.aiProgress = nil
                let alert = NSAlert()
                alert.messageText = String(localized: "The deliverables for “\(item.title)” couldn’t be made")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
