import AppKit
import AVFoundation

/// Clean Up Audio: Apple's voice isolation (local AI, the kind Final Cut Pro uses) removes noise,
/// hum and wind around speech; a gentle low cut, compressor and de-esser follow, and the loudness
/// is levelled to a target. Saved as a "(clean audio)" copy; the picture is copied untouched.
enum AudioCleanup {
    enum Strength: String, CaseIterable, Identifiable {
        case light, strong
        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: String(localized: "Light")
            case .strong: String(localized: "Strong")
            }
        }

        var detail: String {
            switch self {
            case .light: String(localized: "Keeps a little of the room, so the voice sounds natural.")
            case .strong: String(localized: "Removes as much noise as possible.")
            }
        }

        /// How much of the isolated voice is used (the rest is the original sound).
        var mix: Float {
            switch self {
            case .light: 80
            case .strong: 100
            }
        }
    }

    enum Loudness: String, CaseIterable, Identifiable {
        case online, podcast, broadcast
        var id: String { rawValue }

        var label: String {
            switch self {
            case .online: String(localized: "Online video (−14 LUFS)")
            case .podcast: String(localized: "Podcast (−16 LUFS)")
            case .broadcast: String(localized: "Broadcast (−23 LUFS)")
            }
        }

        var lufs: Double {
            switch self {
            case .online: -14
            case .podcast: -16
            case .broadcast: -23
            }
        }

        var truePeak: Double { self == .broadcast ? -2 : -1 }
    }

    struct Options {
        var strength: Strength = .strong
        var loudness: Loudness = .online
        /// PCM sources: the channels to clean, counted across every sound stream from 0 (nil: all).
        /// The others are kept as they were.
        var channels: Set<Int>?
        /// PCM videos: also save the clean sound as a WAV beside the video.
        var wav = false
    }

    /// One sound stream of the source, as ffprobe reports it.
    struct Stream: Equatable {
        var codec: String
        var channels: Int
        var layout: String?
        var rate: Int

        /// PCM (and lossless) sound stays PCM, for editing in DaVinci Resolve.
        var isLossless: Bool { codec.hasPrefix("pcm_") || ["flac", "alac"].contains(codec) }

        /// The layout for ffmpeg's join: the source's own, or just a channel count ("4C").
        var joinLayout: String {
            guard let layout, !layout.isEmpty, layout != "unknown", !layout.contains(" ") else { return "\(channels)C" }
            return layout
        }
    }

    static func streams(_ file: URL, ffprobe: String) async -> [Stream] {
        streams(json: await ToolOutput.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries",
                                                     "stream=codec_name,channels,channel_layout,sample_rate", "-of", "json", file.path]))
    }

    static func streams(json: String) -> [Stream] {
        guard let open = json.firstIndex(of: "{"),
              let root = try? JSONSerialization.jsonObject(with: Data(json[open...].utf8)) as? [String: Any] else { return [] }
        return (root["streams"] as? [[String: Any]] ?? []).compactMap { stream in
            guard let codec = stream["codec_name"] as? String, let channels = stream["channels"] as? Int, channels > 0 else { return nil }
            return Stream(codec: codec, channels: channels, layout: stream["channel_layout"] as? String,
                          rate: (stream["sample_rate"] as? String).flatMap(Int.init) ?? 48000)
        }
    }

    /// The final mix for PCM sources: every stream with its own channels in their own layout, the
    /// chosen channels replaced by their clean versions (input 1, 2… in `cleaned` order, each
    /// with its own polish and levelling filters), the rest straight from the source (input 0).
    static func pcmGraph(_ streams: [Stream], cleaned: [Int: String]) -> String {
        var parts: [String] = [], channel = 0, input = 1
        for (s, stream) in streams.enumerated() {
            var labels = ""
            for c in 0..<stream.channels {
                let label = "s\(s)c\(c)"
                if let filters = cleaned[channel] {
                    parts.append("[\(input):a]\(filters)[\(label)]")
                    input += 1
                } else {
                    parts.append("[0:a:\(s)]pan=mono|c0=c\(c)[\(label)]")
                }
                labels += "[\(label)]"
                channel += 1
            }
            parts.append(stream.channels == 1 ? "\(labels)anull[a\(s)]"
                                              : "\(labels)join=inputs=\(stream.channels):channel_layout=\(stream.joinLayout)[a\(s)]")
        }
        return parts.joined(separator: ";")
    }

    enum Failure: LocalizedError {
        case unavailable, noSound

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Voice isolation isn’t available on this Mac.")
            case .noSound: String(localized: "Pluck couldn’t read the sound of this file.")
            }
        }
    }

    private static let isolation = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    static var isSupported: Bool {
        !AVAudioUnitComponentManager.shared().components(matching: isolation).isEmpty
    }

    /// Runs the voice isolation over a mono WAV, faster than real time. Returns how many frames
    /// at the start of the output are the effect's delay, to trim so the sound stays in sync.
    static func isolate(_ input: URL, to output: URL, mix: Float, progress: @Sendable (Double) -> Void) throws -> Int {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit = AVAudioUnitEffect(audioComponentDescription: isolation)
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
        if #available(macOS 15, *) {
            parameters.first { $0.address == AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate) }?.value =
                AUValue(kAUSoundIsolationSoundType_HighQualityVoice)
        }
        parameters.first { $0.address == AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent) }?.value = mix

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(file, at: nil)
        player.play()

        let delay = Int((unit.auAudioUnit.latency * format.sampleRate).rounded())
        let total = file.length + AVAudioFramePosition(delay)
        let writer = try AVAudioFile(forWriting: output, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { throw Failure.noSound }
        var lastReport = 0.0
        while engine.manualRenderingSampleTime < total {
            // Stopped from the row.
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(4096, total - engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try writer.write(from: buffer)
            let done = Double(engine.manualRenderingSampleTime) / Double(total)
            if done - lastReport > 0.01 { progress(done); lastReport = done }
        }
        return delay
    }

    /// Low cut, gentle compression and de-essing before levelling.
    static func polish(trimming delay: Int) -> String {
        "atrim=start_sample=\(delay),asetpts=PTS-STARTPTS,highpass=f=80,"
            + "acompressor=threshold=-24dB:ratio=2.5:attack=10:release=200:makeup=2,deesser=i=0.4"
    }

    /// loudnorm's first pass: what the sound measures, to level it exactly in the second pass.
    static func measure(_ file: URL, chain: String, loudness: Loudness, ffmpeg: String) async -> [String: String]? {
        let log = await ToolOutput.run(ffmpeg, ["-nostdin", "-v", "info", "-i", file.path,
                                                "-af", "\(chain),loudnorm=I=\(loudness.lufs):TP=\(loudness.truePeak):LRA=11:print_format=json",
                                                "-f", "null", "-"])
        guard let open = log.lastIndex(of: "{"), let close = log.lastIndex(of: "}"), open < close,
              let json = try? JSONSerialization.jsonObject(with: Data(log[open...close].utf8)) as? [String: String] else { return nil }
        return json
    }

    /// The levelling: one fixed gain to the target loudness (so quiet noise isn't pumped up the
    /// way automatic levelling would), with a limiter catching the peaks. Without a measurement,
    /// ffmpeg's automatic levelling.
    static func level(_ loudness: Loudness, measured: [String: String]?, rate: Int = 48000) -> String {
        guard let input = measured?["input_i"].flatMap(Double.init), input.isFinite, input > -70 else {
            return "loudnorm=I=\(loudness.lufs):TP=\(loudness.truePeak):LRA=11,aresample=\(rate)"
        }
        let gain = loudness.lufs - input
        // Sample-peak limiter a little under the true-peak target, delay compensated.
        let limit = pow(10, (loudness.truePeak - 0.5) / 20)
        return String(format: "volume=%.2fdB,alimiter=limit=%.4f:level=false:latency=true:attack=5:release=60,aresample=%d", gain, limit, rate)
    }
}

extension AIStudio {
    /// Makes a "(clean audio)" copy next to the file: isolated voice, polished and levelled.
    func cleanUpAudio(_ item: DownloadItem, options: AudioCleanup.Options) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-clean-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                guard AudioCleanup.isSupported else { throw AudioCleanup.Failure.unavailable }
                guard let ffmpegPath = toolPath("ffmpeg") else { throw Converting.Failure.noFFmpeg }
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let info = if let ffprobe = toolPath("ffprobe") { await Converting.probe(file, ffprobe: ffprobe) } else { Converting.MediaInfo?.none }
                guard info?.audioCodec != nil else { throw AudioCleanup.Failure.noSound }
                let video = Self.isVideo(file) && info?.videoCodec != nil
                if let ffprobe = toolPath("ffprobe") {
                    let streams = await AudioCleanup.streams(file, ffprobe: ffprobe)
                    if let first = streams.first, first.isLossless {
                        try await cleanUpPCM(item, file: file, streams: streams, video: video, info: info, options: options, ffmpeg: ffmpegPath, work: work)
                        return
                    }
                }

                item.aiStatus = String(localized: "Reading sound…")
                let decoded = work.appendingPathComponent("in.wav")
                try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", decoded.path],
                                 failure: AudioCleanup.Failure.noSound)

                item.aiStatus = String(localized: "Isolating the voice…")
                item.aiProgress = 0
                let isolated = work.appendingPathComponent("voice.wav")
                let mix = options.strength.mix
                let delay = try await Self.offMain {
                    try AudioCleanup.isolate(decoded, to: isolated, mix: mix) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    }
                }
                try Task.checkCancellation()

                item.aiStatus = String(localized: "Levelling…")
                item.aiProgress = nil
                let chain = AudioCleanup.polish(trimming: delay)
                let measured = await AudioCleanup.measure(isolated, chain: chain, loudness: options.loudness, ffmpeg: ffmpegPath)
                let audioFilter = "[1:a]\(chain),\(AudioCleanup.level(options.loudness, measured: measured))[a]"

                let source = file.pathExtension.lowercased()
                let lossless = ["wav", "aif", "aiff", "flac"].contains(source)
                let fileExtension = video ? (["mov", "mp4", "m4v", "mkv"].contains(source) ? source : "mp4") : (lossless ? "wav" : "m4a")
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (clean audio)"),
                                                  fileExtension: fileExtension)
                var args = ["-y", "-v", "error", "-progress", "pipe:1", "-nostats", "-i", file.path, "-i", isolated.path,
                            "-filter_complex", audioFilter, "-map_metadata", "0"]
                if video {
                    args += ["-map", "0:v", "-map", "[a]", "-map", "0:s?", "-map_chapters", "0", "-c:v", "copy", "-c:s", "copy",
                             "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
                    if fileExtension != "mkv" { args += ["-movflags", "+faststart"] }
                } else {
                    args += ["-map", "[a]", "-ac", "2"] + (lossless ? ["-c:a", "pcm_s24le"] : ["-c:a", "aac", "-b:a", "256k"])
                }
                item.aiStatus = String(localized: "Saving…")
                item.aiProgress = 0
                try await ffmpeg(args + [output.path], failure: AudioCleanup.Failure.noSound,
                                 duration: info?.duration ?? item.duration, item: item)
                finishJob(item)
                notify(title: String(localized: "“\(item.title)” has clean audio"),
                       body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }
}

extension AIStudio {
    /// Clean Up Audio for PCM sources: stays PCM (24-bit, .mov for video), every channel and
    /// stream kept in its own place (a lav and a boom are cleaned each on their own, never mixed),
    /// with the source's timecode and reel, so the copy drops straight into a Resolve edit.
    func cleanUpPCM(_ item: DownloadItem, file: URL, streams: [AudioCleanup.Stream], video: Bool, info: Converting.MediaInfo?,
                    options: AudioCleanup.Options, ffmpeg ffmpegPath: String, work: URL) async throws {
        let total = streams.reduce(0) { $0 + $1.channels }
        let chosen = (0..<total).filter { options.channels?.contains($0) ?? true }
        guard !chosen.isEmpty else { throw AudioCleanup.Failure.noSound }
        // Where each channel number is: (stream, channel in it).
        let places = streams.enumerated().flatMap { s, stream in (0..<stream.channels).map { (s, $0) } }

        item.aiStatus = String(localized: "Reading sound…")
        var decode = ["-y", "-v", "error", "-i", file.path]
        for channel in chosen {
            let (s, c) = places[channel]
            decode += ["-map", "0:a:\(s)", "-af", "pan=mono|c0=c\(c)", "-ar", "48000", "-c:a", "pcm_f32le", work.appendingPathComponent("in\(channel).wav").path]
        }
        // (The last output is the one ffmpeg() names when whole; the others are written as they are.)
        try await ffmpeg(decode, failure: AudioCleanup.Failure.noSound)

        item.aiStatus = String(localized: "Isolating the voice…")
        var cleaned: [Int: String] = [:], inputs: [String] = []
        for (index, channel) in chosen.enumerated() {
            item.aiProgress = Double(index) / Double(chosen.count)
            let decoded = work.appendingPathComponent("in\(channel).wav"), isolated = work.appendingPathComponent("voice\(channel).wav")
            let mix = options.strength.mix, count = Double(chosen.count)
            let delay = try await Self.offMain {
                try AudioCleanup.isolate(decoded, to: isolated, mix: mix) { progress in
                    Task { @MainActor in item.aiProgress = (Double(index) + progress) / count }
                }
            }
            try Task.checkCancellation()
            let chain = AudioCleanup.polish(trimming: delay)
            let measured = await AudioCleanup.measure(isolated, chain: chain, loudness: options.loudness, ffmpeg: ffmpegPath)
            cleaned[channel] = chain + "," + AudioCleanup.level(options.loudness, measured: measured, rate: streams[places[channel].0].rate)
            inputs += ["-i", isolated.path]
        }

        item.aiStatus = String(localized: "Saving…")
        item.aiProgress = 0
        let name = file.deletingPathExtension().lastPathComponent + String(localized: " (clean audio)")
        let folder = file.deletingLastPathComponent().path
        let output = Converting.outputURL(folder: folder, name: name, fileExtension: video || streams.count > 1 ? "mov" : "wav")
        var args = ["-y", "-v", "error", "-progress", "pipe:1", "-nostats", "-i", file.path] + inputs
            + ["-filter_complex", AudioCleanup.pcmGraph(streams, cleaned: cleaned)]
        if video { args += ["-map", "0:v"] }
        for s in streams.indices { args += ["-map", "[a\(s)]"] }
        args += await FrameRewriter.keepingSource(file, input: 0, ffprobe: toolPath("ffprobe"))
        args += ["-c:v", "copy", "-c:a", "pcm_s24le"]
        try await ffmpeg(args + [output.path], failure: AudioCleanup.Failure.noSound, duration: info?.duration ?? item.duration, item: item)

        var files = [output]
        if options.wav, video {
            // Every channel in one WAV (a poly WAV when there are several streams), its start time
            // from the timecode, for syncing in Resolve.
            let wav = Converting.outputURL(folder: folder, name: name, fileExtension: "wav")
            var extract = ["-y", "-v", "error", "-i", output.path]
            extract += streams.count > 1
                ? ["-filter_complex", streams.indices.map { "[0:a:\($0)]" }.joined() + "amerge=inputs=\(streams.count)[a]", "-map", "[a]"]
                : ["-map", "0:a:0"]
            extract += ["-c:a", "pcm_s24le", "-write_bext", "1"]
            if let start = await Tighten.startTimecode(of: file, ffprobe: toolPath("ffprobe") ?? ""), let fps = info?.fps, fps > 0,
               let frames = DropFrame.frames(start, base: DropFrame.base(fps), drop: DropFrame.canDrop(fps) && DropFrame.isDrop(start)) {
                extract += ["-metadata", "time_reference=\(Int((Double(frames) / fps * Double(streams[0].rate)).rounded()))"]
            }
            try await ffmpeg(extract + [wav.path], failure: AudioCleanup.Failure.noSound)
            files.append(wav)
        }
        finishJob(item)
        notify(title: String(localized: "“\(item.title)” has clean audio"),
               body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }
}
