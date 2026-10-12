import Foundation
import SwiftUI

/// How the Editor writes a video, like an editing program's render settings: the file type,
/// codec, size, frame rate, quality (or a size to stay under) and the sound. Kept between
/// exports; presets fill it in for the usual places a video goes.
struct EditorRenderSettings: Codable, Equatable, Sendable {
    enum Container: String, Codable, CaseIterable, Identifiable, Sendable {
        case mp4, mov
        var id: String { rawValue }
        var title: String { self == .mp4 ? "MP4" : String(localized: "QuickTime (MOV)") }
        var fileExtension: String { rawValue }
    }

    enum Codec: String, Codable, CaseIterable, Identifiable, Sendable {
        case h264, hevc, prores422, prores422hq, prores4444
        var id: String { rawValue }

        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "H.265 (HEVC)"
            case .prores422: "Apple ProRes 422"
            case .prores422hq: "Apple ProRes 422 HQ"
            case .prores4444: "Apple ProRes 4444"
            }
        }

        var isProRes: Bool { self == .prores422 || self == .prores422hq || self == .prores4444 }
    }

    /// The picture's shorter side, in lines (0: as the source).
    enum Resolution: Int, Codable, CaseIterable, Identifiable, Sendable {
        case source = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .source: String(localized: "Same as Source")
            case .p2160: "2160p (4K)"
            default: "\(rawValue)p"
            }
        }
    }

    enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
        case source, fps23976 = "24000/1001", fps24 = "24", fps25 = "25", fps2997 = "30000/1001", fps30 = "30", fps50 = "50", fps60 = "60"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .source: String(localized: "Same as Source")
            case .fps23976: "23.976"
            case .fps2997: "29.97"
            default: rawValue
            }
        }
        var value: Double? {
            switch self {
            case .source: nil
            case .fps23976: 24000 / 1001
            case .fps2997: 30000 / 1001
            default: Double(rawValue)
            }
        }
    }

    enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
        case best, high, medium, small, size
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .best: "Best"
            case .high: "High"
            case .medium: "Medium"
            case .small: "Small"
            case .size: "Fit a File Size"
            }
        }

        /// Bits per pixel per frame, for an estimate and for the Mac's own encoder.
        var bitsPerPixel: Double {
            switch self {
            case .best: 0.16
            case .high: 0.1
            case .medium: 0.06
            case .small, .size: 0.035
            }
        }

        /// x264's constant quality (x265 a few steps higher).
        var crf: Int {
            switch self {
            case .best: 16
            case .high: 19
            case .medium: 23
            case .small, .size: 27
            }
        }
    }

    enum AudioCodec: String, Codable, CaseIterable, Identifiable, Sendable {
        case aac, pcm
        var id: String { rawValue }
        var title: String { self == .aac ? "AAC" : String(localized: "Linear PCM (uncompressed)") }
    }

    /// The file for audio-only exports.
    enum AudioFile: String, Codable, CaseIterable, Identifiable, Sendable {
        case m4a, mp3, wav
        var id: String { rawValue }
        var title: String {
            switch self {
            case .m4a: "M4A (AAC)"
            case .mp3: "MP3"
            case .wav: "WAV"
            }
        }
    }

    var container = Container.mp4
    var codec = Codec.h264
    var resolution = Resolution.source
    var frameRate = FrameRate.source
    var quality = Quality.high
    /// For Fit a File Size, in megabytes.
    var targetMB = 50
    /// The Mac's own video encoder: much faster, a little larger for the same quality.
    var hardware = true
    var audioCodec = AudioCodec.aac
    var audioKbps = 256
    var audioFile = AudioFile.m4a

    /// ProRes and uncompressed sound only go in a QuickTime file.
    mutating func tidy() {
        if codec.isProRes { container = .mov }
        if container == .mp4 { audioCodec = .aac }
        if codec.isProRes, quality == .size { quality = .best }
    }

    // MARK: - Presets

    enum Preset: String, CaseIterable, Identifiable {
        case web, youtube4K, smaller, email, master, custom
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .web: "Web 1080p"
            case .youtube4K: "YouTube 4K"
            case .smaller: "Smaller File"
            case .email: "Email (25 MB)"
            case .master: "Master (ProRes 422 HQ)"
            case .custom: "Custom"
            }
        }

        var settings: EditorRenderSettings? {
            var s = EditorRenderSettings()
            switch self {
            case .web: s.resolution = .p1080
            case .youtube4K: s.resolution = .p2160; s.quality = .best
            case .smaller: s.resolution = .p1080; s.quality = .small; s.audioKbps = 160
            case .email: s.resolution = .p720; s.quality = .size; s.targetMB = 25; s.audioKbps = 128; s.hardware = false
            case .master: s.container = .mov; s.codec = .prores422hq; s.quality = .best; s.audioCodec = .pcm
            case .custom: return nil
            }
            return s
        }
    }

    var preset: Preset {
        Preset.allCases.first { $0.settings == self } ?? .custom
    }

    // MARK: - Size

    /// The picture's size after the resolution setting (even numbers, never larger than the source).
    func outputSize(source: CGSize) -> CGSize {
        guard resolution != .source, source.width > 0, source.height > 0 else { return source }
        let short = min(source.width, source.height)
        let scale = min(1, Double(resolution.rawValue) / short)
        func even(_ value: Double) -> Double { (value * scale / 2).rounded() * 2 }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    /// The video's bitrate in kbit/s: for the Mac's encoder, a size to fit, and the estimate.
    func videoKbps(source: CGSize, sourceFPS: Double, length: Double) -> Int {
        if quality == .size {
            let total = Double(targetMB) * 8 * 1024 * 0.97 / max(length, 1)
            return max(Int(total) - audioKbps, 150)
        }
        let size = outputSize(source: source)
        let fps = frameRate.value ?? sourceFPS
        return max(Int(size.width * size.height * fps * quality.bitsPerPixel / 1000), 300)
    }

    /// About how big the file will be, in bytes (ProRes by Apple's published data rates).
    func estimatedBytes(source: CGSize, sourceFPS: Double, length: Double) -> Int64 {
        let size = outputSize(source: source)
        let fps = frameRate.value ?? sourceFPS
        var kbps: Double
        switch codec {
        case .prores422: kbps = size.width * size.height * fps * 2.0 / 1000
        case .prores422hq: kbps = size.width * size.height * fps * 3.0 / 1000
        case .prores4444: kbps = size.width * size.height * fps * 4.5 / 1000
        default: kbps = Double(videoKbps(source: source, sourceFPS: sourceFPS, length: length))
            * (codec == .hevc && quality != .size ? 0.65 : 1)
        }
        kbps += audioCodec == .pcm ? 1536 : Double(audioKbps)
        return Int64(kbps * 1000 / 8 * length)
    }

    // MARK: - ffmpeg

    /// Scaling and frame rate, added after the subtitles.
    var filters: [String] {
        var chain: [String] = []
        if resolution != .source {
            let lines = resolution.rawValue
            chain.append("scale=w='if(gte(iw,ih),-2,min(iw,\(lines)))':h='if(gte(iw,ih),min(ih,\(lines)),-2)'")
        }
        if frameRate != .source { chain.append("fps=\(frameRate.rawValue)") }
        return chain
    }

    func videoArguments(source: CGSize, sourceFPS: Double, length: Double, hardware: Bool) -> [String] {
        let kbps = videoKbps(source: source, sourceFPS: sourceFPS, length: length)
        let rate = ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
        switch codec {
        case .h264:
            if hardware { return ["-c:v", "h264_videotoolbox"] + rate + ["-pix_fmt", "yuv420p"] }
            return ["-c:v", "libx264", "-preset", quality == .best ? "slow" : "medium"]
                + (quality == .size ? rate : ["-crf", "\(quality.crf)"]) + ["-pix_fmt", "yuv420p"]
        case .hevc:
            if hardware { return ["-c:v", "hevc_videotoolbox"] + rate + ["-tag:v", "hvc1", "-pix_fmt", "yuv420p"] }
            return ["-c:v", "libx265", "-preset", "medium"]
                + (quality == .size ? rate : ["-crf", "\(quality.crf + 4)"]) + ["-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
        case .prores422: return ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le", "-vendor", "apl0"]
        case .prores422hq: return ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-vendor", "apl0"]
        case .prores4444: return ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", "-vendor", "apl0"]
        }
    }

    var audioArguments: [String] {
        audioCodec == .pcm ? ["-c:a", "pcm_s16le"] : ["-c:a", "aac", "-b:a", "\(audioKbps)k"]
    }

    var audioOnlyArguments: [String] {
        switch audioFile {
        case .m4a: ["-c:a", "aac", "-b:a", "\(audioKbps)k"]
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "\(min(audioKbps, 320))k"]
        case .wav: ["-c:a", "pcm_s16le"]
        }
    }
}

extension EditorRenderSettings {
    /// Saved as text in the preferences (not RawRepresentable: that would make Codable recurse).
    init(saved: String) {
        self = saved.data(using: .utf8).flatMap { try? JSONDecoder().decode(EditorRenderSettings.self, from: $0) } ?? Self()
    }

    var saved: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
