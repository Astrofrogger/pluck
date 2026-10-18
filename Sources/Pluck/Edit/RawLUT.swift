import CoreImage
import Foundation

/// LUTs for Raw Player: a .cube over the developed picture, the folders they're found in
/// (DaVinci Resolve's own, and any added), shown by name.
enum RawLUT {
    /// Unmanaged: a LUT maps the picture's numbers as they are (log in, Rec.709 out).
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    nonisolated(unsafe) private static var cubes: [String: (size: Int, data: Data)] = [:]
    private static let lock = NSLock()

    /// The picture through the LUT (as it is, without one or when the file can't be read).
    static func apply(_ image: CGImage, lut path: String?) -> CGImage {
        guard let path, let cube = cube(path) else { return image }
        let input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(cube.size, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        filter.setValue(input, forKey: kCIInputImageKey)
        // Into plain memory (an image Core Image keeps on the GPU doesn't always draw), tagged
        // Rec.709 (what LUTs make), with no conversion: the context works unmanaged.
        guard let output = filter.outputImage else { return image }
        let width = image.width, height = image.height, rowBytes = width * 8
        var pixels = Data(count: rowBytes * height)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: input.extent, format: .RGBA16, colorSpace: space)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let made = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return made
    }

    /// The LUT as Core Image's cube (at most 64 a side: bigger ones are sampled down).
    private static func cube(_ path: String) -> (size: Int, data: Data)? {
        if let known = lock.withLock({ cubes[path] }) { return known }
        guard let file = LUTFile.read(path) else { return nil }
        let size = min(file.size, 64)
        var values = [Float](repeating: 1, count: size * size * size * 4)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let n = Double(size - 1)
            let low = file.domainMin, high = file.domainMax
            let color = file.sample(low[0] + Double(r) / n * (high[0] - low[0]), low[1] + Double(g) / n * (high[1] - low[1]),
                                    low[2] + Double(b) / n * (high[2] - low[2]))
            let o = ((b * size + g) * size + r) * 4
            values[o] = Float(color[0]); values[o + 1] = Float(color[1]); values[o + 2] = Float(color[2])
        } } }
        let cube = (size, values.withUnsafeBufferPointer { Data(buffer: $0) })
        lock.withLock { cubes[path] = cube }
        return cube
    }

    // MARK: - Folders

    /// Where DaVinci Resolve keeps its LUTs (when it's installed).
    static let resolveFolders = ["/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT",
                                 NSHomeDirectory() + "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"]
        .filter { FileManager.default.fileExists(atPath: $0) }

    /// The .cube files in a folder and the folders in it (a few levels down), grouped by folder.
    static func luts(in folder: String) -> [(group: String, files: [URL])] {
        let root = URL(fileURLWithPath: folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var groups: [String: [URL]] = [:]
        var count = 0
        while let url = walker.nextObject() as? URL, count < 400 {
            if walker.level > 3 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "cube" else { continue }
            let group = url.deletingLastPathComponent().path == root.path ? root.lastPathComponent : url.deletingLastPathComponent().lastPathComponent
            groups[group, default: []].append(url)
            count += 1
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            (key, groups[key]!.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }
}
