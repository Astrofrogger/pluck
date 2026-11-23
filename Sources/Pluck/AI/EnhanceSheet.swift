import SwiftUI

/// Upscale & Smooth: a bigger, sharper picture and/or smoother motion, with a time estimate.
struct EnhanceSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    private var item: DownloadItem { items[0] }
    @AppStorage("enhanceUpscale") private var upscale: Enhance.Upscale = .hd
    @AppStorage("enhanceMotion") private var motion: Enhance.Motion = .off
    @State private var info: Converting.MediaInfo?
    /// Every video's, for the time estimate.
    @State private var infos: [Converting.MediaInfo] = []

    /// The picture's short side (its height when upright).
    private var sourceHeight: Int? {
        guard let w = info?.width, let h = info?.height else { return nil }
        return min(w, h)
    }

    private var options: Enhance.Options { Enhance.Options(upscale: upscale, motion: motion) }

    /// Every selected video's short side.
    private var heights: [Int] { infos.compactMap { info in info.width.flatMap { w in info.height.map { min(w, $0) } } } }
    /// Any video smaller than the chosen size.
    private var upscales: Bool { upscale.height.map { target in heights.contains { $0 < target } || (heights.isEmpty && target > (sourceHeight ?? 0)) } ?? false }

    /// What the size does to the selection.
    private var sizeDetail: String? {
        guard items.count > 1 else {
            return sourceHeight.map { h in upscale.height.map { $0 <= h } ?? false
                ? String(localized: "This video is already \(String(h))p.")
                : String(localized: "Now \(String(h))p. Local AI adds real detail, not just bigger pixels.") }
        }
        // (Plain digits: "1080p", never "1.080p".)
        guard let first = heights.first else { return nil }
        guard heights.allSatisfy({ $0 == first }) else { return String(localized: "Mixed sizes") }
        guard let target = upscale.height, target > first else { return String(localized: "Already \(String(first))p.") }
        return String(localized: "\(String(first))p to \(String(target))p")
    }
    private var hasWork: Bool { upscales || motion != .off }

    private var estimate: String? {
        guard hasWork, !infos.isEmpty else { return nil }
        let seconds = infos.reduce(0.0) { total, info in
            guard let w = info.width, let h = info.height, let duration = info.duration else { return total }
            return total + Enhance.estimatedSeconds(width: w, height: h, duration: duration, frameRate: info.fps ?? 30, options: options)
        }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 90 ? String(localized: "Takes about \(minutes) min on this Mac.")
                            : String(localized: "Takes about \(minutes / 60) h on this Mac. Try part of the video first.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "sparkles.tv", title: Text("Upscale & Smooth"), subtitle: Text(AIStudio.Batch(items).title))

            Form {
                Picker(selection: $upscale) {
                    ForEach(Enhance.Upscale.allCases) { size in
                        Text(size.label).tag(size)
                            .disabled(!Enhance.canUpscale && size != .off)
                    }
                } label: {
                    Text("Size")
                    if let sizeDetail { Text(sizeDetail) }
                }
                Picker(selection: $motion) {
                    ForEach(Enhance.Motion.allCases) { Text($0.label).tag($0).disabled(!Enhance.canSmooth && $0 != .off) }
                } label: {
                    Text("Motion")
                    Text(motionDetail)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Runs entirely on this Mac with local AI (Apple’s video processing). Pluck saves an enhanced copy next to the original; the original isn’t changed.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                if let estimate {
                    Label(estimate, systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enhance") {
                    for item in items { studio.enhance(item, options: options) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasWork)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 500)
        .task {
            guard let ffprobe = studio.toolPath("ffprobe") else { return }
            for item in items {
                guard let file = item.existingFile, let found = await Converting.probe(file, ffprobe: ffprobe) else { continue }
                if item === items[0] { info = found }
                infos.append(found)
            }
        }
    }

    private var motionDetail: String {
        let fps = Int((info?.fps ?? 30).rounded())
        return switch motion {
        case .off: String(localized: "Keeps the original frames.")
        case .smooth: String(localized: "\(fps) → \(fps * 2) frames per second, for smoother movement.")
        case .slow2, .slow4: String(localized: "New frames in between make smooth slow motion. Slow motion has no sound.")
        }
    }
}

extension EnhanceSheet {
    init(item: DownloadItem) { self.init(items: [item]) }
}
