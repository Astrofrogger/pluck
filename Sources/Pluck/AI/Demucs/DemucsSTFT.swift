//  Vendored from swift-vocal-isolation v1.2.0 by David Sherlock (ArrayPress), MIT licence:
//  https://github.com/arraypress/swift-vocal-isolation — see ThirdPartyLicenses.md.
//  Changes for Pluck: macOS 27 availability, input is always 44.1 kHz stereo (no resampling
//  or file reading here), its error type replaced by `StemError`.
//
//  DemucsSTFT.swift
//  VocalIsolation
//
//  Created by David Sherlock on 2026.
//
//  HTDemucs's `_spec` and `_ispec`, in vDSP. Upstream: n_fft 4096, hop 1024,
//  periodic Hann, `normalized=True` (×1/√n_fft forward, ×√n_fft inverse),
//  centre reflect padding; but before the STFT the signal is reflect-padded
//  by 3·hop/2 on the left and enough on the right to make the length a
//  multiple of the hop, the Nyquist bin is dropped and two frames are trimmed
//  from each end, so that frames = ⌈length / hop⌉ and the two branches of
//  the network align. The inverse undoes exactly that: Nyquist zeroed, two
//  zero frames each side, overlap-add with window-square normalisation,
//  trim. Layout is complex-as-channels `[Lᵣ, Lᵢ, Rᵣ, Rᵢ][2048][frames]`.
//

import Accelerate
import Foundation

/// The spectrogram HTDemucs sees, and the way back.
final class DemucsSTFT {

    static let nFFT = 4096
    static let hop = 1024
    /// Frequency bins kept: n_fft / 2, the Nyquist bin dropped.
    static let bins = nFFT / 2
    /// Reflect padding before the STFT: 3·hop/2.
    static let edge = hop / 2 * 3

    private let window: [Float]
    private let windowSq: [Float]
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup

    init?() {
        var w = [Float](repeating: 0, count: Self.nFFT)
        for n in 0..<Self.nFFT { w[n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.nFFT))) }
        window = w
        windowSq = w.map { $0 * $0 }
        guard let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD),
              let i = vDSP_DFT_zop_CreateSetup(f, vDSP_Length(Self.nFFT), .INVERSE) else { return nil }
        fwd = f; inv = i
    }

    deinit { vDSP_DFT_DestroySetup(inv); vDSP_DFT_DestroySetup(fwd) }

    /// ⌈samples / hop⌉: the frames `_spec` returns for a signal of that length.
    static func frames(forSamples count: Int) -> Int { (count + hop - 1) / hop }

    // MARK: - Forward

    /// `_spec` then `_magnitude` (cac): stereo → `[4][bins][frames]`.
    func spectrogram(_ channels: [[Float]]) -> (values: [Float], frames: Int) {
        let length = channels[0].count
        let le = Self.frames(forSamples: length)
        let padLeft = Self.edge
        let padRight = Self.edge + le * Self.hop - length
        let scale = 1 / Float(Self.nFFT).squareRoot()
        var spec = [Float](repeating: 0, count: 4 * Self.bins * le)
        var frameReal = [Float](repeating: 0, count: Self.nFFT)
        let frameImag = [Float](repeating: 0, count: Self.nFFT)
        var outR = [Float](repeating: 0, count: Self.nFFT)
        var outI = [Float](repeating: 0, count: Self.nFFT)
        spec.withUnsafeMutableBufferPointer { sp in
            for ch in 0..<2 {
                // Upstream pads by (edge, edge + le·hop − length) with reflection, then
                // torch.stft centre-pads n_fft/2 with reflection again.
                let padded = Self.reflectPadded(Self.reflectPadded(channels[ch], left: padLeft, right: padRight),
                                                left: Self.nFFT / 2, right: Self.nFFT / 2)
                let reBase = (2 * ch) * Self.bins * le, imBase = (2 * ch + 1) * Self.bins * le
                padded.withUnsafeBufferPointer { pp in
                    for frame in 0..<le {
                        // Frames 0 and 1 and the last two of the full STFT are discarded.
                        let start = (frame + 2) * Self.hop
                        vDSP_vmul(pp.baseAddress! + start, 1, window, 1, &frameReal, 1, vDSP_Length(Self.nFFT))
                        vDSP_DFT_Execute(fwd, frameReal, frameImag, &outR, &outI)
                        var s = scale
                        vDSP_vsmul(outR, 1, &s, &outR, 1, vDSP_Length(Self.bins))
                        vDSP_vsmul(outI, 1, &s, &outI, 1, vDSP_Length(Self.bins))
                        for k in 0..<Self.bins {
                            sp[reBase + k * le + frame] = outR[k]
                            sp[imBase + k * le + frame] = outI[k]
                        }
                    }
                }
            }
        }
        return (spec, le)
    }

    // MARK: - Inverse

    /// The overlap-added window-square envelope for a frame count, shared by every stem and channel.
    private var envelopes: [Int: [Float]] = [:]

    private func envelope(frames total: Int, paddedLen: Int) -> [Float] {
        if let cached = envelopes[total] { return cached }
        var envelope = [Float](repeating: 0, count: paddedLen)
        envelope.withUnsafeMutableBufferPointer { ep in
            for frame in 0..<total {
                let off = frame * Self.hop
                vDSP_vadd(ep.baseAddress! + off, 1, windowSq, 1, ep.baseAddress! + off, 1, vDSP_Length(Self.nFFT))
            }
        }
        envelopes[total] = envelope
        return envelope
    }

    /// `_mask` (cac → complex) then `_ispec`: one stem's `[4][bins][frames]` → stereo of `length` samples.
    func inverse(_ spec: [Float], frames le: Int, length: Int) -> [[Float]] {
        precondition(spec.count == 4 * Self.bins * le)
        let total = le + 4                                  // two zero frames padded each side
        let paddedLen = (total - 1) * Self.hop + Self.nFFT  // what torch.istft reconstructs before trimming
        let targetLen = Self.hop * Self.frames(forSamples: length) + 2 * Self.edge   // istft(length=)
        let centre = Self.nFFT / 2
        precondition(centre + Self.edge + length <= paddedLen && Self.edge + length <= targetLen)
        let scale = Float(Self.nFFT).squareRoot() / Float(Self.nFFT)   // normalized=True, and the DFT's 1/N
        // The envelope counts every frame, the zero ones included.
        let envelope = envelope(frames: total, paddedLen: paddedLen)
        var out: [[Float]] = []
        var fullR = [Float](repeating: 0, count: Self.nFFT)
        var fullI = [Float](repeating: 0, count: Self.nFFT)
        var timeR = [Float](repeating: 0, count: Self.nFFT)
        var timeI = [Float](repeating: 0, count: Self.nFFT)
        var tmp = [Float](repeating: 0, count: Self.nFFT)
        var scaledWindow = [Float](repeating: 0, count: Self.nFFT)
        var s = scale
        vDSP_vsmul(window, 1, &s, &scaledWindow, 1, vDSP_Length(Self.nFFT))
        spec.withUnsafeBufferPointer { sp in
            for ch in 0..<2 {
                let reBase = (2 * ch) * Self.bins * le, imBase = (2 * ch + 1) * Self.bins * le
                var recon = [Float](repeating: 0, count: paddedLen)
                recon.withUnsafeMutableBufferPointer { rp in
                    for source in 0..<le {
                        let off = (source + 2) * Self.hop
                        for k in 0..<Self.bins {
                            fullR[k] = sp[reBase + k * le + source]
                            fullI[k] = sp[imBase + k * le + source]
                        }
                        fullR[Self.bins] = 0; fullI[Self.bins] = 0            // Nyquist, zero-padded upstream
                        for k in (Self.bins + 1)..<Self.nFFT { fullR[k] = fullR[Self.nFFT - k]; fullI[k] = -fullI[Self.nFFT - k] }
                        vDSP_DFT_Execute(inv, fullR, fullI, &timeR, &timeI)
                        vDSP_vmul(timeR, 1, scaledWindow, 1, &tmp, 1, vDSP_Length(Self.nFFT))
                        vDSP_vadd(rp.baseAddress! + off, 1, tmp, 1, rp.baseAddress! + off, 1, vDSP_Length(Self.nFFT))
                    }
                }
                // torch.istft divides by the envelope and drops the n_fft/2 centre pad; _ispec drops `edge` more.
                var channel = [Float](repeating: 0, count: length)
                recon.withUnsafeBufferPointer { rp in
                    envelope.withUnsafeBufferPointer { ep in
                        vDSP_vdiv(ep.baseAddress! + centre + Self.edge, 1, rp.baseAddress! + centre + Self.edge, 1, &channel, 1, vDSP_Length(length))
                    }
                }
                out.append(channel)
            }
        }
        return out
    }

    // MARK: - Padding

    /// torch reflect padding: the sample at the edge is not repeated.
    static func reflectPadded(_ x: [Float], left: Int, right: Int) -> [Float] {
        let n = x.count
        precondition(left < n && right < n, "reflect padding must be shorter than the signal")
        var out = [Float](repeating: 0, count: n + left + right)
        for i in 0..<left { out[i] = x[left - i] }
        for i in 0..<n { out[left + i] = x[i] }
        for j in 0..<right { out[left + n + j] = x[n - 2 - j] }
        return out
    }
}
