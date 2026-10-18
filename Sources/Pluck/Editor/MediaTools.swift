import AVFoundation
import CryptoKit
import Foundation

/// The two ways of working on a timeline: choosing and moving, or cutting.
enum EditTool { case select, blade }

/// Reading media for the editors (both editions): its length, a copy macOS plays, its sound's
/// peaks, a frame's length.
enum MediaFile {
    nonisolated static let peakCount = 3000

    /// The file's real length, and whether it has a picture (a song's cover isn't one), as
    /// ffprobe reads it.
    nonisolated static func probe(_ file: URL, ffprobe: String) async -> (duration: Double, video: Bool)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_type:stream_disposition=attached_pic",
                                 "-of", "json", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) else { return nil }
            let video = (json["streams"] as? [[String: Any]] ?? []).contains { stream in
                stream["codec_type"] as? String == "video" && ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
            }
            return (duration, video)
        }.value
    }

    /// A copy macOS plays, in Pluck's cache (made once per file and version): AAC sound, and
    /// H.264 up to 1080p for video, same timing. Copies not opened for two weeks go.
    nonisolated static func playableCopy(of file: URL, video: Bool, ffmpeg: String) async -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Editor", isDirectory: true)
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map {
            "\($0.fileSize ?? 0)-\(Int($0.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        } ?? ""
        let name = SHA256.hash(data: Data((file.path + stamp).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + (video ? ".mov" : ".m4a")
        let copy = folder.appendingPathComponent(name)
        // Copies not used for two weeks go (each use touches its date: APFS barely keeps access
        // dates). Half-made ones go after a day.
        let old = Date.now.addingTimeInterval(-14 * 86_400), stale = Date.now.addingTimeInterval(-86_400)
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where item != copy {
            guard let used = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if used < (item.lastPathComponent.hasPrefix("partial-") ? stale : old) { try? FileManager.default.removeItem(at: item) }
        }
        if FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: copy.path)
            return copy
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Its own half-made file (two tabs can make the same copy at once).
        let partial = folder.appendingPathComponent("partial-\(UUID().uuidString)-" + name)
        var arguments = ["-nostdin", "-y", "-v", "error", "-i", file.path]
        if video {
            arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(1080,ih)'", "-c:v", "h264_videotoolbox", "-b:v", "8M",
                          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        } else {
            arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        }
        let made = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments + [partial.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        guard made, (try? FileManager.default.moveItem(at: partial, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: partial)
            // The other tab finished it first.
            return FileManager.default.fileExists(atPath: copy.path) ? copy : nil
        }
        return copy
    }

    /// A file's sound as peaks (0…1, about 3000 of them across the file), read with ffmpeg at a low
    /// rate: plenty for drawing.
    nonisolated static func peaks(of file: URL, duration: Double, ffmpeg: String) async -> [Float] {
        let rate = duration > 1800 ? 500 : 2000
        return await Task.detached { () -> [Float] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-vn", "-ac", "1", "-ar", String(rate), "-f", "f32le", "-"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !samples.isEmpty else { return [] }
            let buckets = min(peakCount, samples.count)
            var peaks = [Float](repeating: 0, count: buckets)
            let per = Double(samples.count) / Double(buckets)
            for bucket in 0..<buckets {
                let start = Int(Double(bucket) * per), end = min(samples.count, max(start + 1, Int(Double(bucket + 1) * per)))
                var loudest: Float = 0
                for i in start..<end { loudest = max(loudest, abs(samples[i])) }
                peaks[bucket] = loudest
            }
            // Loud enough to see, also for quiet recordings.
            let top = max(peaks.max() ?? 1, 0.05)
            return peaks.map { min($0 / top, 1) }
        }.value
    }

    /// "01:23:10" (minutes, seconds, frames) or with hours for long files.
    /// One frame's duration, exact for the NTSC rates (23.976, 29.97, 59.94: 1001/24000…).
    nonisolated static func frameDuration(_ fps: Double) -> CMTime {
        for (rate, base) in [(24000, 1001), (30000, 1001), (48000, 1001), (60000, 1001), (120000, 1001)]
        where abs(fps - Double(rate) / Double(base)) < 0.005 {
            return CMTime(value: CMTimeValue(base), timescale: CMTimeScale(rate))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
    }
}
