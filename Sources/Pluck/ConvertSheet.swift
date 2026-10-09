import SwiftUI

/// Shown when videos or songs from this Mac are dropped on the window (or chosen in File →
/// Convert Files…): pick what to turn them into, optionally for just part of the file.
struct ConvertSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AIStudio.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.audioFormat) private var audioFormat: AudioFormat = .m4a
    @AppStorage("compressPercent") private var percent = 50
    @AppStorage("gifWidth") private var gifWidth = 480
    /// nil: Automatic, 0: Original, otherwise a height.
    @State private var resolution: Int?
    @State private var onlyPart = false
    @State private var partStart = ""
    @State private var partEnd = ""
    @State private var details: [URL: (size: Int64, info: Converting.MediaInfo?)] = [:]
    let files: [URL]

    private var hasVideo: Bool { files.contains(where: Converting.isVideo) }

    private var heading: String {
        files.count == 1
            ? String(localized: "Convert “\(files[0].lastPathComponent)”")
            : String(localized: "Convert \(files.count) Files")
    }

    /// The part to convert, or nil for the whole file.
    private var clip: ClipRange? { onlyPart ? ClipRange.from(start: partStart, end: partEnd) : nil }
    private var partIsInvalid: Bool { onlyPart && clip == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if LocalAI.canTranscribe || Stems.isSupported || AudioCleanup.isSupported || Enhance.isSupported {
                        aiSection
                            .padding(.bottom, 6)
                    }
                    partRow
                        .padding(.bottom, 6)
                    presetButton(.audio)
                    presetButton(.mp4)
                    presetButton(.trim, enabled: clip != nil)
                    gifCard
                    compressCard
                }
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Audio format", selection: $audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("Used by Extract Audio")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await loadDetails() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: files.first?.path ?? ""))
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if files.count > 1 {
                    Text(files.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let file = files.first, let duration = details[file]?.info?.duration {
                    Text(Format.duration(duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Local AI

    private enum AIAction {
        case shorts, subtitles, summarize, chapters, stems, tighten, cleanup, enhance, background, blur
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local AI", systemImage: "sparkles")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                aiButton(.shorts, "Make Shorts…", "rectangle.portrait.on.rectangle.portrait.angled",
                         enabled: LocalAI.canTranscribe && files.count == 1 && hasVideo)
                aiButton(.subtitles, "Subtitles & Transcript…", "captions.bubble", enabled: LocalAI.canTranscribe)
                aiButton(.summarize, "Summarize", "text.badge.star", enabled: LocalAI.canSummarize)
                aiButton(.chapters, "Add Chapters", "list.number", enabled: LocalAI.canSummarize)
                aiButton(.tighten, "Remove Silences & Fillers…", "scissors", enabled: true)
                aiButton(.enhance, "Upscale & Smooth…", "sparkles.tv", enabled: Enhance.isSupported && files.count == 1 && hasVideo)
                aiButton(.background, "New Background…", "person.and.background.dotted", enabled: files.count == 1 && hasVideo)
                aiButton(.blur, "Privacy Blur…", "eye.slash", enabled: files.count == 1 && hasVideo)
                aiButton(.cleanup, "Clean Up Audio…", "waveform", enabled: AudioCleanup.isSupported)
                aiButton(.stems, "Separate Stems", "slider.vertical.3", enabled: Stems.isSupported)
            }
            Text(files.count > 1
                 ? "Works on your files in place, on this Mac. Shorts, upscaling, backgrounds and blurring take one file at a time."
                 : "Works on your file in place, on this Mac. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.purple.opacity(0.08)))
    }

    private func aiButton(_ action: AIAction, _ title: LocalizedStringKey, _ symbol: String, enabled: Bool) -> some View {
        Button { run(action) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(ConvertCardStyle())
        .disabled(!enabled)
    }

    /// Lists the files (as local files, not copies) and starts the AI action on them.
    private func run(_ action: AIAction) {
        let items = manager.addLocalFiles(files.filter(Converting.isMedia))
        let open: (PlayerTarget) -> Void = { openWindow(value: $0) }
        dismiss()
        switch action {
        case .shorts, .subtitles, .tighten, .cleanup, .enhance, .background, .blur:
            guard let item = items.first else { return }
            // After this sheet has closed, so the next one can open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                switch action {
                case .shorts: ai.shortsItem = item
                case .tighten: ai.tightenBatch = AIStudio.Batch(items)
                case .cleanup: ai.cleanupBatch = AIStudio.Batch(items)
                case .enhance: ai.enhanceItem = item
                case .background: ai.backgroundItem = item
                case .blur: ai.blurItem = item
                default: ai.subtitleBatch = AIStudio.Batch(items)
                }
            }
        case .summarize, .chapters:
            let kind: AIStudio.LanguageAsk.Action = action == .summarize ? .summarize : .chapters
            if items.count == 1, let item = items.first {
                // May ask for the spoken language, after this sheet has closed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ai.start(kind, item, openPlayer: open) }
            } else {
                for item in items {
                    if kind == .summarize { ai.summarize(item) { _ in } } else { ai.addChapters(item) { _ in } }
                }
            }
        case .stems:
            for item in items { ai.separateStems(item) }
        }
    }

    // MARK: - Part of the file

    private var partRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Only part of the file", isOn: $onlyPart.animation(.snappy(duration: 0.2)))
            if onlyPart {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("From")
                    TextField("0:00", text: $partStart)
                        .frame(width: 70)
                        .accessibilityLabel("Clip start")
                    Text("to")
                    TextField("end", text: $partEnd)
                        .frame(width: 70)
                        .accessibilityLabel("Clip end")
                    Group {
                        if partIsInvalid {
                            Label("Use times like 1:30, with the end after the start", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        } else if let clip {
                            Text(clip.end == nil ? String(localized: "From \(Format.duration(clip.start)) to the end")
                                                 : String(localized: "\(Format.duration((clip.end ?? 0) - clip.start)) clip"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Times like 1:30 or 1:02:03").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                .textFieldStyle(.roundedBorder)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Presets

    private func presetButton(_ preset: Conversion.Preset, enabled: Bool = true) -> some View {
        Button {
            start(preset)
        } label: {
            HStack(spacing: 14) {
                presetText(preset)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(ConvertCardStyle())
        .disabled(!enabled || partIsInvalid || (preset.needsVideo && !hasVideo))
        .accessibilityElement(children: .combine)
    }

    private func presetText(_ preset: Conversion.Preset) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: preset.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.headline)
                Text(preset.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func start(_ preset: Conversion.Preset) {
        manager.convert(files, preset: preset,
                        percent: preset == .compress ? percent : nil,
                        resolution: preset == .compress ? resolution : nil,
                        clip: clip,
                        gifWidth: preset == .gif ? gifWidth : nil)
        dismiss()
    }

    private func card<Content: View>(_ preset: Conversion.Preset, button: LocalizedStringKey, enabled: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            presetText(preset)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.leading, 46)
            HStack {
                Spacer()
                Button(button) { start(preset) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled || partIsInvalid)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.tertiary).opacity(0.8))
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - GIF

    /// The length of what becomes a GIF: the part, or the longest file.
    private var gifLength: Double? {
        let longest = files.compactMap { details[$0]?.info?.duration }.max()
        guard let clip else { return longest }
        let end = clip.end ?? longest
        return end.map { $0 - clip.start }
    }

    private var gifCard: some View {
        card(.gif, button: "Make GIF", enabled: hasVideo) {
            Picker("Size", selection: $gifWidth) {
                Text("Small (320 px)").tag(320)
                Text("Medium (480 px)").tag(480)
                Text("Large (720 px)").tag(720)
            }
            .fixedSize()
            if let length = gifLength, length > 20 {
                Label("GIFs of \(Format.duration(length)) get very big. Pick a shorter part above.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Compress

    private var compressCard: some View {
        card(.compress, button: "Compress", enabled: details.count == files.count) {
            LabeledContent("Target size") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(percent) }, set: { percent = Int($0) }), in: 10...90, step: 5)
                        .frame(width: 200)
                        .accessibilityValue("\(percent)%")
                    Text("\(percent)%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if hasVideo {
                Picker("Resolution", selection: $resolution) {
                    Text("Automatic").tag(Int?.none)
                    Text(originalLabel).tag(Int?.some(0))
                    ForEach(Converting.resolutions(below: tallest), id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                }
                .fixedSize()
                .help("Automatic keeps the resolution unless the file gets so small that a lower one looks sharper")
            }
            estimate
        }
    }

    private var tallest: Int { files.compactMap { details[$0]?.info?.height }.max() ?? 0 }

    private var originalLabel: String {
        tallest > 0 ? String(localized: "Original (\(tallest)p)") : String(localized: "Original")
    }

    /// What each file becomes at the chosen size: the same numbers the encoder will aim for.
    /// With a part chosen, the "original" is that part's share of the file.
    private var plans: [(original: Int64, result: Int64, compression: Converting.Compression?)] {
        files.compactMap { file in
            guard let detail = details[file] else { return nil }
            guard var info = detail.info, let full = info.duration, full > 0 else {
                return (detail.size, detail.size * Int64(percent) / 100, nil)
            }
            var size = detail.size
            if let clip {
                let length = max(min(clip.end ?? full, full) - clip.start, 0.1)
                size = Int64(Double(size) * length / full)
                info.duration = length
            }
            let c = Converting.compression(info: info, sourceSize: size, percent: percent, resolution: resolution)
            let kbps = Double((c.videoKbps ?? 0) + c.audioKbps)
            return (size, Int64(kbps * 1000 / 8 * (info.duration ?? full) * 1.03), c)
        }
    }

    @ViewBuilder
    private var estimate: some View {
        if details.count < files.count {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            let plans = plans
            let original = plans.reduce(0) { $0 + $1.original }
            let result = min(plans.reduce(0) { $0 + $1.result }, original)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.bytes(original)) → about \(Format.bytes(result))")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("Saves \(Format.bytes(original - result))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if resolution == nil, let lowered = plans.compactMap({ $0.compression?.height }).max() {
                    Label("Lowered to \(lowered)p to stay sharp", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if plans.contains(where: { $0.compression?.isRough == true }) {
                    Label("At this size the quality drops noticeably", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .animation(.snappy, value: percent)
        }
    }

    private func loadDetails() async {
        for file in files {
            let size = DownloadManager.size(of: file) ?? 0
            let info = await manager.mediaInfo(for: file)
            details[file] = (size, info)
        }
    }
}

private struct ConvertCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.fill.tertiary)
                    .opacity(configuration.isPressed ? 1.6 : (hovering && isEnabled ? 1.2 : 0.8))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}
