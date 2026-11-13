import CoreImage
import Foundation
import ImageIO

/// A merged photo (HDR, panorama, focus stack) kept as a raw file: a scene-linear DNG ("LinearRaw", 16-bit float, three
/// colours a pixel), so it opens in Pluck, Lightroom or Photos with the same room to edit as the frames it came from,
/// highlights above white included. Written by hand (ImageIO can't write DNG): one little-endian TIFF IFD, uncompressed strips.
enum PhotoDNG {
    struct Unwritable: LocalizedError {
        var errorDescription: String? { String(localized: "The merged photo couldn’t be saved as a DNG.") }
    }

    /// The camera's colours are linear sRGB (Core Image's working space), so ColorMatrix1 is XYZ → linear sRGB under the
    /// calibration illuminant, D65. Per the DNG spec the matrix takes XYZ *as lit by that illuminant* (not adapted to D50):
    /// the reader finds the white from AsShotNeutral through this matrix (1,1,1 → D65's xy), then adapts that white to D50
    /// itself (Bradford). A D50-adapted matrix gives the same colours but tells the reader the light was 5000 K, which
    /// throws off its white balance sliders. These are the IEC 61966-2-1 numbers, the inverse of sRGB → XYZ (D65).
    private static let colorMatrix: [Double] = [
        3.2404542, -1.5371385, -0.4985314,
        -0.9692660, 1.8760108, 0.0415560,
        0.0556434, -0.2040259, 1.0572252,
    ]

    /// `image` (linear light in Core Image's working space: linear sRGB primaries, D65) written to `url` as a DNG.
    /// Rendered and written a strip at a time, so a 60 MP merge never needs the whole picture in memory at once.
    /// `baselineExposure` (stops) tells a reader how far to brighten it by default; `source` (a CGImageSource properties
    /// dictionary of one of the frames) gives the camera make, model and date.
    nonisolated static func write(_ image: CIImage, to url: URL, context: CIContext, baselineExposure: Double = 0, source: [String: Any]? = nil) throws {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { throw Unwritable() }
        let width = Int(extent.width), height = Int(extent.height)
        let rowBytes = width * 6
        let rowsPerStrip = max(1, min(height, (4 << 20) / rowBytes))
        let strips = (height + rowsPerStrip - 1) / rowsPerStrip
        guard width * height * 6 < Int(UInt32.max) - (1 << 20) else { throw Unwritable() } // (TIFF offsets are 32 bits)

        var ifd = IFD()
        ifd.add(254, long: [0]) // NewSubFileType: the main image
        ifd.add(256, long: [UInt32(width)])
        ifd.add(257, long: [UInt32(height)])
        ifd.add(258, short: [16, 16, 16]) // BitsPerSample
        ifd.add(259, short: [1]) // Compression: none
        ifd.add(262, short: [34892]) // PhotometricInterpretation: LinearRaw
        let tiff = source?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        if let make = tiff?[kCGImagePropertyTIFFMake as String] as? String { ifd.add(271, ascii: make) }
        if let model = tiff?[kCGImagePropertyTIFFModel as String] as? String { ifd.add(272, ascii: model) }
        ifd.add(273, long: Array(repeating: 0, count: strips)) // StripOffsets, filled in below
        ifd.add(274, short: [1]) // Orientation: as stored (the frames were already turned upright)
        ifd.add(277, short: [3]) // SamplesPerPixel
        ifd.add(278, long: [UInt32(rowsPerStrip)])
        ifd.add(279, long: (0..<strips).map { UInt32(min(rowsPerStrip, height - $0 * rowsPerStrip) * rowBytes) })
        ifd.add(284, short: [1]) // PlanarConfiguration: chunky
        let exif = source?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let date = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            ifd.add(306, ascii: date) // DateTime
            ifd.add(36867, ascii: date) // DateTimeOriginal (TIFF/EP allows it in IFD0)
        }
        ifd.add(339, short: [3, 3, 3]) // SampleFormat: IEEE float
        ifd.add(50717, long: [1, 1, 1]) // WhiteLevel: set once the brightest value is known (below)
        ifd.add(50706, bytes: [1, 4, 0, 0]) // DNGVersion 1.4 (the first with float samples)
        ifd.add(50707, bytes: [1, 4, 0, 0]) // DNGBackwardVersion
        ifd.add(50708, ascii: "Pluck Merge") // UniqueCameraModel
        ifd.add(50721, srational: colorMatrix) // ColorMatrix1
        ifd.add(50728, rational: [1, 1, 1]) // AsShotNeutral: the colours are already balanced
        ifd.add(50730, srational: [baselineExposure]) // BaselineExposure, likewise
        ifd.add(50778, short: [21]) // CalibrationIlluminant1: D65

        // Header, IFD and its out-of-line values first, then the strips, in order.
        let start = UInt32(ifd.size(at: 8) + 8)
        ifd.set(273, long: (0..<strips).map { start + UInt32($0 * rowsPerStrip * rowBytes) })
        var head = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        head.append(ifd.encoded(at: 8))

        // Below black isn't light (and a reader would clip it anyway); colours outside sRGB lose their negative part.
        let clean = image.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                      "inputMaxComponents": CIVector(x: 65000, y: 65000, z: 65000, w: 1)])
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: head), let file = try? FileHandle(forWritingTo: partial) else { throw Unwritable() }
        do {
            defer { try? file.close() }
            try file.seekToEnd()
            var rgba = [UInt16](repeating: 0, count: rowsPerStrip * width * 4)
            var rgb = [UInt16](repeating: 0, count: rowsPerStrip * width * 3)
            var brightest: UInt16 = 0 // (non-negative halves sort as their bits do)
            for s in 0..<strips {
                let rows = min(rowsPerStrip, height - s * rowsPerStrip)
                // (A bitmap's first row is the top of the rectangle; Core Image counts y from the bottom.)
                let band = CGRect(x: extent.minX, y: extent.maxY - CGFloat(s * rowsPerStrip + rows), width: extent.width, height: CGFloat(rows))
                rgba.withUnsafeMutableBytes { context.render(clean, toBitmap: $0.baseAddress!, rowBytes: width * 8, bounds: band, format: .RGBAh, colorSpace: space) }
                let n = rows * width
                rgba.withUnsafeBufferPointer { i in rgb.withUnsafeMutableBufferPointer { o in
                    for p in 0..<n {
                        let r = i[4 * p], g = i[4 * p + 1], b = i[4 * p + 2]
                        o[3 * p] = r; o[3 * p + 1] = g; o[3 * p + 2] = b
                        brightest = max(brightest, r, g, b)
                    }
                } }
                try rgb.withUnsafeBytes { try file.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!), count: n * 6, deallocator: .none)) }
            }
            // A reader takes a float DNG's values as shares of WhiteLevel and clips there (without the tag Apple's decoder
            // assumed 65535 and everything came back black; with 1, all above 1 was clipped). So white is set just above
            // the brightest value, keeping every highlight, and BaselineExposure lifts by as much: a reader's default shows
            // the values as written (times 2^baselineExposure). The header is the same size either way, so it's written
            // again over the first.
            let white = UInt32(max(1, halfValue(brightest).rounded(.up)))
            ifd.add(50717, long: [white, white, white])
            ifd.add(50730, srational: [baselineExposure + log2(Double(white))])
            var final = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
            final.append(ifd.encoded(at: 8))
            guard final.count == head.count else { throw Unwritable() }
            try file.seek(toOffset: 0)
            try file.write(contentsOf: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Unwritable()
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Unwritable()
        }
    }

    /// One TIFF IFD: entries kept sorted by tag (as TIFF requires), values over four bytes stored after it.
    private struct IFD {
        private var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: Data)] = []

        mutating func add(_ tag: UInt16, type: UInt16, count: Int, _ value: Data) {
            entries.removeAll { $0.tag == tag }
            entries.append((tag, type, UInt32(count), value))
            entries.sort { $0.tag < $1.tag }
        }
        mutating func add(_ tag: UInt16, bytes: [UInt8]) { add(tag, type: 1, count: bytes.count, Data(bytes)) }
        mutating func add(_ tag: UInt16, ascii: String) {
            let text = Array(ascii.utf8) + [0]
            add(tag, type: 2, count: text.count, Data(text))
        }
        mutating func add(_ tag: UInt16, short: [UInt16]) { add(tag, type: 3, count: short.count, little(short)) }
        mutating func add(_ tag: UInt16, long: [UInt32]) { add(tag, type: 4, count: long.count, little(long)) }
        mutating func set(_ tag: UInt16, long: [UInt32]) { add(tag, long: long) }
        mutating func add(_ tag: UInt16, rational: [Double]) {
            add(tag, type: 5, count: rational.count, little(rational.flatMap { [UInt32(max($0, 0) * 1_000_000), 1_000_000] }))
        }
        mutating func add(_ tag: UInt16, srational: [Double]) {
            add(tag, type: 10, count: srational.count, little(srational.flatMap { [Int32($0 * 1_000_000), 1_000_000] }))
        }

        /// Bytes taken by the IFD placed at `offset`, its out-of-line values included.
        func size(at offset: Int) -> Int { encoded(at: offset).count }

        func encoded(at offset: Int) -> Data {
            var table = little([UInt16(entries.count)])
            var extra = Data()
            let extraStart = offset + 2 + entries.count * 12 + 4
            for e in entries {
                table.append(little([e.tag, e.type]))
                table.append(little([e.count]))
                if e.value.count <= 4 {
                    table.append(e.value + Data(count: 4 - e.value.count))
                } else {
                    table.append(little([UInt32(extraStart + extra.count)]))
                    extra.append(e.value)
                    if extra.count % 2 == 1 { extra.append(0) } // values start on a word boundary
                }
            }
            table.append(little([UInt32(0)])) // no next IFD
            return table + extra
        }

        private func little<T: FixedWidthInteger>(_ values: [T]) -> Data {
            values.reduce(into: Data()) { data, v in withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        }
    }

    /// A positive half float's value from its bits (Float16 isn't there on Intel Macs, which the app is also built for).
    nonisolated private static func halfValue(_ bits: UInt16) -> Float {
        let exponent = Int((bits >> 10) & 0x1F), fraction = Float(bits & 0x3FF)
        if exponent == 0 { return fraction / 1024 * pow(2, -14) }
        if exponent == 31 { return .greatestFiniteMagnitude }
        return (1 + fraction / 1024) * pow(2, Float(exponent - 15))
    }
}
