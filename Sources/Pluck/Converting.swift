import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A file on this Mac converted with Pluck's ffmpeg: drop it on the window or use File → Convert Files….
struct Conversion: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        /// `smaller` (720p) was replaced by `compress`; it stays so older history entries still load.
        case audio, mp4, compress, smaller

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: String(localized: "Extract Audio")
            case .mp4: String(localized: "Convert to MP4")
            case .compress: String(localized: "Compress")
            case .smaller: String(localized: "Make Smaller")
            }
        }

        var detail: String {
            switch self {
            case .audio: String(localized: "Saves the sound as an audio file in the format below. Audio that’s already in that format is copied without quality loss.")
            case .mp4: String(localized: "H.264 video that plays everywhere. Files that are already compatible are only repackaged, without quality loss.")
            case .compress: String(localized: "Makes the file the size you choose, for sharing or mail. The resolution stays the same unless the file gets very small.")
            case .smaller: String(localized: "Shrinks the video to at most 720p, for sharing or mail.")
            }
        }

        var symbol: String {
            switch self {
            case .audio: "waveform"
            case .mp4: "film"
            case .compress, .smaller: "arrow.down.right.and.arrow.up.left"
            }
        }

        var needsVideo: Bool { self == .mp4 || self == .smaller }
    }

    var source: String
    var preset: Preset
    /// For Compress: the target size as a percentage of the original.
    var percent: Int?
    /// For Compress: output height. nil lets Pluck decide, 0 keeps the original.
    var resolution: Int?

    /// Shown in the row instead of the download format.
    func label(options: DownloadOptions) -> String {
        switch preset {
        case .audio: options.audioFormat.shortLabel
        case .mp4: "MP4 · H.264"
        case .compress:
            if let resolution, resolution > 0 {
                String(localized: "Compressed to \(percent ?? 50)% · \(resolution)p")
            } else {
                String(localized: "Compressed to \(percent ?? 50)%")
            }
        case .smaller: "MP4 · 720p"
        }
    }
}

enum Converting {
    enum Failure: LocalizedError {
        case noAudio, noVideo, unreadable, sourceMissing, noFFmpeg, tooShort

        var errorDescription: String? {
            switch self {
            case .noAudio: String(localized: "This file has no sound to extract.")
            case .noVideo: String(localized: "This file has no video. Use Extract Audio instead.")
            case .unreadable: String(localized: "Pluck couldn’t read this file. It may not be audio or video.")
            case .sourceMissing: String(localized: "The original file was moved or deleted.")
            case .noFFmpeg: String(localized: "ffmpeg isn’t installed, so this file can’t be converted.")
            case .tooShort: String(localized: "Pluck couldn’t tell how long this file is, so it can’t aim for a size.")
            }
        }
    }

    static func isMedia(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) ?? false
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// Text files (link lists, .txt, .csv…) whose links can be downloaded.
    static func isText(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) ?? false
    }

    // MARK: - Reading the file

    struct MediaInfo {
        var duration: Double?
        var videoCodec: String?
        var audioCodec: String?
        /// Bits per second.
        var audioBitrate: Double?
        var width: Int?
        var height: Int?
        var fps: Double?
    }

    static func probe(_ file: URL, ffprobe: String) async -> MediaInfo? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v", "error", "-show_entries",
                           "format=duration:stream=codec_type,codec_name,bit_rate,width,height,avg_frame_rate:stream_disposition=attached_pic",
                           "-of", "json", file.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var info = MediaInfo()
            info.duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
            for stream in json["streams"] as? [[String: Any]] ?? [] {
                let codec = stream["codec_name"] as? String
                let isCover = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
                switch stream["codec_type"] as? String {
                case "video" where !isCover && info.videoCodec == nil:
                    info.videoCodec = codec
                    info.width = stream["width"] as? Int
                    info.height = stream["height"] as? Int
                    // "30000/1001" → 29.97
                    let rate = (stream["avg_frame_rate"] as? String)?.split(separator: "/").compactMap { Double($0) }
                    if let rate, rate.count == 2, rate[1] > 0 { info.fps = rate[0] / rate[1] }
                case "audio" where info.audioCodec == nil:
                    info.audioCodec = codec
                    info.audioBitrate = (stream["bit_rate"] as? String).flatMap(Double.init)
                default: break
                }
            }
            return info.videoCodec == nil && info.audioCodec == nil ? nil : info
        }.value
    }

    // MARK: - Planning

    struct Plan {
        /// Two-pass encodes analyse the video first (output discarded), then encode for real.
        var firstPass: [String]?
        var arguments: [String]
        var fileExtension: String
        /// Added to the name so a converted copy doesn't look like the original.
        var suffix = ""
    }

    static func plan(_ conversion: Conversion, options: DownloadOptions, info: MediaInfo, sourceExtension: String,
                     sourceSize: Int64 = 0, passLog: String = "") throws -> Plan {
        switch conversion.preset {
        case .compress:
            guard let duration = info.duration, duration > 0 else { throw Failure.tooShort }
            let target = compression(info: info, sourceSize: sourceSize, percent: conversion.percent ?? 50,
                                     resolution: conversion.resolution)
            guard let video = target.videoKbps else {
                guard info.audioCodec != nil else { throw Failure.noAudio }
                return Plan(arguments: ["-map", "0:a:0", "-vn", "-map_metadata", "0",
                                        "-c:a", "aac", "-b:a", "\(target.audioKbps)k"],
                            fileExtension: "m4a", suffix: String(localized: " (compressed)"))
            }
            var video264 = ["-c:v", "libx264", "-preset", "medium", "-b:v", "\(video)k", "-pix_fmt", "yuv420p"]
            if let height = target.height { video264 += ["-vf", "scale=-2:\(height)"] }
            let log = ["-passlogfile", passLog]
            return Plan(firstPass: ["-map", "0:v:0"] + video264 + ["-pass", "1"] + log + ["-an", "-f", "mp4"],
                        arguments: ["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"] + video264 + ["-pass", "2"] + log
                            + ["-c:a", "aac", "-b:a", "\(target.audioKbps)k", "-movflags", "+faststart"],
                        fileExtension: "mp4", suffix: String(localized: " (compressed)"))
        case .audio:
            guard let codec = info.audioCodec else { throw Failure.noAudio }
            return audioPlan(codec: codec, options: options)
        case .mp4:
            guard let video = info.videoCodec else { throw Failure.noVideo }
            let videoFits = ["h264", "hevc"].contains(video)
            let audioFits = info.audioCodec.map { ["aac", "alac", "mp3"].contains($0) } ?? true
            var args = ["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"]
            args += videoFits ? ["-c:v", "copy"] : ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
            if video == "hevc" { args += ["-tag:v", "hvc1"] }   // so QuickTime and iPhone play it
            args += audioFits ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
            args += ["-movflags", "+faststart"]
            return Plan(arguments: args, fileExtension: "mp4",
                        suffix: sourceExtension == "mp4" ? String(localized: " (converted)") : "")
        case .smaller:
            guard info.videoCodec != nil else { throw Failure.noVideo }
            let args = ["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0",
                        "-c:v", "libx264", "-preset", "medium", "-crf", "26", "-pix_fmt", "yuv420p",
                        "-vf", "scale=-2:'min(720,trunc(ih/2)*2)'",
                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
            return Plan(arguments: args, fileExtension: "mp4", suffix: String(localized: " (smaller)"))
        }
    }

    /// Bitrates that make a file `percent` of its original size, and a lower resolution when the
    /// bitrate gets too thin for the original one (a sharp 720p beats a blocky 1080p).
    struct Compression {
        var videoKbps: Int?
        var audioKbps: Int
        /// Lowered height, or nil to keep the original.
        var height: Int?
        /// So few bits that it will look (or sound) noticeably worse.
        var isRough: Bool
    }

    /// Heights offered for Compress: the common ones below the source's.
    static func resolutions(below height: Int) -> [Int] {
        [2160, 1440, 1080, 720, 480, 360].filter { $0 < height }
    }

    static func compression(info: MediaInfo, sourceSize: Int64, percent: Int, resolution: Int? = nil) -> Compression {
        let duration = max(info.duration ?? 1, 1)
        // 3% for the container, then share the rest between picture and sound.
        let totalKbps = Double(sourceSize) * Double(percent) / 100 * 8 / duration / 1000 * 0.97
        guard info.videoCodec != nil else {
            let audio = Int(min(max(totalKbps, 32), 320))
            return Compression(videoKbps: nil, audioKbps: audio, height: nil, isRough: totalKbps < 64)
        }
        let audio = info.audioCodec == nil ? 0 : (totalKbps > 1500 ? 128 : totalKbps > 500 ? 96 : 64)
        let video = max(totalKbps - Double(audio), 60)

        // Bits per pixel per frame; below ~0.05 H.264 starts to fall apart.
        var height: Int?
        if let chosen = resolution {
            // The user's pick: 0 keeps the original, anything lower than the source scales down.
            if chosen > 0, let h = info.height, chosen < h { height = chosen }
        } else if let w = info.width, let h = info.height, w > 0, h > 0 {
            let fps = min(max(info.fps ?? 30, 1), 120)
            let bpp = { (lines: Int) -> Double in
                let width = Double(w) * Double(lines) / Double(h)
                return video * 1000 / (width * Double(lines) * fps)
            }
            for lines in [1080, 720, 480, 360] where lines < h && bpp(height ?? h) < 0.05 {
                height = lines
            }
        }
        let rough = video < 300 || totalKbps < 200
        return Compression(videoKbps: Int(video), audioKbps: max(audio, 48), height: height, isRough: rough)
    }

    /// Copies the audio when it's already in the chosen format, so nothing is lost; converts otherwise.
    private static func audioPlan(codec: String, options: DownloadOptions) -> Plan {
        let base = ["-map", "0:a:0", "-vn", "-map_metadata", "0"]
        let bitrate = options.audioBitrate == .best ? nil : "\(options.audioBitrate.rawValue)k"
        let copy = base + ["-c:a", "copy"]
        let aac = Plan(arguments: base + ["-c:a", "aac", "-b:a", bitrate ?? "256k"], fileExtension: "m4a")

        switch options.audioFormat {
        case .original:
            switch codec {
            case "aac", "alac": return Plan(arguments: copy, fileExtension: "m4a")
            case "mp3": return Plan(arguments: copy, fileExtension: "mp3")
            case "opus": return Plan(arguments: copy, fileExtension: "opus")
            case "vorbis": return Plan(arguments: copy, fileExtension: "ogg")
            case "flac": return Plan(arguments: copy, fileExtension: "flac")
            case let c where c.hasPrefix("pcm"): return Plan(arguments: copy, fileExtension: "wav")
            default: return aac
            }
        case .m4a:
            return codec == "aac" ? Plan(arguments: copy, fileExtension: "m4a") : aac
        case .mp3:
            if codec == "mp3" { return Plan(arguments: copy, fileExtension: "mp3") }
            return Plan(arguments: base + ["-c:a", "libmp3lame"] + (bitrate.map { ["-b:a", $0] } ?? ["-q:a", "0"]), fileExtension: "mp3")
        case .opus:
            if codec == "opus" { return Plan(arguments: copy, fileExtension: "opus") }
            return Plan(arguments: base + ["-c:a", "libopus", "-b:a", bitrate ?? "192k"], fileExtension: "opus")
        case .flac:
            return Plan(arguments: base + ["-c:a", codec == "flac" ? "copy" : "flac"], fileExtension: "flac")
        case .wav:
            return Plan(arguments: base + ["-c:a", codec.hasPrefix("pcm") ? "copy" : "pcm_s16le"], fileExtension: "wav")
        }
    }

    /// A name next to nothing else: "Name.mp4", then "Name 2.mp4", and so on.
    static func outputURL(folder: String, name: String, fileExtension: String) -> URL {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        var url = directory.appendingPathComponent("\(name).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) \(number).\(fileExtension)")
            number += 1
        }
        return url
    }

    /// A Quick Look thumbnail of the file, saved so the row can show it like a video's thumbnail.
    static func thumbnail(for file: URL) async -> URL? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 256, height: 144),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }
}
