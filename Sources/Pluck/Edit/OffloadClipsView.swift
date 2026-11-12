import SwiftUI

/// The clips of a finished card as pictures, each with its details in a popover. It shows once
/// the details are worked out (a minute or so after the card is done).
struct OffloadClipGrid: View {
    let job: OffloadJob
    @State private var center = OffloadCenter.shared
    @State private var open = false

    var body: some View {
        if let clips = center.details(for: job.id), !clips.isEmpty {
            OffloadFold(isOpen: $open, label: Text("\(clips.count) clips"), symbol: "film") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(clips, id: \.path) { clip in ClipTile(job: job, clip: clip) }
                }
            }
        } else {
            Color.clear.frame(height: 0).task { await center.loadDetails(job.id) }
        }
    }
}

/// One clip: its picture and name, and its details when clicked.
private struct ClipTile: View {
    let job: OffloadJob
    let clip: ClipDetails
    @State private var picture: CGImage?
    @State private var showing = false

    private var file: URL? {
        job.targets.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(job.destination(of: clip.path)) }
    }

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Rectangle().fill(Design.Studio.raised)
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").foregroundStyle(Design.Studio.textFaint)
                    }
                }
                .frame(width: 120, height: 68)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                Text((clip.path as NSString).lastPathComponent).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing) { ClipDetailsView(clip: clip) }
        .task {
            guard picture == nil, let file else { return }
            picture = await ClipPictures.shared.picture(for: file)
        }
    }
}

/// Pictures already made, so scrolling back doesn't make them again.
private final class ClipPictures: @unchecked Sendable {
    static let shared = ClipPictures()
    private let cache = NSCache<NSURL, CGImage>()

    func picture(for file: URL) async -> CGImage? {
        if let made = cache.object(forKey: file as NSURL) { return made }
        let made = await Task.detached(priority: .utility) { await OffloadClips.thumbnail(file, size: 320) }.value
        if let made { cache.setObject(made, forKey: file as NSURL) }
        return made
    }
}

/// What's known about a clip; whatever isn't known isn't shown.
private struct ClipDetailsView: View {
    let clip: ClipDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((clip.path as NSString).lastPathComponent).font(Design.Studio.sectionTitle).lineLimit(1).truncationMode(.middle)
            ForEach(lines, id: \.self) { Text($0).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
        }
        .padding(Design.Spacing.inset)
        .frame(minWidth: 200, alignment: .leading)
    }

    private var lines: [String] {
        func rate(_ fps: Double) -> String { fps.rounded() == fps ? "\(Int(fps))" : fps.formatted(.number.precision(.fractionLength(2))) }
        var picture: [String] = []
        if let width = clip.width, let height = clip.height { picture.append("\(width)×\(height)") }
        if let fps = clip.fps { picture.append("\(rate(fps)) fps") }
        if let codec = clip.codec { picture.append(codec) }
        var exposure: [String] = []
        if let iso = clip.iso { exposure.append("ISO \(Int(iso))") }
        if let shutter = clip.shutter, shutter > 0 { exposure.append(shutter < 1 ? "1/\(Int((1 / shutter).rounded()))" : "\(shutter.formatted())s") }
        if let kelvin = clip.whiteBalance { exposure.append("\(Int(kelvin)) K") }
        var seconds: String?
        if let duration = clip.duration {
            seconds = Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        }
        return [clip.camera, clip.lens, picture.isEmpty ? nil : picture.joined(separator: " · "),
                exposure.isEmpty ? nil : exposure.joined(separator: " · "), clip.lut, seconds].compactMap { $0 }
    }
}
