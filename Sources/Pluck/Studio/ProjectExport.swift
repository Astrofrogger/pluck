import Foundation
import SwiftUI

/// A project's export: every clip in turn (each fitted to the project's frame), the music mixed
/// under it, the titles drawn in, written with the render settings by ffmpeg from the original
/// files.
@MainActor
@Observable
final class ProjectExports {
    private(set) var progress: Double?
    private(set) var output: URL?
    private(set) var problem: String?
    private(set) var finished: [URL] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { progress != nil }

    /// Stops the export; what was written so far is thrown away.
    func stop() { task?.cancel() }

    func run(_ project: Project, settings: EditorRenderSettings, audioOnly: Bool, size: CGSize, fps: Double, lengths: [String: Double] = [:],
             manager: DownloadManager) {
        runAll([(project, project.name)], settings: settings, audioOnly: audioOnly, size: size, fps: fps, lengths: lengths, manager: manager)
    }

    /// Each clip of the main line as a file of its own (the music and titles under it come
    /// along), numbered in order; only those in `range` when there's one.
    func runEach(_ project: Project, range: ClosedRange<Double>? = nil, settings: EditorRenderSettings, audioOnly: Bool, size: CGSize,
                 fps: Double, lengths: [String: Double] = [:], manager: DownloadManager) {
        var at = 0.0
        var parts: [(Project, String)] = []
        for clip in project.clips {
            defer { at += clip.length }
            var span = at...(at + clip.length)
            if let range {
                guard span.upperBound > range.lowerBound + 0.01, span.lowerBound < range.upperBound - 0.01 else { continue }
                span = max(span.lowerBound, range.lowerBound)...min(span.upperBound, range.upperBound)
            }
            var part = project.cut(to: span)
            // On its own: no dissolve into the clip before or after.
            for index in part.clips.indices { part.clips[index].transitionIn = nil }
            parts.append((part, String(format: "%@ %02d", project.name, parts.count + 1)))
        }
        runAll(parts, settings: settings, audioOnly: audioOnly, size: size, fps: fps, lengths: lengths, manager: manager)
    }

    private func runAll(_ jobs: [(project: Project, name: String)], settings: EditorRenderSettings, audioOnly: Bool, size: CGSize, fps: Double,
                        lengths: [String: Double], manager: DownloadManager) {
        let jobs = jobs.filter { !$0.project.clips.isEmpty }
        guard !jobs.isEmpty else { return }
        guard let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            problem = Converting.Failure.noFFmpeg.localizedDescription
            return
        }
        output = nil
        problem = nil
        let missing = jobs.reduce(into: Set<String>()) { $0.formUnion(ProjectModel.missingFiles(in: $1.project)) }
        guard missing.isEmpty else {
            let names = missing.map { ($0 as NSString).lastPathComponent }.sorted()
            problem = String(localized: "Offline: \(names.prefix(3).formatted(.list(type: .and)))\(names.count > 3 ? "…" : "")")
            return
        }
        progress = 0
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        task = Task {
            var made: [URL] = []
            defer { Self.announce(made, total: jobs.count, problem: problem, cancelled: Task.isCancelled, manager: manager) }
            for (number, job) in jobs.enumerated() {
                guard !Task.isCancelled else { break }
                let output = Converting.outputURL(folder: folder, name: job.name,
                                                  fileExtension: audioOnly ? settings.audioFile.rawValue : settings.container.fileExtension)
                let done = await render(job.project, to: output, settings: settings, audioOnly: audioOnly, size: size, fps: fps,
                                        lengths: lengths, ffmpeg: ffmpeg, ffprobe: ffprobe) { value in
                    self.progress = (Double(number) + value) / Double(jobs.count)
                }
                guard done else { break }
                self.output = output
                finished.insert(output, at: 0)
                made.append(output)
                _ = manager.addLocalFiles([output])
            }
            manager.saveHistory()
            progress = nil
            task = nil
        }
    }

    /// Word that an export is done (or why not), for when Pluck is in the background.
    static func announce(_ made: [URL], total: Int, problem: String?, cancelled: Bool, manager: DownloadManager) {
        guard !cancelled else { return }
        if made.count == total, let first = made.first {
            manager.notify(title: String(localized: "Export done"),
                           body: made.count == 1 ? first.lastPathComponent : String(localized: "\(made.count) files"), files: made)
        } else {
            manager.notify(title: String(localized: "Export stopped"), body: problem ?? String(localized: "\(made.count) of \(total) files were made."), files: made)
        }
    }

    /// One file of the project; true when it's written.
    private func render(_ project: Project, to output: URL, settings: EditorRenderSettings, audioOnly: Bool, size: CGSize, fps: Double,
                        lengths: [String: Double], ffmpeg: String, ffprobe: String, progress: @escaping @MainActor (Double) -> Void) async -> Bool {
        // What each file has: a picture, sound or both.
        var streams: [String: Set<String>] = [:]
        let items = (project.tracks ?? []).flatMap(\.items).map(\.path)
        for path in Set(project.clips.map(\.path) + project.music.map(\.path) + items) {
            streams[path] = await Self.streams(of: path, ffprobe: ffprobe)
        }
        var subtitleFile: URL?
        let cues = project.subtitlesOn == true ? project.subtitleCues : []
        if !audioOnly, !cues.isEmpty {
            let ass = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-project-\(UUID().uuidString)-subtitles.ass")
            let text = EditorSubtitleFiles.ass(cues, style: project.subtitleLook, width: Int(size.width), height: Int(size.height))
            if (try? text.write(to: ass, atomically: true, encoding: .utf8)) != nil { subtitleFile = ass }
        }
        var assFile: URL?
        if !audioOnly, !project.titles.isEmpty {
            let ass = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-project-\(UUID().uuidString).ass")
            let titles = project.titles.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
            let text = EditorSubtitleFiles.ass(titles, style: project.titleStyle, width: Int(size.width), height: Int(size.height))
            if (try? text.write(to: ass, atomically: true, encoding: .utf8)) != nil { assFile = ass }
        }
        let arguments = { (hardware: Bool) in
            Self.arguments(project, streams: streams, lengths: lengths, settings: settings, audioOnly: audioOnly, size: size, fps: fps,
                           titles: assFile, subtitles: subtitleFile, hardware: hardware, output: output)
        }
        let report: @Sendable (Double) -> Void = { value in Task { @MainActor in progress(value) } }
        let hardware = !audioOnly && settings.hardware && !settings.codec.isProRes
        var outcome = EditorExport.Outcome.stopped
        if !Task.isCancelled { outcome = await EditorExport.run(ffmpeg, arguments(hardware), total: project.duration, progress: report) }
        if outcome.isFailed, hardware, !Task.isCancelled {
            report(0)
            outcome = await EditorExport.run(ffmpeg, arguments(false), total: project.duration, progress: report)
        }
        if outcome.isFailed, ScreenshotMode.scene != nil {
            // Tests: the command, to run by hand.
            let tail = if case .failed(let lines) = outcome { lines } else { "" }
            try? ([ffmpeg] + arguments(false) + ["", tail]).joined(separator: "\n")
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pluck-project-export.txt"), atomically: true, encoding: .utf8)
        }
        if let assFile { try? FileManager.default.removeItem(at: assFile) }
        if let subtitleFile { try? FileManager.default.removeItem(at: subtitleFile) }
        if outcome.isDone {
            // The subtitles as a file too, next to the video.
            if !cues.isEmpty {
                try? EditorSubtitleFiles.srt(cues).write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            }
            return true
        }
        try? FileManager.default.removeItem(at: output)
        problem = EditorExport.readable(outcome)
        return false
    }

    nonisolated private static func streams(of path: String, ffprobe: String) async -> Set<String> {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "csv=p=0", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var kinds: Set<String> = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: ",")
                guard let kind = fields.first else { continue }
                // Cover art isn't a picture to show.
                if kind == "video", fields.count > 1, fields[1] == "1" { continue }
                kinds.insert(String(kind))
            }
            return kinds
        }.value
    }

    /// atempo steps that multiply to this speed.
    nonisolated static func tempo(_ speed: Double) -> String {
        var left = speed, steps: [String] = []
        while left > 2 { steps.append("atempo=2"); left /= 2 }
        while left < 0.5 { steps.append("atempo=0.5"); left /= 0.5 }
        steps.append(String(format: "atempo=%.5f", left))
        return steps.joined(separator: ",")
    }

    nonisolated static func videoChain(input: String, clip: ProjectClip, k: Int, width: Int, height: Int, rate: String) -> [String] {
        ClipLook.ffmpegChain(input: input, start: clip.start, end: clip.end, length: clip.length, look: clip.look, k: k,
                             width: width, height: height, rate: rate, path: clip.path)
    }

    nonisolated static func arguments(_ project: Project, streams: [String: Set<String>], lengths: [String: Double] = [:], settings: EditorRenderSettings,
                                              audioOnly: Bool, size: CGSize, fps: Double, titles: URL?, subtitles: URL?, hardware: Bool,
                                              output: URL) -> [String] {
        let width = Int(size.width) / 2 * 2, height = Int(size.height) / 2 * 2
        let rate = String(format: "%.3f", max(fps, 1))
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        // The files, each opened where it's first needed. A clip earlier in a file than the one
        // before it opens the file again (seeking there), so ffmpeg never holds the frames in between.
        // (A clip's picture and sound share one.)
        var opened: [(path: String, from: Double, to: Double, last: Double)] = []
        func input(_ path: String, _ start: Double, _ end: Double) -> (index: Int, from: Double) {
            if let i = opened.lastIndex(where: { $0.path == path && ($0.to <= start + 0.001 || $0.last == start) }) {
                opened[i].to = max(opened[i].to, end)
                opened[i].last = start
                return (i, opened[i].from)
            }
            opened.append((path, start, end, start))
            return (opened.count - 1, start)
        }
        var graph: [String] = []
        let clips = project.clips
        // Dissolves take frames from either side of the cut (as the preview does).
        let overlap = ProjectModel.dissolveOverlaps(clips, lengths: lengths)
        var segments: [(video: String, audio: String, length: Double)] = []
        for (k, clip) in clips.enumerated() {
            let kinds = streams[clip.path] ?? []
            let before = overlap[k], after = k + 1 < clips.count ? overlap[k + 1] : 0
            let start = clip.start - before * clip.speed, end = clip.end + after * clip.speed
            let length = clip.length + before + after
            if !audioOnly {
                if kinds.contains("video") {
                    // Stabilized clips' pictures come from their steadied copies.
                    let copy = clip.look?.stabilize == true ? Stabilizer.copy(for: clip.path)?.path : nil
                    // Dips to black or white at the edits, as the preview draws them.
                    var finish: [String] = []
                    if k > 0, let dip = clips[k - 1].dipOut {
                        let half = min(dip.length / 2, clip.length / 2)
                        finish.append("fade=t=in:st=\(number(before)):d=\(number(half)):color=\(dip.white ? "white" : "black")")
                    }
                    if let dip = clip.dipOut {
                        let half = min(dip.length / 2, clip.length / 2)
                        finish.append("fade=t=out:st=\(number(before + max(clip.length - half, 0))):d=\(number(half)):color=\(dip.white ? "white" : "black")")
                    }
                    if let freeze = clip.freeze {
                        // One frame, held for the clip's length.
                        let (v, from) = input(copy ?? clip.path, freeze, freeze + 1)
                        graph += ClipLook.ffmpegChain(input: "[\(v):v:0]", start: freeze - from, end: freeze - from + 1, length: length,
                                                      look: clip.look, k: k, width: width, height: height, rate: rate,
                                                      steadied: copy != nil, finish: finish, hold: length, path: clip.path)
                    } else {
                        let (v, from) = input(copy ?? clip.path, max(start, 0), end)
                        graph += ClipLook.ffmpegChain(input: "[\(v):v:0]", start: start - from, end: end - from,
                                                      length: length, look: clip.look, k: k, width: width, height: height, rate: rate,
                                                      steadied: copy != nil, finish: finish, path: clip.path)
                    }
                } else {
                    graph.append("color=black:s=\(width)x\(height):r=\(rate):d=\(number(length)),format=yuv420p[v\(k)]")
                }
            }
            var audio: String
            // Its own sound, unless it was taken off to a track of its own or it's a held frame.
            if kinds.contains("audio"), clip.ownAudio != false, clip.freeze == nil {
                let (i, from) = input(clip.path, max(start, 0), end)
                audio = "[\(i):a:0]atrim=start=\(number(start - from)):end=\(number(end - from)),asetpts=PTS-STARTPTS,volume=\(number(clip.volume))"
                // Faster or slower, at the same pitch (atempo goes from half to double speed per step).
                if clip.speed != 1 { audio += "," + tempo(clip.speed) }
            } else {
                audio = "anullsrc=r=48000:cl=stereo,atrim=duration=\(number(length))"
            }
            let fade = fades(clip.fadeIn, clip.fadeOut, over: clip.length)
            if fade.in > 0 { audio += ",afade=t=in:st=\(number(before)):d=\(number(fade.in))" }
            if fade.out > 0 { audio += ",afade=t=out:st=\(number(before + max(clip.length - fade.out, 0))):d=\(number(fade.out))" }
            graph.append(audio + ",aformat=sample_rates=48000:channel_layouts=stereo[a\(k)]")
            segments.append(("[v\(k)]", "[a\(k)]", length))
        }
        // Runs of clips cut together, joined to the next run by a dissolve.
        var runs: [(video: String, audio: String, length: Double, overlap: Double)] = []
        var start = 0
        for k in 1...clips.count where k == clips.count || overlap[k] > 0 {
            let run = segments[start..<k]
            let label = "r\(runs.count)"
            if run.count == 1 {
                runs.append((run.first!.video, run.first!.audio, run.first!.length, overlap[start]))
            } else {
                let joined = run.map { (audioOnly ? "" : $0.video) + $0.audio }.joined()
                graph.append("\(joined)concat=n=\(run.count):v=\(audioOnly ? 0 : 1):a=1\(audioOnly ? "" : "[\(label)v]")[\(label)a]")
                runs.append(("[\(label)v]", "[\(label)a]", run.reduce(0) { $0 + $1.length }, overlap[start]))
            }
            start = k
        }
        var video = runs[0].video, audio = runs[0].audio, length = runs[0].length
        for (r, run) in runs.enumerated().dropFirst() {
            let blend = run.overlap * 2
            if !audioOnly {
                graph.append("\(video)\(run.video)xfade=transition=fade:duration=\(number(blend)):offset=\(number(max(length - blend, 0)))[x\(r)v]")
                video = "[x\(r)v]"
            }
            graph.append("\(audio)\(run.audio)acrossfade=d=\(number(blend))[x\(r)a]")
            audio = "[x\(r)a]"
            length += run.length - blend
        }
        // The picture so far (each layer laid over it gives a new one).
        var picture = video
        graph.append("\(audio)anull[ac]")
        // Pictures laid over the main line, each from its moment on, see-through around it.
        if !audioOnly {
            var layer = 0
            for track in project.tracks ?? [] where track.kind == .video && !track.hidden {
                for item in track.items where streams[item.path]?.contains("video") == true {
                    let k = 10_000 + layer
                    let at = item.at ?? 0
                    var finish: [String] = []
                    if item.fadeIn > 0 { finish.append("fade=t=in:st=0:d=\(number(item.fadeIn)):alpha=1") }
                    if item.fadeOut > 0 { finish.append("fade=t=out:st=\(number(max(item.length - item.fadeOut, 0))):d=\(number(item.fadeOut)):alpha=1") }
                    let (v, from) = input(item.path, item.start, item.end)
                    graph += ClipLook.ffmpegChain(input: "[\(v):v:0]", start: item.start - from, end: item.end - from, length: item.length,
                                                  look: item.look, k: k, width: width, height: height, rate: rate, finish: finish, clear: true, path: item.path)
                    graph.append("[v\(k)]setpts=PTS+\(number(at))/TB[o\(layer)]")
                    graph.append("\(picture)[o\(layer)]overlay=x=0:y=0:eof_action=pass:enable='between(t,\(number(at)),\(number(at + item.length)))'[l\(layer)]")
                    picture = "[l\(layer)]"
                    layer += 1
                }
            }
        }
        // The music under the clips.
        var mixed = "[ac]"
        for (m, song) in project.music.enumerated() {
            let length = min(song.length, max(project.duration - song.at, 0))
            guard length > 0, streams[song.path]?.contains("audio") == true else { continue }
            let (i, from) = input(song.path, song.start, song.start + length)
            let delay = Int(song.at * 1000)
            let songFade = fades(max(song.fadeIn, 0.01), max(song.fadeOut, 0.01), over: length)
            graph.append("[\(i):a:0]atrim=start=\(number(song.start - from)):end=\(number(song.start + length - from)),asetpts=PTS-STARTPTS,"
                         + "volume=\(number(song.volume)),afade=t=in:d=\(number(songFade.in)),"
                         + "afade=t=out:st=\(number(max(length - songFade.out, 0))):d=\(number(songFade.out)),"
                         + "adelay=\(delay)|\(delay),aformat=sample_rates=48000:channel_layouts=stereo[m\(m)]")
            mixed += "[m\(m)]"
        }
        var sound = 0
        for track in project.tracks ?? [] where !track.muted {
            for item in track.items where item.ownAudio != false && streams[item.path]?.contains("audio") == true {
                let (i, from) = input(item.path, item.start, item.end)
                let delay = Int((item.at ?? 0) * 1000)
                var chain = "[\(i):a:0]atrim=start=\(number(item.start - from)):end=\(number(item.end - from)),asetpts=PTS-STARTPTS,volume=\(number(item.volume))"
                if item.speed != 1 { chain += "," + tempo(item.speed) }
                let fade = fades(item.fadeIn, item.fadeOut, over: item.length)
                if fade.in > 0 { chain += ",afade=t=in:d=\(number(fade.in))" }
                if fade.out > 0 { chain += ",afade=t=out:st=\(number(max(item.length - fade.out, 0))):d=\(number(fade.out))" }
                graph.append(chain + ",adelay=\(delay)|\(delay),aformat=sample_rates=48000:channel_layouts=stereo[s\(sound)]")
                mixed += "[s\(sound)]"
                sound += 1
            }
        }
        let pieces = mixed.components(separatedBy: "][").count
        graph.append(pieces > 1 ? "\(mixed)amix=inputs=\(pieces):normalize=0:duration=first[aout]" : "[ac]anull[aout]")
        if !audioOnly {
            var chain: [String] = []
            if let subtitles { chain.append("ass=\(EditorSubtitleFiles.filterPath(subtitles))") }
            if let titles { chain.append("ass=\(EditorSubtitleFiles.filterPath(titles))") }
            chain += settings.filters
            graph.append(picture + (chain.isEmpty ? "null" : chain.joined(separator: ",")) + "[v]")
        }
        var inputs: [String] = []
        for file in opened {
            // Many files open at once: fewer decoding threads each (only one decodes at a time).
            if opened.count > 24 { inputs += ["-threads", "2"] }
            if file.from > 0 { inputs += ["-ss", number(file.from)] }
            inputs += ["-t", number(file.to - file.from + 1), "-i", file.path]
        }
        var arguments = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1"] + inputs + ["-filter_complex", graph.joined(separator: ";")]
        if !audioOnly {
            arguments += ["-map", "[v]"] + settings.videoArguments(source: CGSize(width: width, height: height), sourceFPS: fps,
                                                                    length: project.duration, hardware: hardware)
        }
        arguments += ["-map", "[aout]"] + (audioOnly ? settings.audioOnlyArguments : settings.audioArguments)
        if ["mp4", "mov", "m4a"].contains(output.pathExtension.lowercased()) { arguments += ["-movflags", "+faststart"] }
        return arguments + [output.path]
    }
}
