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
    static func level(_ loudness: Loudness, measured: [String: String]?) -> String {
        guard let input = measured?["input_i"].flatMap(Double.init), input.isFinite, input > -70 else {
            return "loudnorm=I=\(loudness.lufs):TP=\(loudness.truePeak):LRA=11,aresample=48000"
        }
        let gain = loudness.lufs - input
        // Sample-peak limiter a little under the true-peak target, delay compensated.
        let limit = pow(10, (loudness.truePeak - 0.5) / 20)
        return String(format: "volume=%.2fdB,alimiter=limit=%.4f:level=false:latency=true:attack=5:release=60,aresample=48000", gain, limit)
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

                item.aiStatus = String(localized: "Reading sound…")
                let decoded = work.appendingPathComponent("in.wav")
                try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", decoded.path],
                                 failure: AudioCleanup.Failure.noSound)

                item.aiStatus = String(localized: "Isolating the voice…")
                item.aiProgress = 0
                let isolated = work.appendingPathComponent("voice.wav")
                let mix = options.strength.mix
                let delay = try await Task.detached {
                    try AudioCleanup.isolate(decoded, to: isolated, mix: mix) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    }
                }.value

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
