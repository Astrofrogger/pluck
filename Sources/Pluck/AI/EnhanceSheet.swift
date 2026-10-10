import SwiftUI

/// Upscale & Smooth: a bigger, sharper picture and/or smoother motion, with a time estimate.
struct EnhanceSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("enhanceUpscale") private var upscale: Enhance.Upscale = .hd
    @AppStorage("enhanceMotion") private var motion: Enhance.Motion = .off
    @State private var info: Converting.MediaInfo?

    /// The picture's short side (its height when upright).
    private var sourceHeight: Int? {
        guard let w = info?.width, let h = info?.height else { return nil }
        return min(w, h)
    }

    private var options: Enhance.Options { Enhance.Options(upscale: upscale, motion: motion) }

    private var upscales: Bool { upscale.height.map { $0 > (sourceHeight ?? 0) } ?? false }
    private var hasWork: Bool { upscales || motion != .off }

    private var estimate: String? {
        guard hasWork, let w = info?.width, let h = info?.height, let duration = info?.duration else { return nil }
        let seconds = Enhance.estimatedSeconds(width: w, height: h, duration: duration, frameRate: info?.fps ?? 30, options: options)
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 90 ? String(localized: "Takes about \(minutes) min on this Mac.")
                            : String(localized: "Takes about \(minutes / 60) h on this Mac. Try part of the video first.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "sparkles.tv", title: Text("Upscale & Smooth"), subtitle: Text(item.title))

            Form {
                Picker(selection: $upscale) {
                    ForEach(Enhance.Upscale.allCases) { size in
                        Text(size.label).tag(size)
                            .disabled(!Enhance.canUpscale && size != .off)
                    }
                } label: {
                    Text("Size")
                    if let h = sourceHeight {
                        Text(upscale.height.map { $0 <= h } ?? false
                             ? String(localized: "This video is already \(h)p.")
                             : String(localized: "Now \(h)p. Local AI adds real detail, not just bigger pixels."))
                    }
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
                    studio.enhance(item, options: options)
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
            guard let file = item.existingFile, let ffprobe = studio.toolPath("ffprobe") else { return }
            info = await Converting.probe(file, ffprobe: ffprobe)
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
