import AVFoundation
import CryptoKit
import Foundation
import ImageIO

extension PhotoSelfTest {
    /// The asset library (-PluckScreenshotOnly assets): every sound is a 48 kHz 24-bit stereo WAV,
    /// peaks at most −1 dBFS (−1 dBTP), no DC, silent ends (loops: no step at the seam), the same per
    /// seed; every graphic has alpha, the same per seed, loops without a jump; movies are ProRes 4444
    /// with alpha at their size, stills a PNG and a still movie; a CC0 manifest is checked (licence,
    /// names, addresses, checksum) and a local pack installs; the drag payload is a file the Edit page
    /// takes. Then the store's first sets are made (in the test home, for the snapshots).
    static func assetsTest() async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AssetsTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let limit = Float(pow(10, -1.0 / 20)) + 1e-4

        // Sounds.
        for kind in AssetKind.allCases where kind.category != .graphics {
            let seed = AssetMaker.seed(kind, 1)
            let sound = AssetSound.make(kind, seed: seed)
            let file = base.appendingPathComponent("\(kind.rawValue).wav")
            do { try AssetSound.writeWAV(sound, to: file) } catch { check("assets: \(kind.rawValue) written", false, "\(error)"); continue }
            guard let audio = try? AVAudioFile(forReading: file), let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil, let data = buffer.floatChannelData else {
                check("assets: \(kind.rawValue) reads back", false); continue
            }
            let bits = audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
            check("assets: \(kind.rawValue) 48 kHz 24-bit stereo", audio.fileFormat.sampleRate == 48_000 && audio.fileFormat.channelCount == 2 && bits == 24,
                  "\(audio.fileFormat.sampleRate) \(audio.fileFormat.channelCount) \(bits ?? 0)")
            let n = Int(buffer.frameLength), seconds = Double(n) / 48_000
            check("assets: \(kind.rawValue) duration", seconds > 0.03 && seconds < 40, "\(seconds)")
            let left = Array(UnsafeBufferPointer(start: data[0], count: n)), right = Array(UnsafeBufferPointer(start: data[1], count: n))
            let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
            check("assets: \(kind.rawValue) peak ≤ −1 dBFS and not quiet", peak <= limit && peak > 0.5, "\(peak)")
            check("assets: \(kind.rawValue) true peak ≤ −1 dBTP", max(AssetSound.truePeak(left), AssetSound.truePeak(right)) <= limit + 0.01)
            let dc = max(abs(left.reduce(0, +) / Float(n)), abs(right.reduce(0, +) / Float(n)))
            check("assets: \(kind.rawValue) no DC offset", dc < 0.002, "\(dc)")
            if sound.loops {
                let step = max(abs(left[n - 1] - left[0]), abs(right[n - 1] - right[0]))
                check("assets: \(kind.rawValue) loop seam", step < 0.08, "\(step)")
            } else {
                let ends = [left[0], right[0], left[n - 1], right[n - 1]].map(abs).max() ?? 1
                check("assets: \(kind.rawValue) silent ends", ends < 0.001, "\(ends)")
            }
            let again = AssetSound.make(kind, seed: seed), other = AssetSound.make(kind, seed: AssetMaker.seed(kind, 2))
            check("assets: \(kind.rawValue) same per seed, varies", again.left == sound.left && again.right == sound.right && other.left != sound.left)
            if [.pad, .pulse, .beat].contains(kind) { check("assets: \(kind.rawValue) has its tempo", sound.bpm != nil) }
            if [.pad, .pulse, .stinger].contains(kind) { check("assets: \(kind.rawValue) has its key", sound.key != nil) }
        }

        // Graphics, drawn small.
        func bytes(_ image: CGImage?) -> [UInt8] {
            guard let image, let data = image.dataProvider?.data else { return [] }
            return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            var sum = 0
            for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
            return Double(sum) / Double(a.count)
        }
        let small = CGSize(width: 320, height: 180)
        for kind in AssetKind.allCases where kind.category == .graphics {
            let seed = AssetMaker.seed(kind, 1)
            let first = bytes(AssetGraphics.image(kind, seed: seed, t: kind == .counter ? 2.9 : 0, size: small))
            var alphas = Set<UInt8>()
            for i in stride(from: 3, to: first.count, by: 4) { alphas.insert(first[i]) }
            check("assets: \(kind.rawValue) has alpha", alphas.contains(0) || alphas.contains { $0 < 255 }, "\(alphas.count) values")
            check("assets: \(kind.rawValue) draws something", alphas.contains { $0 > 0 })
            let again = bytes(AssetGraphics.image(kind, seed: seed, t: kind == .counter ? 2.9 : 0, size: small))
            let others = (2...4).map { bytes(AssetGraphics.image(kind, seed: AssetMaker.seed(kind, $0), t: kind == .counter ? 2.9 : 0, size: small)) }
            check("assets: \(kind.rawValue) same per seed, varies", first == again && others.contains { $0 != first })
            if AssetGraphics.loops(kind) {
                let fps = Double(AssetGraphics.frameRate), count = Int(AssetGraphics.length(kind) * fps)
                let frames = (0..<count).map { bytes(AssetGraphics.image(kind, seed: seed, t: Double($0) / fps, size: small)) }
                let steps = (1..<count).map { difference(frames[$0 - 1], frames[$0]) }.sorted()
                let seam = difference(frames[count - 1], frames[0]), typical = steps[steps.count / 2]
                check("assets: \(kind.rawValue) loop seam", seam <= typical * 1.5 + 0.5, "seam \(seam) typical \(typical)")
            }
        }

        // Real files: a moving overlay and a still.
        if let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") {
            // (Into the test home's asset folder, where the items point.)
            let assets = AssetStore.root
            func probe(_ file: URL) -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobe)
                process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,profile,pix_fmt,width,height", "-of", "csv=p=0", file.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                try? process.run()
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            do {
                let leak = try await AssetMaker.make(.lightLeak, variation: 1, canvas: .landscape, into: assets, ffmpeg: ffmpeg)
                let info = probe(leak.url)
                check("assets: light leak ProRes 4444 alpha 1920×1080", info.contains("prores") && info.contains("4444") && info.contains("yuva444") && info.contains("1920,1080"), info)
                let seconds = (try? await AVURLAsset(url: leak.url).load(.duration).seconds) ?? 0
                check("assets: light leak 4 s", abs(seconds - 4) < 0.1, "\(seconds)")
                let still = try await AssetMaker.make(.lowerThird, variation: 1, canvas: .vertical, into: assets, ffmpeg: ffmpeg)
                let png = still.url
                let image = CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                check("assets: lower third PNG 1080×1920 with alpha", image?.width == 1080 && image?.height == 1920
                      && ![.none, .noneSkipLast, .noneSkipFirst].contains(image?.alphaInfo ?? .none), "\(image?.width ?? 0)×\(image?.height ?? 0)")
                let movie = still.timelineFile, stillInfo = probe(movie)
                check("assets: lower third still movie ProRes alpha", stillInfo.contains("yuva444") && stillInfo.contains("1080,1920"), stillInfo)
                let small = try await AssetMaker.make(.bokeh, variation: 1, canvas: .landscape, movie: .hevc, into: assets, ffmpeg: ffmpeg)
                let track = try? await AVURLAsset(url: small.url).loadTracks(withMediaType: .video).first
                let format = try? await track?.load(.formatDescriptions).first
                let alpha = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool } ?? false
                let bytes = RemotePullManager.size(of: small.url) ?? 0, prores = RemotePullManager.size(of: leak.url) ?? 0
                check("assets: bokeh HEVC with alpha, a separate file", alpha && small.file.hasSuffix("HEVC.mov") && small.id != leak.id, "alpha \(alpha) \(small.file)")
                note("assets: 4 s 1920×1080 overlay: ProRes 4444 \(prores / 1_000_000) MB, HEVC \(bytes / 1_000_000) MB")
                // Dragged as the media panel drags: a file URL the Edit page opens (a movie or sound, with a length).
                let sound = try await AssetMaker.make(.whoosh, variation: 1, canvas: .landscape, into: assets, ffmpeg: ffmpeg)
                for item in [still, leak, sound] {
                    let url = await AssetLibraryView.dragPayload(item).load(URL.self)
                    let length = (try? await AVURLAsset(url: url ?? base).load(.duration).seconds) ?? 0
                    check("assets: \(item.kind) drag payload the Edit page takes", url?.isFileURL == true && url.map(EditorTarget.canOpen) == true && length > 0,
                          "\(url?.path ?? "none") \(length)")
                }
                check("assets: named with category and variation", sound.file.hasSuffix("SFX Whoosh 01.wav") && leak.file.contains("Graphics Light Leak 01"), sound.file)
            } catch {
                check("assets: files made", false, "\(error)")
            }
        } else {
            skip("assets: files", "no ffmpeg")
        }

        // A CC0 pack, all local.
        let packFiles = base.appendingPathComponent("pack-source", isDirectory: true)
        try? fm.createDirectory(at: packFiles, withIntermediateDirectories: true)
        let source = packFiles.appendingPathComponent("hit.wav")
        try? AssetSound.writeWAV(AssetSound.make(.impact, seed: 7), to: source)
        let sha = (try? Data(contentsOf: source)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        func manifest(licence: String = "CC0-1.0", id: String = "hit", url: URL? = nil, sha256: String? = nil) -> Data {
            let entry: [String: Any] = ["id": id, "title": "Hit", "category": "sfx", "kind": "impact", "tags": ["hit"], "url": (url ?? source).absoluteString,
                                        "sha256": sha256 ?? sha, "size": size, "licence": licence, "source": "https://example.org/hit", "author": "Someone"]
            return (try? JSONSerialization.data(withJSONObject: ["id": "testpack", "title": "Test", "files": [entry]])) ?? Data()
        }
        check("assets: manifest parses", (try? AssetPackManifest.parse(manifest(), local: true))?.files.first?.sha256 == sha)
        check("assets: manifest refuses non-CC0", (try? AssetPackManifest.parse(manifest(licence: "CC-BY-NC-4.0"), local: true)) == nil)
        check("assets: manifest refuses CC-BY", (try? AssetPackManifest.parse(manifest(licence: "CC-BY-4.0"), local: true)) == nil)
        check("assets: manifest refuses a path in a name", (try? AssetPackManifest.parse(manifest(id: "../x"), local: true)) == nil)
        check("assets: remote manifest refuses file addresses", (try? AssetPackManifest.parse(manifest(), local: false)) == nil)
        check("assets: manifest refuses plain http", (try? AssetPackManifest.parse(manifest(url: URL(string: "http://example.org/hit.wav")), local: false)) == nil)
        let good = base.appendingPathComponent("good.json"), bad = base.appendingPathComponent("bad.json")
        try? manifest().write(to: good)
        try? manifest(sha256: String(repeating: "0", count: 64)).write(to: bad)
        let root = base.appendingPathComponent("root", isDirectory: true)
        do {
            let items = try await AssetPackDownloader.install(from: good, into: root) { _ in }
            let item = items.first
            check("assets: local pack installs, checked", items.count == 1 && item.map { AssetPackManifest.verify(root.appendingPathComponent($0.file), try! AssetPackManifest.parse(manifest(), local: true).files[0]) } == true)
            check("assets: pack file keeps its licence and source", item?.licence == "CC0-1.0" && item?.sourcePage == "https://example.org/hit" && item?.author == "Someone")
        } catch {
            check("assets: local pack installs, checked", false, "\(error)")
        }
        do {
            _ = try await AssetPackDownloader.install(from: bad, into: base.appendingPathComponent("root2")) { _ in }
            check("assets: wrong checksum refused", false)
        } catch {
            check("assets: wrong checksum refused", (error as? AssetPackManifest.Problem) == .checksum("Hit"), "\(error)")
        }

        // The first sets, in the test home's asset folder (the snapshots show them).
        let store = AssetStore.shared
        for category in AssetCategory.allCases where !store.items.contains(where: { $0.category == category && $0.pack == nil }) {
            await store.makeStarter(category)
        }
        let counts = AssetCategory.allCases.map { category in store.items.filter { $0.category == category }.count }
        note("assets: store has \(counts[0]) SFX, \(counts[1]) music, \(counts[2]) graphics")
        check("assets: first sets made", counts[0] >= 30 && counts[1] >= 8 && counts[2] >= 12 && store.problem == nil, "\(counts) \(store.problem ?? "")")
    }
}
