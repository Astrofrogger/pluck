import AVFoundation
import CoreAudio
import Foundation

/// A microphone to record from.
struct AudioInput: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Where a take is written: 48 kHz mono 24-bit WAV, whatever the microphone gives. Called from
/// the audio thread while recording, so it keeps its own lock.
final class VoiceOverWriter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// How the first buffers are placed against the timeline.
    private enum Sync {
        /// Everything is written as it comes (tests).
        case none
        /// The microphone runs, playback isn't timed yet: buffers are left out.
        case waiting
        /// Sound before `cut` (host time, seconds) is dropped; if the first buffer comes later, `lead` says by how much.
        case armed(cut: Double)
        case running
    }

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var sync = Sync.none
    private var skip: Int64 = 0
    private var lastEnd: Double?
    private(set) var frames: Int64 = 0
    /// The loudest sample written, 0...1.
    private(set) var peak: Float = 0
    /// Seconds the take starts after the timeline's start (the microphone was late to deliver).
    private(set) var lead: Double = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Leaves buffers out until `arm`, so the start can be cut to the sample.
    func holdUntilArmed() {
        lock.lock(); defer { lock.unlock() }
        sync = .waiting
    }

    /// The take starts at the first sample whose host time (seconds) is `cut`.
    func arm(cut: Double) {
        lock.lock(); defer { lock.unlock() }
        sync = .armed(cut: cut)
    }

    /// Converts and writes one buffer; returns its level (0...1, from -60 dB up). `hostTime`: when
    /// the buffer's first sample was taken.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard file != nil else { return 0 }
        let seconds = hostTime.map { AVAudioTime.seconds(forHostTime: $0) }
        let length = Double(buffer.frameLength) / buffer.format.sampleRate
        switch sync {
        case .none, .running: break
        case .waiting: return 0
        case .armed(let cut):
            if let seconds {
                if seconds + length <= cut { return 0 }
                if seconds < cut { skip = Int64((cut - seconds) * Self.format.sampleRate) } else { lead = seconds - cut }
            }
            sync = .running
        }
        // A gap (the microphone restarted, or dropped out) is kept as silence so the take stays in step.
        if let seconds, let last = lastEnd, seconds > last + 0.05 { write(silence: seconds - last) }
        if let seconds { lastEnd = seconds + length }
        guard let out = convert(Self.mono(buffer), flush: false) else { return 0 }
        return write(out)
    }

    /// Drains the converter and closes the file; the length written, in seconds.
    func finish() -> Double {
        lock.lock(); defer { lock.unlock() }
        if file != nil, let tail = convert(nil, flush: true) { write(tail) }
        file = nil
        converter = nil
        return Double(frames) / Self.format.sampleRate
    }

    /// All the channels as one: AVAudioConverter would take the first only, and a microphone on
    /// input 2 of an interface would record silence. Two channels are averaged; more are summed
    /// (such interfaces usually have one live microphone), both kept inside ±1.
    private static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let count = Int(buffer.format.channelCount)
        guard count > 1, let data = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength), let target = out.floatChannelData?[0]
        else { return buffer }
        out.frameLength = buffer.frameLength
        let scale: Float = count == 2 ? 0.5 : 1
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            if buffer.format.isInterleaved {
                for channel in 0..<count { sum += data[0][i * count + channel] }
            } else {
                for channel in 0..<count { sum += data[channel][i] }
            }
            target[i] = max(-1, min(1, sum * scale))
        }
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer?, flush: Bool) -> AVAudioPCMBuffer? {
        if let buffer, converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter, let source = sourceFormat else { return nil }
        let ratio = Self.format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer?.frameLength ?? 0) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if flush { status.pointee = .endOfStream; return nil }
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func write(silence seconds: Double) {
        var left = Int64(seconds * Self.format.sampleRate)
        while left > 0, let zeros = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 48_000) {
            let n = AVAudioFrameCount(min(left, 48_000))
            zeros.frameLength = n
            zeros.floatChannelData?[0].update(repeating: 0, count: Int(n))
            write(zeros)
            left -= Int64(n)
        }
    }

    @discardableResult
    private func write(_ buffer: AVAudioPCMBuffer) -> Float {
        var out = buffer
        if skip > 0 {
            let dropped = min(skip, Int64(out.frameLength))
            skip -= dropped
            guard dropped < Int64(out.frameLength) else { return 0 }
            let rest = AVAudioFrameCount(Int64(out.frameLength) - dropped)
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: rest),
                  let from = out.floatChannelData?[0], let to = trimmed.floatChannelData?[0] else { return 0 }
            to.update(from: from + Int(dropped), count: Int(rest))
            trimmed.frameLength = rest
            out = trimmed
        }
        do { try file?.write(from: out) } catch { return 0 }
        frames += Int64(out.frameLength)
        guard let samples = out.floatChannelData?[0], out.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(out.frameLength) {
            sum += samples[i] * samples[i]
            peak = max(peak, abs(samples[i]))
        }
        let rms = (sum / Float(out.frameLength)).squareRoot()
        return max(0, min(1, (20 * log10(max(rms, 1e-6)) + 60) / 60))
    }
}

/// Records a voice-over while the timeline plays, and lays the take on an audio track called
/// "Voice-over" where the recording began.
///
/// How it stays in step: at Record the timeline goes to the start time and is prerolled there
/// through the 3-2-1 (silent, still). At the end of the count the microphone starts, and playback is
/// scheduled for a host time a moment ahead (`setRate(_:time:atHostTime:)`), so it begins at a
/// known instant instead of whenever AVPlayer gets going. Each microphone buffer says when its first
/// sample was taken; the take is cut so that its first sample is the one heard at that instant,
/// minus the input's own delay (`presentationLatency`, more over Bluetooth). It lands within about a
/// frame of what the speaker heard, apart from the speaker's own output delay.
@MainActor @Observable
final class VoiceOverRecorder {
    enum State: Equatable {
        case idle
        case countingDown(Int)
        case recording(since: Double)
        case failed(String)
    }

    /// Tests: buffers fed in place of the microphone (no permission, no countdown, no timeline).
    static var testInput: [AVAudioPCMBuffer]?

    var state: State = .idle
    /// 0...1, the input's level now.
    var level: Float = 0
    var inputs: [AudioInput] = []
    var input: AudioInput?
    /// When the take began, for the clock on the bar.
    var startedAt = Date()
    /// The recording in progress (tests wait on it).
    private(set) var task: Task<Void, Never>?

    private var engine: AVAudioEngine?
    private var writer: VoiceOverWriter?
    private var url: URL?
    private weak var model: ProjectModel?
    /// The player's mute and stalling settings from before the take; nil where this take left them alone.
    private var mutedBefore: Bool?
    private var waitedBefore: Bool?
    private var observer: NSObjectProtocol?
    private var restarts = 0
    /// Which `start` a run belongs to: a stopped run that wakes up later (a permission prompt
    /// answered, a sleep over) sees a newer number and leaves everything alone.
    private var generation = 0
    private var starts = 0

    var isActive: Bool {
        switch state {
        case .countingDown, .recording: true
        case .idle, .failed: false
        }
    }

    /// The microphones now connected; keeps the chosen one when it's still there.
    func refreshInputs() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        inputs = devices.map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
        if let input, inputs.contains(input) { return }
        let preferred = AVCaptureDevice.default(for: .audio)?.uniqueID
        input = inputs.first { $0.id == preferred } ?? inputs.first
    }

    func start(at timelineTime: Double, in model: ProjectModel, muteTimeline: Bool) {
        guard !isActive else { return }
        self.model = model
        // The timeline isn't built again under the take (that would stop the playback it's timed to).
        if Self.testInput == nil { model.holdingBuilds = true }
        generation += 1
        starts += 1
        let mine = generation, number = starts
        state = .countingDown(3)
        task = Task { [weak self] in
            await self?.run(mine, at: timelineTime, in: model, muteTimeline: muteTimeline)
            if self?.starts == number { self?.task = nil }
        }
    }

    /// Ends the take (or the countdown) and puts the take on the timeline; its file.
    @discardableResult
    func stop() async -> URL? {
        let testing = Self.testInput != nil
        switch state {
        case .countingDown:
            generation += 1
            task?.cancel()
            end()
            state = .idle
            return nil
        case .recording(let since):
            // Tests wait for the fed buffers to be written first.
            if testing { await task?.value }
            guard let model, let url else { end(); state = .idle; return nil }
            let taken = writer
            end()
            let seconds = taken?.finish() ?? 0
            state = .idle
            guard seconds > 0.05 else {
                try? FileManager.default.removeItem(at: url)
                state = .failed(String(localized: "Nothing was recorded."))
                return nil
            }
            guard (taken?.peak ?? 0) > 0.0003 else {
                try? FileManager.default.removeItem(at: url)
                state = .failed(String(localized: "The microphone gave only silence. Check the one chosen here."))
                return nil
            }
            await model.addVoiceOver(url, at: since + (taken?.lead ?? 0))
            return url
        case .failed:
            state = .idle
            return nil
        case .idle:
            return nil
        }
    }

    // MARK: - Recording

    private func current(_ generation: Int) -> Bool { generation == self.generation && !Task.isCancelled }

    private func run(_ generation: Int, at timelineTime: Double, in model: ProjectModel, muteTimeline: Bool) async {
        let testing = Self.testInput != nil
        guard current(generation) else { return }
        if !testing {
            let allowed = await allowed(generation)
            guard current(generation) else { return }
            guard allowed else { return }
        }
        let url: URL
        do { url = try Self.newTakeURL(for: model.project.name) } catch {
            state = .failed(String(localized: "Can’t save the take.")); return
        }
        self.url = url
        do { writer = try VoiceOverWriter(url: url) } catch {
            end()
            state = .failed(String(localized: "Can’t save the take.")); return
        }

        var start = timelineTime
        if !testing {
            mutedBefore = model.player.isMuted
            waitedBefore = model.player.automaticallyWaitsToMinimizeStalling
            model.player.isMuted = muteTimeline
            // Needed for starting at a host time.
            model.player.automaticallyWaitsToMinimizeStalling = false
            if model.isPlaying { model.togglePlay() }
            model.seek(to: timelineTime)
            start = model.time
            for number in [3, 2, 1] {
                state = .countingDown(number)
                try? await Task.sleep(for: .seconds(1))
                guard current(generation) else { return }
                if number == 3 { await preroll(model.player) }
                guard current(generation) else { return }
            }
        }

        if let buffers = Self.testInput {
            startedAt = Date()
            state = .recording(since: start)
            for buffer in buffers { writer?.append(buffer) }
            return
        }

        restarts = 0
        writer?.holdUntilArmed()
        do { try startEngine() } catch {
            end()
            state = .failed(String(localized: "Can’t use this microphone."))
            return
        }
        // Playback begins a moment ahead, at a host time the take is cut to.
        let latency = engine?.inputNode.presentationLatency ?? 0
        let begin = AVAudioTime.seconds(forHostTime: mach_absolute_time()) + 0.25
        writer?.arm(cut: begin + latency)
        startedAt = Date().addingTimeInterval(0.25)
        state = .recording(since: start)
        // Not past the timeline's end: there's nothing to play.
        if model.time < model.duration - 0.05 {
            let host = CMClockMakeHostTimeFromSystemUnits(AVAudioTime.hostTime(forSeconds: begin))
            model.player.setRate(1, time: CMTime(seconds: start, preferredTimescale: 600), atHostTime: host)
        }
    }

    /// Has the player ready to start at once (the item may still be loading: then it just starts).
    private func preroll(_ player: AVPlayer) async {
        guard player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            player.preroll(atRate: 1) { _ in done.resume() }
        }
    }

    private func startEngine() throws {
        stopEngine()
        let engine = AVAudioEngine()
        if let input, let device = Self.deviceID(for: input.id), let unit = engine.inputNode.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let writer else { throw CocoaError(.fileWriteUnknown) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            let level = writer.append(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.level = level } }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // A microphone pulled out or switched under us.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    /// Bluetooth headsets change profile when the microphone opens, and the engine stops: start it
    /// again and keep writing to the same take (the gap is kept as silence). Only a microphone that
    /// is really gone ends the take.
    private func configurationChanged() {
        guard engine != nil, case .recording = state else { return }
        if Date().timeIntervalSince(startedAt) > 1 { restarts += 1 }
        let gone = input.map { Self.deviceID(for: $0.id) == nil } ?? false
        if gone || restarts > 5 {
            Task { await stop() }
            return
        }
        do { try startEngine() } catch { Task { await stop() } }
    }

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Everything but a placed take's file goes: the engine, the timeline's sound back.
    private func end() {
        stopEngine()
        level = 0
        model?.holdingBuilds = false
        if let model, Self.testInput == nil {
            model.player.pause()
            if let mutedBefore { model.player.isMuted = mutedBefore }
            if let waitedBefore { model.player.automaticallyWaitsToMinimizeStalling = waitedBefore }
        }
        mutedBefore = nil
        waitedBefore = nil
        if case .countingDown = state, let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        writer = nil
    }

    private func allowed(_ generation: Int) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        default: break
        }
        // A stopped run says nothing.
        if current(generation) {
            state = .failed(String(localized: "Microphone is off for Pluck. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."))
        }
        return false
    }

    // MARK: - Files and devices

    /// `~/Library/Application Support/Pluck/Voice-overs/<project>-<yyyyMMdd-HHmmss>.wav`; a number
    /// is added if that name is taken. Never the name of a take that was deleted but is still in a
    /// project (it would play the new one).
    static func newTakeURL(for projectName: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Pluck/Voice-overs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clean = projectName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { clean = "Voice-over" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = "\(clean)-\(formatter.string(from: Date()))"
        var candidate = folder.appendingPathComponent("\(stamp).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stamp)-\(n).wav")
            n += 1
        }
        return candidate
    }

    private static func deviceID(for uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
