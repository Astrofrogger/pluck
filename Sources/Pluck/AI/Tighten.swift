import AppKit
import Foundation

/// Remove Silences & Fillers: finds long pauses in the sound and filler words ("uhm", "uh") in the
/// transcript, and cuts them out into a tightened copy. Optionally writes an edit list (EDL) with
/// the same cuts, for DaVinci Resolve and Premiere Pro.
enum Tighten {
    enum Pace: String, CaseIterable, Identifiable, Codable {
        case tight, natural, relaxed
        var id: String { rawValue }

        var label: String {
            switch self {
            case .tight: String(localized: "Tight")
            case .natural: String(localized: "Natural")
            case .relaxed: String(localized: "Relaxed")
            }
        }

        var detail: String {
            switch self {
            case .tight: String(localized: "Cuts every pause longer than a third of a second. Fast, like a vlog.")
            case .natural: String(localized: "Cuts pauses longer than about half a second, keeping a natural rhythm.")
            case .relaxed: String(localized: "Only cuts pauses longer than a second.")
            }
        }

        /// Pauses at least this long are shortened.
        var threshold: Double {
            switch self {
            case .tight: 0.35
            case .natural: 0.6
            case .relaxed: 1.0
            }
        }

        /// How much of a shortened pause is left on each side of it, so speech isn't clipped
        /// and breaths sound natural.
        var padding: Double {
            switch self {
            case .tight: 0.08
            case .natural: 0.14
            case .relaxed: 0.22
            }
        }
    }

    struct Options {
        var pace: Pace = .natural
        /// Also remove filler words (needs a transcript, macOS 26).
        var fillers = true
        /// The spoken language, for the transcript the filler words are found in.
        var language: Locale?
        /// Also save an edit list for video editors (videos only).
        var editList = false
        /// Also build the tightened timeline in the project open in DaVinci Resolve (videos only).
        var resolveTimeline = false
    }

    // MARK: - Finding what to cut

    /// Filler sounds per language, as Apple's speech recognizer writes them. Only sounds that
    /// aren't also real words in that language.
    static func fillerWords(for language: Locale?) -> Set<String> {
        let common: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "hmm", "hm", "mm", "mmm", "ehm", "euhm"]
        switch language?.language.languageCode?.identifier {
        case "en": return common.union(["ah", "er", "erm", "eh"])
        case "nl": return common.union(["eh", "euh", "ehh"])
        case "de": return common.union(["äh", "ähm", "öhm", "eh"])
        case "fr": return common.union(["euh", "heu", "eh"])
        case "es", "it", "pt": return common.union(["eh", "ehh", "em", "ehm"])
        default: return common
        }
    }

    /// Filler words, cut out whole (with the bit of pause the recognizer counts with them).
    static func fillerCuts(_ words: [Transcript.Word], language: Locale?) -> [ClosedRange<Double>] {
        let fillers = fillerWords(for: language)
        return words.compactMap { word in
            let bare = word.t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard fillers.contains(bare), word.e - word.s > 0.06 else { return nil }
            return (word.s + 0.02)...(word.e - 0.02)
        }
    }

    /// Long pauses, shortened to the pace's padding on either side.
    static func pauseCuts(_ silences: [ClosedRange<Double>], pace: Pace, duration: Double) -> [ClosedRange<Double>] {
        silences.compactMap { silence in
            guard silence.upperBound - silence.lowerBound >= pace.threshold else { return nil }
            // Silence at the very start or end goes completely (apart from a short lead-in).
            let start = silence.lowerBound <= 0.05 ? 0 : silence.lowerBound + pace.padding
            let end = silence.upperBound >= duration - 0.05 ? duration : silence.upperBound - pace.padding
            return end - start > 0.05 ? start...end : nil
        }
    }

    /// The parts to keep, in order: everything outside the cuts, without slivers too short to
    /// matter.
    static func keeps(duration: Double, cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let cut = max(cut.lowerBound, 0)...min(cut.upperBound, duration)
            guard cut.upperBound > cut.lowerBound else { continue }
            if let last = merged.last, cut.lowerBound <= last.upperBound + 0.1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cut.upperBound)
            } else {
                merged.append(cut)
            }
        }
        var keeps: [ClosedRange<Double>] = []
        var position = 0.0
        for cut in merged {
            if cut.lowerBound - position >= 0.08 { keeps.append(position...cut.lowerBound) }
            position = cut.upperBound
        }
        if duration - position >= 0.08 { keeps.append(position...duration) }
        return keeps
    }

    /// The parts moved onto whole video frames, so every cut falls between two frames and the
    /// picture stays exactly in sync with the sound.
    static func snapped(_ keeps: [ClosedRange<Double>], fps: Double) -> [ClosedRange<Double>] {
        guard fps > 0 else { return keeps }
        return keeps.compactMap { keep in
            let start = (keep.lowerBound * fps).rounded() / fps, end = (keep.upperBound * fps).rounded() / fps
            return end > start ? start...end : nil
        }
    }

    // MARK: - Reading the sound

    /// Pauses in the file's sound. "Quiet" is set between the recording's own noise floor and its
    /// speech level, so a noisy room or a quiet microphone works too. Measured in 10 ms steps;
    /// a click or two inside a pause doesn't end it.
    static func silences(in file: URL, ffmpeg: String, minimum: Double) async -> [ClosedRange<Double>] {
        let log = await ToolOutput.run(ffmpeg, [
            "-nostdin", "-v", "error", "-i", file.path, "-vn",
            "-af", "aresample=16000,aformat=channel_layouts=mono,asetnsamples=n=160:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
            "-f", "null", "-"])
        var levels: [Double] = []
        for line in log.split(separator: "\n") where line.hasPrefix("lavfi.astats.Overall.RMS_level=") {
            let value = Double(line.dropFirst("lavfi.astats.Overall.RMS_level=".count)) ?? -120
            levels.append(value.isFinite ? max(value, -120) : -120)
        }
        return silences(levels: levels, step: 0.01, minimum: minimum)
    }

    /// Runs of quiet windows at least `minimum` long, from one loudness value (dB) per `step`.
    static func silences(levels: [Double], step: Double, minimum: Double) -> [ClosedRange<Double>] {
        guard levels.count > 10 else { return [] }
        let sorted = levels.sorted()
        let noise = sorted[sorted.count / 10], speech = sorted[sorted.count * 95 / 100]
        // No real difference between quiet and loud parts: nothing to cut.
        guard speech - noise >= 10 else { return [] }
        let threshold = min(noise + max(6, (speech - noise) * 0.35), speech - 10)
        var result: [ClosedRange<Double>] = []
        var start: Int?
        var loudRun = 0
        for (index, level) in levels.enumerated() {
            if level < threshold {
                if start == nil { start = index }
                loudRun = 0
            } else if let s = start {
                loudRun += 1
                // Three loud windows in a row (30 ms) end the pause, where the sound came back.
                if loudRun >= 3 {
                    let end = index - loudRun + 1
                    if Double(end - s) * step >= minimum { result.append(Double(s) * step...Double(end) * step) }
                    start = nil
                    loudRun = 0
                }
            }
        }
        if let s = start, Double(levels.count - loudRun - s) * step >= minimum {
            result.append(Double(s) * step...Double.greatestFiniteMagnitude)
        }
        return result
    }

    // MARK: - Making the copy

    /// ffmpeg filters that keep only the given parts, video and sound in sync. Video frames keep
    /// their own timing minus the time cut before them; sound is cut to the millisecond.
    static func filterGraph(keeps: [ClosedRange<Double>], video: Bool) -> String {
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        // Each part includes its first frame but not the one at its end (that's the next part's
        // first), with a hair of slack for timestamps that aren't exact.
        let select = keeps.map { "gte(t\\,\(number($0.lowerBound - 0.0005)))*lt(t\\,\(number($0.upperBound - 0.0005)))" }
            .joined(separator: "+")
        var graph = "[0:a]asetnsamples=n=64:p=0,aselect='\(select)',asetpts=N/SR/TB[a]"
        guard video else { return graph }
        // Each part starts where the previous one ended: subtract the gaps before it.
        var shift: [String] = [number(keeps.first?.lowerBound ?? 0)]
        for index in keeps.indices.dropFirst() {
            let gap = keeps[index].lowerBound - keeps[index - 1].upperBound
            shift.append("gt(T\\,\(number(keeps[index].lowerBound - 0.0005)))*\(number(gap))")
        }
        graph = "[0:v]select='\(select)',setpts='(T-(\(shift.joined(separator: "+"))))/TB'[v];" + graph
        return graph
    }

    // MARK: - Edit list

    /// A CMX 3600 edit list with one event per kept part, for importing into DaVinci Resolve
    /// (File › Import › Timeline) or Premiere Pro (File › Import), then linking to the original.
    /// Drop-frame when the source's timecode is (29.97/59.94 DF), so a long clip doesn't drift.
    /// The reel is the source's own (how Resolve relinks), else the file name's first 8 characters.
    static func edl(keeps: [ClosedRange<Double>], title: String, clipName: String, fps: Double, startTimecode: String?, reel: String? = nil) -> String {
        let reel = (reel ?? String((clipName as NSString).deletingPathExtension.prefix(8))).replacingOccurrences(of: " ", with: "_")
        let base = DropFrame.base(fps)
        // 23.976 and 29.97 exactly, not as rounded by the probe.
        let fps = abs(fps - Double(base) * 1000 / 1001) < 0.01 ? Double(base) * 1000 / 1001 : fps
        let drop = DropFrame.canDrop(fps) && (startTimecode.map(DropFrame.isDrop) ?? false)
        func tc(_ frames: Int) -> String { DropFrame.string(frames, base: base, drop: drop) }
        let sourceStart = startTimecode.flatMap { DropFrame.frames($0, base: base, drop: drop) } ?? 0
        // 01:00:00:00, where editors start their timelines.
        var record = DropFrame.frames("01:00:00:00", base: base, drop: drop) ?? 3600 * base
        var lines = ["TITLE: \(title)", drop ? "FCM: DROP FRAME" : "FCM: NON-DROP FRAME", ""]
        for (index, keep) in keeps.enumerated() {
            let sourceIn = sourceStart + Int((keep.lowerBound * fps).rounded())
            let sourceOut = sourceStart + Int((keep.upperBound * fps).rounded())
            guard sourceOut > sourceIn else { continue }
            let length = sourceOut - sourceIn
            let event = String(format: "%03d", index + 1)
            lines.append("\(event)  \(reel.padding(toLength: max(8, reel.count), withPad: " ", startingAt: 0)) AA/V  C        \(tc(sourceIn)) \(tc(sourceOut)) \(tc(record)) \(tc(record + length))")
            lines.append("* FROM CLIP NAME: \(clipName)")
            lines.append("")
            record += length
        }
        return lines.joined(separator: "\n")
    }

    /// The timecode the file starts at (cameras often start at 01:00:00:00 or time of day).
    static func startTimecode(of file: URL, ffprobe: String) async -> String? {
        let output = await ToolOutput.run(ffprobe, ["-v", "error", "-show_entries", "format_tags=timecode:stream_tags=timecode",
                                                    "-of", "default=noprint_wrappers=1:nokey=1", file.path])
        return output.split(separator: "\n").map(String.init).first { DropFrame.frames($0, base: 1000, drop: false) != nil }
    }
}

extension Tighten {
    /// Sets a timeline's drop-frame timecode (a timeline setting only counts with its own settings on).
    /// A pure function, tested on its own with a stand-in timeline.
    static let setDropFrame = #"""
def set_drop_frame(timeline, drop):
    timeline.SetSetting("useCustomSettings", "1")
    return bool(timeline.SetSetting("timelineDropFrameTimecode", "1" if drop else "0"))
"""#

    /// The timeline named in the instruction, in the open project, set to drop-frame or not.
    static let dropFrameScript = ResolveBridge.preamble + "\n" + setDropFrame + "\n" + #"""
project = pm.GetCurrentProject()
if project is None:
    out({"error": "No project is open in DaVinci Resolve."})
for index in range(1, project.GetTimelineCount() + 1):
    timeline = project.GetTimelineByIndex(index)
    if timeline and timeline.GetName() == cmd["timeline"]:
        out({"set": set_drop_frame(timeline, cmd["drop"])})
out({"error": "noTimeline"})
"""#
}

/// Runs a helper tool and returns everything it printed (ffmpeg's measurements go to stderr).
enum ToolOutput {
    static func run(_ tool: String, _ arguments: [String]) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

extension Tighten {
    enum Failure: LocalizedError {
        case nothingToCut, noSound

        var errorDescription: String? {
            switch self {
            case .nothingToCut: String(localized: "There are no pauses or filler words to remove at this setting.")
            case .noSound: String(localized: "Pluck couldn’t read the sound of this file.")
            }
        }
    }
}

extension AIStudio {
    /// Makes a "(tightened)" copy next to the file, without long pauses (and filler words).
    func tighten(_ item: DownloadItem, options: Tighten.Options) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                guard let ffmpegPath = toolPath("ffmpeg") else { throw Converting.Failure.noFFmpeg }
                let ffprobe = toolPath("ffprobe")
                let info = if let ffprobe { await Converting.probe(file, ffprobe: ffprobe) } else { Converting.MediaInfo?.none }
                guard let duration = info?.duration ?? item.duration, duration > 0, info?.audioCodec != nil else { throw Tighten.Failure.noSound }
                let video = Self.isVideo(file) && info?.videoCodec != nil

                item.aiStatus = String(localized: "Finding pauses…")
                let silences = await Tighten.silences(in: file, ffmpeg: ffmpegPath, minimum: options.pace.threshold)
                var cuts = Tighten.pauseCuts(silences, pace: options.pace, duration: duration)
                var fillerCount = 0
                if options.fillers, #available(macOS 26, *), LocalAI.canTranscribe {
                    let transcript = if let language = options.language {
                        try await transcript(for: item, file: file, language: language)
                    } else {
                        try await existingOrNewTranscript(for: item, file: file)
                    }
                    let fillers = Tighten.fillerCuts(transcript.words, language: Locale(identifier: transcript.language))
                    fillerCount = fillers.count
                    cuts += fillers
                }
                var keeps = Tighten.keeps(duration: duration, cuts: cuts)
                if video, let fps = info?.fps { keeps = Tighten.snapped(keeps, fps: fps) }
                let kept = keeps.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                guard !keeps.isEmpty, duration - kept >= 0.3 else { throw Tighten.Failure.nothingToCut }

                item.aiStatus = String(localized: "Cutting…")
                item.aiProgress = 0
                let name = file.deletingPathExtension().lastPathComponent + String(localized: " (tightened)")
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path, name: name,
                                                  fileExtension: video ? "mp4" : "m4a")
                var args = ["-y", "-v", "error", "-progress", "pipe:1", "-nostats", "-i", file.path,
                            "-filter_complex", Tighten.filterGraph(keeps: keeps, video: video)]
                args += video ? ["-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"]
                              : ["-map", "[a]"]
                args += ["-c:a", "aac", "-b:a", video ? "192k" : "256k", "-movflags", "+faststart", output.path]
                try await ffmpeg(args, failure: Tighten.Failure.noSound, duration: kept, item: item)

                var files = [output]
                let timecode = if let ffprobe, video { await Tighten.startTimecode(of: file, ffprobe: ffprobe) } else { String?.none }
                if options.editList, video {
                    let reel = if let ffprobe {
                        FrameRewriter.sourceTags(await ToolOutput.run(ffprobe, ["-v", "error", "-show_entries", "format_tags=reel_name:stream_tags=reel_name",
                                                                               "-of", "json", file.path])).reel
                    } else { String?.none }
                    let edl = output.deletingPathExtension().appendingPathExtension("edl")
                    try Tighten.edl(keeps: keeps, title: output.deletingPathExtension().lastPathComponent, clipName: file.lastPathComponent,
                                    fps: info?.fps ?? 25, startTimecode: timecode, reel: reel)
                        .write(to: edl, atomically: true, encoding: .utf8)
                    files.append(edl)
                }
                // The cuts on the original clip in Resolve: a failure there still leaves the copy.
                var resolveProblem: Error?
                if options.resolveTimeline, video {
                    item.aiStatus = String(localized: "Sending to DaVinci Resolve…")
                    item.aiProgress = nil
                    do {
                        let timeline = try await MarkedTimeline.buildCuts(name: output.deletingPathExtension().lastPathComponent, bin: "Pluck",
                                                                          cuts: keeps.map { MarkedTimeline.Cut(file: file, start: $0.lowerBound, end: $0.upperBound) })
                        // Its timecode counted like the source's: drop-frame for 29.97/59.94 DF footage.
                        let drop = DropFrame.canDrop(info?.fps ?? 0) && (timecode.map(DropFrame.isDrop) ?? false)
                        _ = try await ResolveBridge.run(["action": "dropFrame", "timeline": timeline, "drop": drop], script: Tighten.dropFrameScript)
                        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app"),
                                                                          configuration: NSWorkspace.OpenConfiguration())
                    } catch {
                        resolveProblem = error
                    }
                }
                finishJob(item)
                if let resolveProblem {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn’t send to DaVinci Resolve")
                    alert.informativeText = resolveProblem.localizedDescription
                    alert.runModal()
                }
                let removed = Format.duration(duration - kept)
                notify(title: String(localized: "“\(item.title)” is tightened"),
                       body: fillerCount > 0 ? String(localized: "Removed \(removed) of pauses and \(fillerCount) filler words.")
                                             : String(localized: "Removed \(removed) of pauses."),
                       files: [output])
                NSWorkspace.shared.activateFileViewerSelecting(files)
            } catch {
                failJob(item, error)
            }
        }
    }
}
