import ImageIO
import SwiftUI

/// A photo shown in its pane, as Quick Look does: as large as the pane allows, the folder's
/// other photos a key away (← →), Esc or Space to go back to the folder.
struct FinderPhotoView: View {
    let pane: FinderPane
    let url: URL
    @State private var thumbs = FinderThumbnails.shared
    @State private var image: CGImage?
    @State private var details: FinderPhotoDetails?
    @State private var size: CGSize = .zero
    @FocusState private var focused: Bool

    var body: some View {
        let photos = pane.photos
        let index = photos.firstIndex(of: url)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { pane.viewing = nil } label: { Image(systemName: "chevron.left") }
                    .help("Back to \(pane.title)")
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle).padding(.leading, 4)
                Spacer(minLength: 8)
                if let index, photos.count > 1 {
                    Text("\(index + 1) of \(photos.count)").foregroundStyle(.secondary).monospacedDigit()
                    Button { pane.view(by: -1) } label: { Image(systemName: "arrow.left") }
                        .disabled(index == 0)
                        .help("Previous photo (←)")
                    Button { pane.view(by: 1) } label: { Image(systemName: "arrow.right") }
                        .disabled(index == photos.count - 1)
                        .help("Next photo (→)")
                }
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(FinderPhotoView.openTitle(url))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ZStack {
                Design.Photo.surround
                if let shown = image ?? thumbs.pictures[url] {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(Design.Spacing.inset)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            if let details, !details.line.isEmpty {
                Divider()
                Text(details.line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; thumbs.wantPicture(url) }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                // (⌘↑, as in the folder: back to it.)
                if press.key == .upArrow { pane.viewing = nil; return .handled }
                return .ignored
            }
            pane.view(by: press.key == .leftArrow || press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(.space) { pane.viewing = nil; return .handled }
        .onKeyPress(.escape) { pane.viewing = nil; return .handled }
        // The whole photo at the pane's size (sharp on its display), its neighbours read ahead.
        .task(id: "\(url.path)|\(Int(longest))") {
            let wanted = longest
            guard wanted > 0 else { return }
            if let cached = FinderPhotoCache.shared.image(url, longest: wanted) {
                image = cached
            } else {
                image = nil
                image = await FinderPhotoCache.shared.load(url, longest: wanted)
            }
            details = await Task.detached(priority: .utility) { [url] in FinderPhotoDetails(url) }.value
            if let index {
                for near in [index + 1, index - 1] where photos.indices.contains(near) {
                    _ = await FinderPhotoCache.shared.load(photos[near], longest: wanted)
                }
            }
        }
    }

    /// The pane's longest side in pixels (in steps, so resizing the pane doesn't read it again and again).
    private var longest: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(size.width, size.height) * scale
        return (pixels / 512).rounded(.up) * 512
    }

    /// "Open with Preview", by the app that opens it.
    static func openTitle(_ url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return String(localized: "Open") }
        return String(localized: "Open with \(FileManager.default.displayName(atPath: app.path))")
    }
}

/// The photos read for the viewer: the last few kept, so going back and forth is instant.
final class FinderPhotoCache: @unchecked Sendable {
    static let shared = FinderPhotoCache()
    private let lock = NSLock()
    private var kept: [(url: URL, longest: CGFloat, image: CGImage)] = []
    /// (The one shown and the two either side.)
    private static let count = 3

    func image(_ url: URL, longest: CGFloat) -> CGImage? {
        lock.withLock { kept.first { $0.url == url && $0.longest == longest }?.image }
    }

    /// The photo, its longest side `longest` pixels at most (never larger than it is), turned
    /// the way the camera was held.
    func load(_ url: URL, longest: CGFloat) async -> CGImage? {
        if let image = image(url, longest: longest) { return image }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: Int(longest)]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let image {
            lock.withLock {
                kept.removeAll { $0.url == url }
                kept.append((url, longest, image))
                if kept.count > Self.count { kept.removeFirst() }
            }
        }
        return image
    }
}

/// What the viewer says about a photo: its size, the camera and how it was taken, when.
struct FinderPhotoDetails: Sendable {
    let line: String

    init(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { line = ""; return }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var parts: [String] = []
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // (Turned, for a photo taken upright.)
            let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            parts.append(turned ? "\(height)×\(width)" : "\(width)×\(height)")
        }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { parts.append(model.trimmingCharacters(in: .whitespaces)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { parts.append(lens.trimmingCharacters(in: .whitespaces)) }
        if let length = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(length.rounded())) mm") }
        if let number = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "ƒ/%g", (number * 10).rounded() / 10)) }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            parts.append(time >= 1 ? String(format: "%gs", time) : "1/\(Int((1 / time).rounded()))s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let reader = DateFormatter()
            reader.locale = Locale(identifier: "en_US_POSIX")
            reader.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = reader.date(from: taken) { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        }
        line = parts.joined(separator: " · ")
    }
}
