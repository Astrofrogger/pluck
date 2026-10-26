import CoreGraphics
import Foundation

/// Level Exposure: evens out the brightness (and, with ⌥, the colour cast) of a set of photos, by adding
/// an offset to each one's own settings. The reference photo, or else the group's median, is the target.
@MainActor
enum PhotoLevel {
    typealias Offsets = (exposure: Double, temperature: Double, tint: Double)

    /// What a photo looks like at 256 px: its middle-tone brightness (median luma, in linear light)
    /// and its cast (red against blue, green against both), as stops.
    struct Reading {
        var luma: Double
        var warmth: Double
        var green: Double
    }

    /// The offsets that bring each photo to the target; photos that can't be rendered are left out.
    static func offsets(_ paths: [String], reference: String?, whiteBalance: Bool) async -> [String: Offsets] {
        var readings: [String: Reading] = [:]
        for path in paths {
            if let reading = await measure(path) { readings[path] = reading }
        }
        guard !readings.isEmpty else { return [:] }
        let target: Reading
        if let reference, let mine = readings[reference] {
            target = mine
        } else {
            target = Reading(luma: median(readings.values.map(\.luma)), warmth: median(readings.values.map(\.warmth)),
                             green: median(readings.values.map(\.green)))
        }
        return readings.mapValues { reading in
            var stops = min(max(log2(target.luma / reading.luma), -1.5), 1.5)
            stops = (stops / 0.05).rounded() * 0.05
            if abs(stops) < 0.1 { stops = 0 }
            var temperature = 0.0, tint = 0.0
            if whiteBalance {
                // Pluck's scale: each 100 is 1.3 stops of colour.
                temperature = min(max(((target.warmth - reading.warmth) / 1.3 * 100).rounded(), -30), 30)
                tint = min(max(((reading.green - target.green) / 1.3 * 100).rounded(), -30), 30)
            }
            return (stops, temperature, tint)
        }
    }

    /// While a set is being levelled: a second Level Exposure would add its offsets on top.
    private static var running = false

    /// Adds the offsets to each photo's settings, as one undo step.
    static func level(_ paths: [String], reference: String?, whiteBalance: Bool) async {
        guard paths.count >= 2, !running else { return }
        running = true
        defer { running = false }
        let found = await offsets(paths, reference: reference, whiteBalance: whiteBalance)
        let moves = found.filter { $0.value.exposure != 0 || $0.value.temperature != 0 || $0.value.tint != 0 }
        guard !moves.isEmpty else { return }
        PhotoCatalog.shared.endStep()
        // `update` goes through the photos in this order.
        let touched = paths.filter { moves[$0] != nil }
        var next = 0
        PhotoCatalog.shared.update(touched) { record in
            defer { next += 1 }
            guard let move = moves[touched[next]] else { return }
            record.adjust.exposure = min(max(record.adjust.exposure + move.exposure, -5), 5)
            record.adjust.temperature = min(max(record.adjust.temperature + move.temperature, -100), 100)
            record.adjust.tint = min(max(record.adjust.tint + move.tint, -100), 100)
        }
        PhotoCatalog.shared.endStep()
    }

    /// The photo rendered small with its current settings, read as linear light.
    static func measure(_ path: String) async -> Reading? {
        guard let image = try? await PhotoRender.develop(path, record: PhotoCatalog.shared.record(path), maxSize: 256) else { return nil }
        return await Task.detached(priority: .userInitiated) { reading(of: image) }.value
    }

    /// The median luma and the average cast of a picture.
    nonisolated static func reading(of image: CGImage) -> Reading? {
        let width = min(image.width, 256), height = min(image.height, 256)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // sRGB to linear light, once per 8-bit value.
        let linear = (0...255).map { value -> Double in
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        var red = 0.0, green = 0.0, blue = 0.0
        for i in 0..<(width * height) {
            let r = linear[Int(pixels[i * 4])], g = linear[Int(pixels[i * 4 + 1])], b = linear[Int(pixels[i * 4 + 2])]
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            red += r; green += g; blue += b
        }
        let luma = median(lumas)
        guard luma > 0, red > 0, green > 0, blue > 0 else { return nil }
        return Reading(luma: luma, warmth: log2(red / blue), green: log2(green / (red * blue).squareRoot()))
    }

    nonisolated private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
