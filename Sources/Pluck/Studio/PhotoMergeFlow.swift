import CoreImage
import ImageIO
import SwiftUI

/// Merging photos (from a photo's menu in Browse): HDR from an exposure bracket, a panorama, or a focus stack (PhotoMerge),
/// written as a linear DNG (PhotoDNG) next to the first photo and put where it is (its albums; a watched folder finds it
/// itself). It then edits like any RAW. One merge at a time; the originals are never changed.
@MainActor
@Observable
final class PhotoMerger {
    static let shared = PhotoMerger()

    enum Kind: String, CaseIterable, Identifiable {
        case hdr, panorama, focus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hdr: String(localized: "HDR")
            case .panorama: String(localized: "Panorama")
            case .focus: String(localized: "Focus Stack")
            }
        }
        /// What goes on the merged file's name.
        var suffix: String {
            switch self {
            case .hdr: "HDR"
            case .panorama: "Pano"
            case .focus: "Stack"
            }
        }
    }

    private(set) var working: Kind?
    private(set) var problem: String?
    /// The last merged photo's key (to show it).
    private(set) var made: String?

    /// Merges these photos (2 or more, their files: copies count as their originals) and adds the result beside them.
    func merge(_ kind: Kind, keys: [String]) {
        guard working == nil else { return }
        var seen: Set<String> = []
        let files = keys.map(PhotoCatalog.file(of:)).filter { seen.insert($0).inserted }
        guard files.count >= 2 else { problem = String(localized: "Choose two or more photos to merge."); return }
        working = kind
        problem = nil
        let albums = PhotoCatalog.shared.albums.filter { album in files.contains(where: album.paths.contains) }.map(\.id)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result { try Self.make(kind, files: files) }
            }.value
            working = nil
            switch result {
            case .success(let url):
                for album in albums { PhotoCatalog.shared.add([url.path], to: album) }
                made = url.path
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    func dismissProblem() { problem = nil }

    /// The merge itself, off the main thread: every photo decoded whole (scene light, nothing of its edit), merged, written.
    nonisolated static func make(_ kind: Kind, files: [String]) throws -> URL {
        let context = PhotoEngine.context
        var frames: [CIImage] = []
        for file in files {
            guard let decoded = PhotoRender.decoded(file, maxSize: 16_384, record: PhotoRecord()) else {
                throw MergeFlowError.unreadable(URL(fileURLWithPath: file).lastPathComponent)
            }
            let e = decoded.extent
            frames.append(decoded.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)))
        }
        let merged: CIImage
        switch kind {
        case .hdr: merged = try PhotoMerge.hdr(frames, exposures: exposures(files), context: context)
        case .panorama: merged = try PhotoMerge.panorama(frames, context: context)
        case .focus: merged = try PhotoMerge.focusStack(frames, context: context)
        }
        let first = URL(fileURLWithPath: files[files.count / 2])
        let properties = CGImageSourceCreateWithURL(first as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        // Beside the photos; where that can't be written (a card), in Pictures › Pluck Merges.
        var folder = first.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck Merges", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let base = first.deletingPathExtension().lastPathComponent + "-" + kind.suffix
        var url = folder.appendingPathComponent(base + ".dng"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base)-\(n).dng"); n += 1 }
        try PhotoDNG.write(merged, to: url, context: context, source: properties)
        return url
    }

    /// Each photo's exposure in stops against the middle one, from its shutter, ISO and aperture (nil when any is missing:
    /// the merge then works it out from the pictures).
    nonisolated static func exposures(_ files: [String]) -> [Double]? {
        let values: [Double?] = files.map { file in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
                  let time = exif[kCGImagePropertyExifExposureTime as String] as? Double, time > 0 else { return nil }
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first ?? 100
            let f = exif[kCGImagePropertyExifFNumber as String] as? Double ?? 8
            return log2(time * iso / 100 / (f * f))
        }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let stops = values.compactMap { $0 }, middle = stops[stops.count / 2]
        return stops.map { $0 - middle }
    }

    enum MergeFlowError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "\(name) couldn’t be read.")
            }
        }
    }
}

extension PhotoDNG {
    nonisolated(unsafe) private static var merges: [String: Bool] = [:]
    nonisolated private static let mergeLock = NSLock()

    /// Whether this file is a merge Pluck wrote (its DNG camera model says so), kept per file.
    nonisolated static func isMerge(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng" else { return false }
        if let known = mergeLock.withLock({ merges[url.path] }) { return known }
        let model = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            .flatMap { $0[kCGImagePropertyDNGDictionary as String] as? [String: Any] }?[kCGImagePropertyDNGUniqueCameraModel as String] as? String
        let merge = model == "Pluck Merge"
        mergeLock.withLock { merges[url.path] = merge }
        return merge
    }
}

/// The merge's progress (or what went wrong), small in the title row.
struct PhotoMergeStatus: View {
    @State private var merger = PhotoMerger.shared

    var body: some View {
        if let kind = merger.working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Merging \(kind.title)…")
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Design.Studio.raised, in: .capsule)
        } else if let problem = merger.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.bad)
                Text(problem).lineLimit(1)
                Button { merger.dismissProblem() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Design.Studio.raised, in: .capsule)
        }
    }
}
