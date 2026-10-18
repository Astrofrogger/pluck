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

    func run(_ project: Project, settings: EditorRenderSettings, audioOnly: Bool, size: CGSize, fps: Double, manager: DownloadManager) {
        guard !project.clips.isEmpty else { return }
        guard let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            problem = Converting.Failure.noFFmpeg.localizedDescription
            return
        }
        output = nil
        problem = nil
        let missing = ProjectModel.missingFiles(in: project)
        guard missing.isEmpty else {
            let names = missing.map { ($0 as NSString).lastPathComponent }.sorted()
            problem = String(localized: "Offline: \(names.prefix(3).formatted(.list(type: .and)))\(names.count > 3 ? "…" : "")")
            return
        }
        progress = 0
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let output = Converting.outputURL(folder: folder, name: project.name,
                                          fileExtension: audioOnly ? settings.audioFile.rawValue : settings.container.fileExtension)
        task = Task {
            // What each file has: a picture, sound or both.
            var streams: [String: Set<String>] = [:]
            for path in Set(project.clips.map(\.path) + project.music.map(\.path)) {
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
                let cues = project.titles.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
                let text = EditorSubtitleFiles.ass(cues, style: project.titleStyle, width: Int(size.width), height: Int(size.height))
                if (try? text.write(to: ass, atomically: true, encoding: .utf8)) != nil { assFile = ass }
            }
            let arguments = { (hardware: Bool) in
                Self.arguments(project, streams: streams, settings: settings, audioOnly: audioOnly, size: size, fps: fps,
                               titles: assFile, subtitles: subtitleFile, hardware: hardware, output: output)
            }
            let report: @Sendable (Double) -> Void = { value in Task { @MainActor in self.progress = value } }
            let hardware = !audioOnly && settings.hardware && !settings.codec.isProRes
            var outcome = EditorExport.Outcome.stopped
            if !Task.isCancelled { outcome = await EditorExport.run(ffmpeg, arguments(hardware), total: project.duration, progress: report) }
            if outcome.isFailed, hardware, !Task.isCancelled {
                report(0)
                outcome = await EditorExport.run(ffmpeg, arguments(false), total: project.duration, progress: report)
            }
            let done = outcome.isDone
            if outcome.isFailed, ScreenshotMode.scene != nil {
                // Tests: the command, to run by hand.
                let tail = if case .failed(let lines) = outcome { lines } else { "" }
                try? ([ffmpeg] + arguments(false) + ["", tail]).joined(separator: "\n")
                    .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pluck-project-export.txt"), atomically: true, encoding: .utf8)
            }
            if let assFile { try? FileManager.default.removeItem(at: assFile) }
            if let subtitleFile { try? FileManager.default.removeItem(at: subtitleFile) }
            progress = nil
            task = nil
            if done, !cues.isEmpty {
                // The subtitles as a file too, next to the video.
                try? EditorSubtitleFiles.srt(cues).write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            }
            if done {
                self.output = output
                finished.insert(output, at: 0)
                _ = manager.addLocalFiles([output])
                manager.saveHistory()
            } else {
                try? FileManager.default.removeItem(at: output)
                problem = EditorExport.readable(outcome)
            }
        }
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
                             width: width, height: height, rate: rate)
    }

    nonisolated private static func arguments(_ project: Project, streams: [String: Set<String>], settings: EditorRenderSettings,
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
        var joined = ""
        for (k, clip) in project.clips.enumerated() {
            let kinds = streams[clip.path] ?? []
            if !audioOnly {
                if kinds.contains("video") {
                    // Stabilized clips' pictures come from their steadied copies.
                    let copy = clip.look?.stabilize == true ? Stabilizer.copy(for: clip.path)?.path : nil
                    let (v, from) = input(copy ?? clip.path, clip.start, clip.end)
                    // Dips to black or white at the edits, as the preview draws them.
                    var finish: [String] = []
                    if k > 0, let dip = project.clips[k - 1].dipOut {
                        let half = min(dip.length / 2, clip.length / 2)
                        finish.append("fade=t=in:st=0:d=\(number(half)):color=\(dip.white ? "white" : "black")")
                    }
                    if let dip = clip.dipOut {
                        let half = min(dip.length / 2, clip.length / 2)
                        finish.append("fade=t=out:st=\(number(max(clip.length - half, 0))):d=\(number(half)):color=\(dip.white ? "white" : "black")")
                    }
                    graph += ClipLook.ffmpegChain(input: "[\(v):v:0]", start: clip.start - from, end: clip.end - from,
                                                  length: clip.length, look: clip.look, k: k, width: width, height: height, rate: rate,
                                                  steadied: copy != nil, finish: finish)
                } else {
                    graph.append("color=black:s=\(width)x\(height):r=\(rate):d=\(number(clip.length)),format=yuv420p[v\(k)]")
                }
                joined += "[v\(k)]"
            }
            var audio: String
            if kinds.contains("audio") {
                let (i, from) = input(clip.path, clip.start, clip.end)
                audio = "[\(i):a:0]atrim=start=\(number(clip.start - from)):end=\(number(clip.end - from)),asetpts=PTS-STARTPTS,volume=\(number(clip.volume))"
                // Faster or slower, at the same pitch (atempo goes from half to double speed per step).
                if clip.speed != 1 { audio += "," + tempo(clip.speed) }
            } else {
                audio = "anullsrc=r=48000:cl=stereo,atrim=duration=\(number(clip.length))"
            }
            let fade = fades(clip.fadeIn, clip.fadeOut, over: clip.length)
            if fade.in > 0 { audio += ",afade=t=in:d=\(number(fade.in))" }
            if fade.out > 0 { audio += ",afade=t=out:st=\(number(max(clip.length - fade.out, 0))):d=\(number(fade.out))" }
            graph.append(audio + ",aformat=sample_rates=48000:channel_layouts=stereo[a\(k)]")
            joined += "[a\(k)]"
        }
        let count = project.clips.count
        graph.append("\(joined)concat=n=\(count):v=\(audioOnly ? 0 : 1):a=1\(audioOnly ? "" : "[vc]")[ac]")
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
        let pieces = mixed.components(separatedBy: "][").count
        graph.append(pieces > 1 ? "\(mixed)amix=inputs=\(pieces):normalize=0:duration=first[aout]" : "[ac]anull[aout]")
        if !audioOnly {
            var chain: [String] = []
            if let subtitles { chain.append("ass=\(EditorSubtitleFiles.filterPath(subtitles))") }
            if let titles { chain.append("ass=\(EditorSubtitleFiles.filterPath(titles))") }
            chain += settings.filters
            graph.append("[vc]" + (chain.isEmpty ? "null" : chain.joined(separator: ",")) + "[v]")
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
