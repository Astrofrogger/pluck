import Accelerate
import Foundation

/// What the edit engine hears in a recording, measured every 10 ms: how strongly something new
/// starts (the onset curve, where beats and hits show as peaks), the energy of kick and bass, and
/// the overall loudness. Sync and the music map work from these, not from the raw waveform, so a
/// distant camera microphone, a different level or crowd noise doesn't throw them off.
struct AudioFeatures: Sendable {
    /// Seconds per value.
    static let step = 0.01
    /// A sound shows up in the measurements as soon as it enters the analysis window, so value
    /// i describes what starts at about i · step + latency. (Sync compares like with like and
    /// doesn't need this; beat times do.)
    static let latency = Double(window) / sampleRate
    static let sampleRate = 8000.0
    private static let hop = 80          // 10 ms at 8 kHz
    private static let window = 1024
    private static let log2n = vDSP_Length(10)

    /// Onset strength, normalised to mean 0 and standard deviation 1.
    var onset: [Float]
    /// Onset strength per frequency band (kick, bass, low mids, vocals and leads, presence,
    /// air), each normalised. A four-on-the-floor kick repeats every beat, but melodies,
    /// vocals and effects in the other bands are what make a moment in a set unique.
    var bands: [[Float]]
    static let bandEdges: [Double] = [30, 150, 400, 1000, 2000, 3000, 4000]
    /// Energy below 150 Hz (kick and bass), in decibels.
    var low: [Float]
    /// Energy above 2 kHz (hats, snares, risers), in decibels.
    var high: [Float]
    /// Overall loudness, in decibels.
    var loudness: [Float]

    var duration: Double { Double(onset.count) * Self.step }

    /// Reads a file's sound (any format ffmpeg reads) as 8 kHz mono, optionally only part of it.
    static func samples(of file: URL, ffmpeg: String, from start: Double? = nil, duration: Double? = nil) async throws -> [Float] {
        try await Task.detached {
            var arguments = ["-nostdin", "-v", "error"]
            if let start { arguments += ["-ss", String(start)] }
            if let duration { arguments += ["-t", String(duration)] }
            arguments += ["-i", file.path, "-vn", "-ac", "1", "-ar", String(Int(sampleRate)), "-f", "f32le", "-"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { throw Failure.noSound(file.lastPathComponent) }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }.value
    }

    enum Failure: LocalizedError {
        case noSound(String)
        var errorDescription: String? {
            switch self {
            case .noSound(let name): String(localized: "Pluck couldn’t read the sound of “\(name)”.")
            }
        }
    }

    /// Measures 8 kHz mono samples.
    init(samples: [Float]) {
        let frames = max(0, (samples.count - Self.window) / Self.hop + 1)
        var onset = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var high = [Float](repeating: 0, count: frames)
        var loudness = [Float](repeating: 0, count: frames)
        let binWidthHz = Self.sampleRate / Double(Self.window)
        let bandRanges = zip(Self.bandEdges, Self.bandEdges.dropFirst()).map { Int($0 / binWidthHz)..<max(Int($1 / binWidthHz), Int($0 / binWidthHz) + 1) }
        var bands = [[Float]](repeating: [Float](repeating: 0, count: frames), count: bandRanges.count)
        guard frames > 1, let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            self.onset = onset; self.bands = bands; self.low = low; self.high = high; self.loudness = loudness
            return
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = Self.window / 2
        var hann = [Float](repeating: 0, count: Self.window)
        vDSP_hann_window(&hann, vDSP_Length(Self.window), Int32(vDSP_HANN_NORM))
        let binWidth = Self.sampleRate / Double(Self.window)
        let lowBins = 1...Int(150 / binWidth)
        let highBins = Int(2000 / binWidth)..<half

        var frame = [Float](repeating: 0, count: Self.window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var logPower = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { input in
            for index in 0..<frames {
                let start = index * Self.hop
                vDSP_vmul(input.baseAddress! + start, 1, hann, 1, &frame, 1, vDSP_Length(Self.window))
                real.withUnsafeMutableBufferPointer { r in
                    imaginary.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        frame.withUnsafeBufferPointer { f in
                            f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                // Compressed magnitudes: quiet and loud recordings look alike.
                for bin in 0..<half { logPower[bin] = log1p(1000 * power[bin]) }
                var flux: Float = 0
                for bin in 1..<half {
                    let rise = logPower[bin] - previous[bin]
                    if rise > 0 { flux += rise }
                }
                onset[index] = flux
                for (band, range) in bandRanges.enumerated() {
                    var bandFlux: Float = 0
                    for bin in range where bin < half {
                        let rise = logPower[bin] - previous[bin]
                        if rise > 0 { bandFlux += rise }
                    }
                    bands[band][index] = bandFlux
                }
                swap(&previous, &logPower)

                var lowSum: Float = 0, highSum: Float = 0, total: Float = 0
                for bin in lowBins { lowSum += power[bin] }
                for bin in highBins { highSum += power[bin] }
                vDSP_sve(power, 1, &total, vDSP_Length(half))
                low[index] = 10 * log10(lowSum + 1e-9)
                high[index] = 10 * log10(highSum + 1e-9)
                loudness[index] = 10 * log10(total + 1e-9)
            }
        }
        self.onset = Self.normalised(Self.detrended(onset))
        self.bands = bands.map { Self.normalised(Self.detrended($0)) }
        self.low = low
        self.high = high
        self.loudness = loudness
    }

    /// Each value minus the average around it (1.5 s): only the hits remain, not whether a
    /// whole stretch is loud or quiet. Otherwise a quiet intro and a silent ending would "match"
    /// just for both being below average.
    static func detrended(_ values: [Float], radius: Int = 75) -> [Float] {
        guard values.count > 2 * radius + 1 else { return values }
        var running = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() { running[index + 1] = running[index] + Double(value) }
        return values.indices.map { index in
            let low = max(0, index - radius), high = min(values.count, index + radius + 1)
            return values[index] - Float((running[high] - running[low]) / Double(high - low))
        }
    }

    /// Mean 0, standard deviation 1 (so recordings at any level compare).
    static func normalised(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &deviation, vDSP_Length(values.count))
        guard deviation > 0 else { return [Float](repeating: 0, count: values.count) }
        var result = [Float](repeating: 0, count: values.count)
        vDSP_normalize(values, 1, &result, 1, &mean, &deviation, vDSP_Length(values.count))
        return result
    }
}
