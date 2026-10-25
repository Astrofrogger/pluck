import CoreImage
import Foundation

/// A look over a part of the timeline (an adjustment layer): the colour controls of a clip, on
/// everything under it from `start` to `end`, mixed with the picture as it was by `amount`.
struct ProjectAdjustment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var color = ClipColor()
    var amount = 1.0

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        color = (try? c.decodeIfPresent(ClipColor.self, forKey: .color)) ?? ClipColor()
        amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 1
    }

    /// Changes the picture at all.
    var isVisible: Bool { amount > 0.001 && !color.isDefault }

    func contains(_ seconds: Double) -> Bool { seconds >= start - 0.0005 && seconds < end - 0.0005 }

    nonisolated(unsafe) private static var cubes: [ProjectAdjustment: Data] = [:]
    private static let lock = NSLock()

    /// The colour's table mixed with no change by `amount` (as RGBA floats, red fastest). The same
    /// table goes to the viewer and to ffmpeg, so both show the same.
    func cube() -> Data {
        var key = self
        key.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        key.start = 0
        key.end = 0
        Self.lock.lock()
        if let known = Self.cubes[key] { Self.lock.unlock(); return known }
        Self.lock.unlock()
        let full = color.cube()
        guard amount < 0.999 else { return full }
        var values = full.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = ClipColor.size, mix = Float(min(max(amount, 0), 1))
        for i in 0..<(n * n * n) {
            let plain = [i % n, (i / n) % n, i / (n * n)].map { Float($0) / Float(n - 1) }
            for k in 0..<3 { values[i * 4 + k] = plain[k] + (values[i * 4 + k] - plain[k]) * mix }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        Self.lock.lock(); Self.cubes[key] = data; if Self.cubes.count > 32 { Self.cubes.removeValue(forKey: Self.cubes.keys.first!) }; Self.lock.unlock()
        return data
    }

    /// The same table as a .cube file, for ffmpeg.
    func cubeFile() -> URL? {
        let floats = cube().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var text = "LUT_3D_SIZE \(ClipColor.size)\n"
        for i in stride(from: 0, to: floats.count, by: 4) {
            text += String(format: "%.6f %.6f %.6f\n", floats[i], floats[i + 1], floats[i + 2])
        }
        // Named for what's in it (the same table the same file, across launches too).
        var name: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { name = (name ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-look-\(String(name, radix: 16)).cube")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    func apply(_ image: CIImage) -> CIImage {
        guard isVisible else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": ClipColor.size, "inputCubeData": cube(),
                                                                               "inputColorSpace": ProjectCompositor.video])
    }

    /// For the export: after the pictures laid over the main line, each look while it's on.
    nonisolated static func ffmpegSteps(_ adjustments: [ProjectAdjustment]) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        let shown = adjustments.filter(\.isVisible)
        guard !shown.isEmpty else { return [] }
        // 16 bits, so a 10-bit export (ProRes) or a camera's log keeps its depth.
        return ["format=rgb48le"] + shown.compactMap { look in
            look.cubeFile().map { "lut3d=file='\($0.path.replacingOccurrences(of: "'", with: "\\'"))':enable='gte(t,\(number(look.start)))*lt(t,\(number(look.end)))'" }
        }
    }
}

extension ProjectModel {
    /// A look over this part of the timeline (5 s from the playhead when it's a moment), in one step.
    @discardableResult
    func addAdjustment(over range: ClosedRange<Double>) -> UUID {
        let end = range.upperBound - range.lowerBound < frame ? range.lowerBound + 5 : range.upperBound
        let look = ProjectAdjustment(start: max(range.lowerBound, 0), end: min(end, max(project.duration, range.lowerBound + frame)))
        change { $0.adjustments = ($0.adjustments ?? []) + [look] }
        return look.id
    }

    /// A look over the part between the in and out points, else over the clips chosen, else 5 s
    /// from the playhead. It's chosen, to set in the inspector.
    func addAdjustmentHere() {
        var range = time...time
        if let inPoint = project.inPoint, let outPoint = project.outPoint, outPoint > inPoint {
            range = inPoint...outPoint
        } else {
            let chosen = project.clips.indices.filter { selected.contains(project.clips[$0].id) }
            if let first = chosen.first, let last = chosen.last {
                let starts = offsets
                range = starts[first]...(starts[last] + project.clips[last].length)
            }
        }
        selected = [addAdjustment(over: range)]
    }

    func removeAdjustment(_ id: UUID) {
        guard project.adjustments?.contains(where: { $0.id == id }) == true else { return }
        change { project in
            project.adjustments?.removeAll { $0.id == id }
            if project.adjustments?.isEmpty == true { project.adjustments = nil }
        }
    }

    func adjustment(_ id: UUID) -> ProjectAdjustment? { project.adjustments?.first { $0.id == id } }
}
