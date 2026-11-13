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
        /// Super Resolution (PhotoUpscale): one photo at a time, at twice its width and height.
        case enlarge
        var id: String { rawValue }
        /// The merges (Super Resolution has its own menu item).
        static let merges: [Kind] = [.hdr, .panorama, .focus]
        var title: String {
            switch self {
            case .hdr: String(localized: "HDR")
            case .panorama: String(localized: "Panorama")
            case .focus: String(localized: "Focus Stack")
            case .enlarge: String(localized: "Super Resolution")
            }
        }
        /// What goes on the merged file's name.
        var suffix: String {
            switch self {
            case .hdr: "HDR"
            case .panorama: "Pano"
            case .focus: "Stack"
            case .enlarge: "Enhanced"
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

    /// Super Resolution for each of these photos (their files), one after the other, each beside its photo.
    func enlarge(_ keys: [String]) {
        guard working == nil else { return }
        var seen: Set<String> = []
        let files = keys.map(PhotoCatalog.file(of:)).filter { seen.insert($0).inserted }
        guard !files.isEmpty else { return }
        working = .enlarge
        problem = nil
        Task {
            for file in files {
                let albums = PhotoCatalog.shared.albums.filter { $0.paths.contains(file) }.map(\.id)
                do {
                    let url = try await Self.makeEnlarged(file)
                    for album in albums { PhotoCatalog.shared.add([url.path], to: album) }
                    made = url.path
                } catch {
                    problem = error.localizedDescription
                    break
                }
            }
            working = nil
        }
    }

    /// One photo enlarged and written (off the main thread).
    nonisolated static func makeEnlarged(_ file: String) async throws -> URL {
        let context = PhotoEngine.context
        guard let decoded = PhotoRender.decoded(file, maxSize: 16_384, record: PhotoRecord()) else {
            throw MergeFlowError.unreadable(URL(fileURLWithPath: file).lastPathComponent)
        }
        let big = try await PhotoUpscale.doubled(decoded, context: context)
        return try write(big, kind: .enlarge, beside: URL(fileURLWithPath: file), context: context)
    }

    /// Writes a made photo as a DNG beside `first` (or in Pictures › Pluck Merges where that can't be written).
    nonisolated static func write(_ image: CIImage, kind: Kind, beside first: URL, context: CIContext) throws -> URL {
        let properties = CGImageSourceCreateWithURL(first as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        var folder = first.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck Merges", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let base = first.deletingPathExtension().lastPathComponent + "-" + kind.suffix
        var url = folder.appendingPathComponent(base + ".dng"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base)-\(n).dng"); n += 1 }
        try PhotoDNG.write(image, to: url, context: context, source: properties)
        return url
    }

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
        case .enlarge: throw MergeFlowError.unreadable("")
        }
        // Beside the middle photo.
        return try write(merged, kind: kind, beside: URL(fileURLWithPath: files[files.count / 2]), context: context)
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
                Text(kind == .enlarge ? "Enlarging…" : "Merging \(kind.title)…")
            }
            .font(Design.Studio.hint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Design.Studio.raised, in: .capsule)
        } else if let problem = merger.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.bad)
                Text(problem).lineLimit(1)
                Button { merger.dismissProblem() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .font(Design.Studio.hint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Design.Studio.raised, in: .capsule)
        }
    }
}

/// Detail › Super Resolution: the photo at twice its width and height, as a new DNG beside it (the original isn't changed).
struct PhotoSuperResolutionRow: View {
    let path: String
    @State private var merger = PhotoMerger.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Super Resolution").font(Design.Studio.sectionTitle).padding(.leading, Design.Sidebar.rowPadding)
            Text("Twice the width and height, by Apple's on-device model: a new DNG beside the photo")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Design.Sidebar.rowPadding)
            HStack(spacing: 8) {
                Button("Enlarge 2×") { merger.enlarge([path]) }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(merger.working != nil)
                if merger.working == .enlarge {
                    ProgressView().controlSize(.small)
                    Text("Enlarging…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .padding(.horizontal, Design.Sidebar.rowPadding)
        }
        .padding(.top, 6)
    }
}
