//  Vendored from swift-vocal-isolation v1.2.0 by David Sherlock (ArrayPress), MIT licence:
//  https://github.com/arraypress/swift-vocal-isolation — see ThirdPartyLicenses.md.
//  Changes for Pluck: macOS 27 availability, input is always 44.1 kHz stereo (no resampling
//  or file reading here), its error type replaced by `StemError`.
//
//  DemucsSeparator.swift
//  VocalIsolation
//
//  Created by David Sherlock on 2026.
//
//  Hybrid Transformer Demucs (Rouard, Massa, Défossez — Meta, MIT) on Core AI:
//  drums, bass, other and vocals from a mix. The network between the complex
//  spectrogram and the mask lives in the .aimodel at the model's training
//  segment; everything around it is upstream's `api.Separator` and
//  `apply_model` line for line — the global normalisation by the mono mix,
//  7.8-second chunks at a 75% stride, the triangular overlap-add weights,
//  the centred padding of the last chunk and its centre trim, and the
//  per-segment normalisation statistics the model computes on its input.
//  Random shifts (`shifts=1` upstream) are off: they make output
//  non-deterministic and parity impossible.
//

import CoreAI
import Foundation

/// Four stems from a stereo mix, with HTDemucs.
@available(macOS 27, *)
final class DemucsSeparator: @unchecked Sendable {

    /// The asset name the export writes and the installer expects, for the default variant.
    public static let assetName = "stems-htdemucs-float32.aimodel"

    /// `stems-<variant>-float32.aimodel`: `htdemucs` (one model) or `htdemucs_ft`
    /// (a bag of four, each fine-tuned for one stem; four times the compute).
    public static func assetName(forVariant variant: String) -> String { "stems-\(variant)-float32.aimodel" }
    public static let sampleRate = 44_100.0
    /// Stems in the model's order.
    public static let sources = ["drums", "bass", "other", "vocals"]
    /// The training segment, 7.8 s: what the model always sees.
    public static let segment = 343_980
    /// `overlap = 0.25`: the stride between chunks.
    public static let chunkStride = Int((1 - 0.25) * Double(segment))

    public struct Stems: Sendable {
        /// `[stem][channel][sample]`, in ``sources`` order, at the input rate.
        public let stems: [[[Float]]]
        public let sampleRate: Double
        public subscript(_ name: String) -> [[Float]]? {
            DemucsSeparator.sources.firstIndex(of: name).map { stems[$0] }
        }
    }

    public let url: URL
    /// Diagnostics only: a pause between chunks of a whole recording.
    nonisolated(unsafe) static var debugPause: Duration?
    nonisolated(unsafe) static var debugReadPause: Duration?
    /// One function for a single model; one per stem for a bag (`model0`…), stem k from model k.
    private let functions: [InferenceFunction]
    /// Whether the asset is a bag of one model per stem.
    public var isBag: Bool { functions.count > 1 }
    private let stft: DemucsSTFT

    /// Where the network runs. See ``ComputeUnit``.
    public let computeUnit: ComputeUnit

    /// The GPU is faster; the CPU is bit-for-bit repeatable. Measured on a
    /// 6-minute mix, GPU runs of the same input differed from each other by
    /// up to 1e-4 relative on one stem (67–137 dB PSNR run to run).
    public enum ComputeUnit: String, Sendable, CaseIterable {
        case gpu, cpu
    }

    /// Run every segment twice and compare the two bit for bit; on a mismatch
    /// run a third time and keep the answer two runs agree on. The GPU path
    /// was measured to return a slightly wrong segment now and then (one or
    /// two of 63 in some passes, none in others, 57–110 dB against upstream
    /// where a correct segment is 136–147 dB); a correct run is bit-for-bit
    /// repeatable, so agreement between two runs is the detector. Doubles the
    /// model time.
    public let verifying: Bool

    /// How many segments verification caught and recomputed, for reporting.
    public private(set) var recomputedSegments = 0

    public init(contentsOf url: URL, computeUnit: ComputeUnit = .gpu, verifying: Bool = true) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw StemError.modelMissing }
        guard let stft = DemucsSTFT() else { throw StemError.setupFailed }
        self.url = url
        self.stft = stft
        self.computeUnit = computeUnit
        self.verifying = verifying
        var options = SpecializationOptions(preferredComputeUnitKind: computeUnit == .gpu ? .gpu : .cpu)
        options.expectFrequentReshapes = true
        let model: AIModel
        do { model = try await AIModel(contentsOf: url, options: options) } catch {
            throw StemError.model("\(url.lastPathComponent): \(error)")
        }
        if let main = try model.loadFunction(named: "main") {
            functions = [main]
        } else {
            var bag: [InferenceFunction] = []
            for k in 0..<Self.sources.count {
                guard let f = try model.loadFunction(named: "model\(k)") else { break }
                bag.append(f)
            }
            guard bag.count == Self.sources.count else {
                throw StemError.model("\(url.lastPathComponent) has neither main nor model0…model\(Self.sources.count - 1); found \(model.functionNames)")
            }
            functions = bag
        }
    }

    // MARK: - Whole recordings

    /// Upstream's `Separator.separate_tensor` + `apply_model(split=True, shifts=0)` at 44.1 kHz.
    public func separateAt44k(_ stereo: [[Float]], progress: ((Double) -> Void)? = nil) async throws -> [[[Float]]] {
        let length = stereo[0].count
        // Global normalisation by the mono mix: mean, and unbiased std + 1e-8.
        let mono = (0..<length).map { (stereo[0][$0] + stereo[1][$0]) / 2 }
        let (mean, std) = Self.stats(mono, unbiased: true)
        let refStd = std + 1e-8
        let norm = stereo.map { ch in ch.map { ($0 - mean) / refStd } }

        let S = Self.sources.count
        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: S)
        var sumWeight = [Float](repeating: 0, count: length)
        let weight = Self.transitionWeight
        let offsets = Array(stride(from: 0, to: length, by: Self.chunkStride))
        for (index, offset) in offsets.enumerated() {
            try Task.checkCancellation()
            let chunkLength = min(Self.segment, length - offset)
            let padded = Self.centredPad(norm, offset: offset, length: chunkLength, target: Self.segment)
            let full = try await separateSegment(padded)
            if let pause = Self.debugPause { try await Task.sleep(for: pause) }
            // center_trim back to the chunk's own length, then weighted overlap-add.
            let delta = Self.segment - chunkLength
            let trim = delta / 2
            for s in 0..<S {
                for ch in 0..<2 {
                    for i in 0..<chunkLength {
                        out[s][ch][offset + i] += weight[i] * full[s][ch][trim + i]
                    }
                }
            }
            for i in 0..<chunkLength { sumWeight[offset + i] += weight[i] }
            progress?(Double(index + 1) / Double(offsets.count))
        }
        for s in 0..<S {
            for ch in 0..<2 {
                for i in 0..<length { out[s][ch][i] = out[s][ch][i] / sumWeight[i] * refStd + mean }
            }
        }
        return out
    }

    // MARK: - One segment

    /// The model on exactly one training segment of the normalised mix: `[stem][channel][sample]`,
    /// verified by a second run when ``verifying``.
    public func separateSegment(_ mix: [[Float]]) async throws -> [[[Float]]] {
        precondition(mix.count == 2 && mix[0].count == Self.segment && mix[1].count == Self.segment)
        let (mag, frames) = stft.spectrogram(mix)
        let stats = Self.segmentStats(mix: mix, mag: mag)
        let S = Self.sources.count
        let stemSpec = 4 * DemucsSTFT.bins * frames
        var spec = [Float](), time = [Float]()
        for (k, function) in functions.enumerated() {
            let out = try await verified(function, mix: mix, mag: mag, frames: frames, stats: stats)
            if functions.count == 1 { spec = out.spec; time = out.time; break }
            // A bag: only stem k of model k counts (upstream's one-hot weights).
            spec.append(contentsOf: out.spec[(k * stemSpec)..<((k + 1) * stemSpec)])
            time.append(contentsOf: out.time[(k * 2 * Self.segment)..<((k + 1) * 2 * Self.segment)])
        }
        precondition(spec.count == S * stemSpec && time.count == S * 2 * Self.segment)
        return stems(fromSpec: spec, time: time, frames: frames)
    }

    /// One function on one segment, run twice and compared when ``verifying``, a third run settling a mismatch.
    /// Up to ``verificationAttempts`` runs; the first two that agree bit for bit win.
    public static let verificationAttempts = 5

    private func verified(_ function: InferenceFunction, mix: [[Float]], mag: [Float], frames: Int, stats: [Float]) async throws -> (spec: [Float], time: [Float]) {
        let first = try await network(function, mix: mix, mag: mag, frames: frames, stats: stats)
        guard verifying else { return first }
        var runs = [first]
        for attempt in 1..<Self.verificationAttempts {
            let next = try await network(function, mix: mix, mag: mag, frames: frames, stats: stats)
            if let match = runs.first(where: { $0.spec == next.spec && $0.time == next.time }) {
                if attempt > 1 { recomputedSegments += 1 }
                return match
            }
            runs.append(next)
        }
        // Say how far apart the runs were: float noise (≥120 dB) means the GPU is not
        // repeatable under this load; 60–110 dB is the wrong-segment fault.
        let spread = runs.dropFirst().map { String(format: "%.0f dB", Self.psnr(runs[0].spec + runs[0].time, $0.spec + $0.time)) }.joined(separator: ", ")
        throw StemError.model("\(Self.verificationAttempts) runs of one segment never agreed (against the first: \(spread)); the GPU is not computing reliably — is another GPU job running?")
    }

    /// Peak signal-to-noise ratio of `b` against `a`, in dB, for diagnostics.
    static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        var err = 0.0, lo = Double.infinity, hi = -Double.infinity
        for i in a.indices { let d = Double(a[i]) - Double(b[i]); err += d * d; lo = min(lo, Double(a[i])); hi = max(hi, Double(a[i])) }
        let rms = (err / Double(max(1, a.count))).squareRoot()
        return rms == 0 ? .infinity : 20 * log10((hi - lo) / rms)
    }

    /// Upstream's per-segment normalisation statistics: mean and unbiased std over every element.
    static func segmentStats(mix: [[Float]], mag: [Float]) -> [Float] {
        let (magMean, magStd) = stats(mag, unbiased: true)
        let (mixMean, mixStd) = stats(mix[0] + mix[1], unbiased: true)
        return [magMean, magStd, mixMean, mixStd]
    }

    /// The network alone: spectrogram-domain and time-domain stems as flat vectors.
    private func network(_ function: InferenceFunction, mix: [[Float]], mag: [Float], frames: Int, stats: [Float]) async throws -> (spec: [Float], time: [Float]) {
        let S = Self.sources.count
        var spec = NDArray(shape: [1, S * 4, DemucsSTFT.bins, frames], scalarType: .float32)
        var time = NDArray(shape: [1, S * 2, Self.segment], scalarType: .float32)
        return try await run(function, inputs: [
            "mix": Self.array(mix[0] + mix[1], shape: [1, 2, Self.segment]),
            "mag": Self.array(mag, shape: [1, 4, DemucsSTFT.bins, frames]),
            "stats": Self.array(stats, shape: [4]),
        ], spec: &spec, time: &time)
    }

    /// Inverse STFT of each stem's spectrogram plus its time-branch part.
    private func stems(fromSpec specValues: [Float], time timeValues: [Float], frames: Int) -> [[[Float]]] {
        let S = Self.sources.count
        let stemSpec = 4 * DemucsSTFT.bins * frames
        var stems: [[[Float]]] = []
        for s in 0..<S {
            var wave = stft.inverse(Array(specValues[(s * stemSpec)..<((s + 1) * stemSpec)]), frames: frames, length: Self.segment)
            for ch in 0..<2 {
                let base = (s * 2 + ch) * Self.segment
                for i in 0..<Self.segment { wave[ch][i] += timeValues[base + i] }
            }
            stems.append(wave)
        }
        return stems
    }

    private func run(_ function: InferenceFunction, inputs: [String: NDArray], spec: inout NDArray, time: inout NDArray) async throws -> (spec: [Float], time: [Float]) {
        var views = InferenceFunction.MutableViews()
        views.insert(spec.mutableRawView(), for: "spec")
        views.insert(time.mutableRawView(), for: "time")
        do {
            _ = try await function.run(inputs: inputs, states: InferenceFunction.MutableViews(), outputViews: consume views)
        } catch {
            throw StemError.model("inference failed: \(error)")
        }
        if let pause = Self.debugReadPause { try await Task.sleep(for: pause) }   // diagnostics
        return (Self.floats(spec), Self.floats(time))
    }

    // MARK: - Helpers

    /// torch's `arange(1, L/2+1)` joined to `arange(L − L/2, 0, −1)`, divided by its maximum.
    static let transitionWeight: [Float] = {
        let L = segment
        var w = [Float]()
        w.reserveCapacity(L)
        for i in 1...(L / 2) { w.append(Float(i)) }
        for i in stride(from: L - L / 2, to: 0, by: -1) { w.append(Float(i)) }
        let maximum = w.max()!
        return w.map { $0 / maximum }
    }()

    /// `TensorChunk.padded`: the chunk widened to `target` about its centre with
    /// whatever real audio surrounds it, zeros beyond the ends of the recording.
    static func centredPad(_ channels: [[Float]], offset: Int, length: Int, target: Int) -> [[Float]] {
        let total = channels[0].count
        let delta = target - length
        let start = offset - delta / 2
        return channels.map { ch in
            (0..<target).map { i in
                let index = start + i
                return index >= 0 && index < total ? ch[index] : 0
            }
        }
    }

    /// Mean and standard deviation as torch computes them (double accumulation, Bessel when `unbiased`).
    static func stats(_ x: [Float], unbiased: Bool) -> (mean: Float, std: Float) {
        let n = Double(x.count)
        var sum = 0.0
        for v in x { sum += Double(v) }
        let mean = sum / n
        var sq = 0.0
        for v in x { let d = Double(v) - mean; sq += d * d }
        return (Float(mean), Float((sq / (unbiased ? n - 1 : n)).squareRoot()))
    }

    static func array(_ values: [Float], shape: [Int]) -> NDArray {
        var a = NDArray(shape: shape, scalarType: .float32)
        var view = a.mutableView(as: Float.self)
        view.withUnsafeMutablePointer { p, _, _ in
            values.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: values.count) }
        }
        return a
    }

    static func floats(_ array: NDArray) -> [Float] {
        let view = array.view(as: Float.self)
        let count = array.shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        view.withUnsafePointer { p, _, _ in out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: count) } }
        return out
    }
}
