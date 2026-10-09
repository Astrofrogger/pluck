import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compressing photos on this Mac with ImageIO: re-encode as JPEG or HEIC at a chosen quality,
/// optionally smaller and without location or camera details.
enum Photos {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case jpeg, heic

        var id: String { rawValue }
        var label: String { self == .jpeg ? "JPEG" : "HEIC" }
        var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
        var type: UTType { self == .jpeg ? .jpeg : .heic }
    }

    /// Longest-edge limits offered, in pixels.
    static let sizes = [3840, 2560, 1920, 1280, 1024]

    /// Still images ImageIO can read. Animated GIFs and vector formats are left out.
    static func isPhoto(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .gif) && !type.conforms(to: .svg) && !type.conforms(to: .pdf)
    }

    struct Settings: Equatable, Sendable {
        var format: Format
        /// 0.1...1
        var quality: Double
        /// Longest edge, or nil to keep the size.
        var maxPixel: Int?
        var removeDetails: Bool
    }

    /// The compressed photo, or nil if it couldn't be read.
    static func compress(_ file: URL, _ settings: Settings) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        // Decoding through the thumbnail call applies the camera's rotation and scales in one go.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(settings.maxPixel ?? longest, longest),
        ]
        guard longest > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // The pixels are already upright, so the orientation tag must say so.
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { properties.removeValue(forKey: key) }
        if settings.removeDetails {
            // Keep only what's needed to show the photo right: colour profile and orientation.
            properties = properties.filter { [kCGImagePropertyOrientation, kCGImagePropertyProfileName,
                                              kCGImagePropertyColorModel, kCGImagePropertyDPIWidth,
                                              kCGImagePropertyDPIHeight].contains($0.key) }
        }
        properties[kCGImageDestinationLossyCompressionQuality] = settings.quality

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, settings.format.type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
