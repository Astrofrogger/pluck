import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AIStudio.self) private var ai
    @Environment(\.openWindow) private var openWindow
    let item: DownloadItem
    var isSelected = false
    /// The other selected rows (with this one), when several are selected.
    var batch: [DownloadItem] = []
    var onSelect: () -> Void = {}
    var onQuickLook: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                details
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                status

                if let task = item.aiStatus {
                    aiProgress(task)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver reads title, format, uploader and status as one item.
            .accessibilityElement(children: .combine)

            actionButton
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.fill.quaternary))
                .opacity(isSelected || hovering ? 1 : 0.6)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(.rect(cornerRadius: 16))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .onTapGesture(count: 2) { open() }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        // Drag a finished download straight into Finder, Mail, an editor…
        .onDrag {
            guard let file = item.existingFile else { return NSItemProvider() }
            return NSItemProvider(contentsOf: file) ?? NSItemProvider()
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Open") { open() }
        .accessibilityAction(named: "Quick Look") { onQuickLook() }
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnail) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: item.conversion != nil ? "arrow.triangle.2.circlepath" : (item.options.isAudio ? "music.note" : "play.rectangle"))
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 128, height: 72)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration = displayedDuration {
                Text(Format.duration(duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    /// The clip's own length for clips, otherwise the video's.
    private var displayedDuration: Double? {
        guard let clip = item.clip else { return item.duration }
        let end = min(clip.end ?? item.duration ?? .infinity, item.duration ?? .infinity)
        return end.isFinite ? max(end - clip.start, 0) : nil
    }

    private var details: some View {
        HStack(spacing: 6) {
            if let service = item.spotify?.source ?? MusicLinks.service(of: item.url) {
                Text(service.name)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(service == .spotify ? Color(red: 0.11, green: 0.73, blue: 0.33)
                                                    : Color(red: 0.98, green: 0.14, blue: 0.24), in: .capsule)
                    .help(service == .spotify ? String(localized: "Matched on YouTube Music and tagged with Spotify’s metadata")
                                              : String(localized: "Matched on YouTube Music and tagged with Apple Music’s metadata and cover"))
            }
            if item.isLocalFile {
                Label("On this Mac", systemImage: "internaldrive")
                    .labelStyle(.titleAndIcon)
            } else if let conversion = item.conversion {
                Label(conversion.label(options: item.options), systemImage: conversion.preset.symbol)
                    .labelStyle(.titleAndIcon)
                Text("·")
                Text(URL(fileURLWithPath: conversion.source).lastPathComponent)
            } else {
                Label(item.options.longLabel, systemImage: item.options.symbol)
                    .labelStyle(.titleAndIcon)
            }
            if let clip = item.clip {
                Text("·")
                Label(clip.label, systemImage: "scissors")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Clip \(clip.label)")
            }
            if let uploader = item.uploader, item.conversion == nil, !item.isLocalFile {
                Text("·")
                Text(uploader)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued where item.phase != nil:
            Label(item.phase ?? "", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)

        case .queued:
            Label("Waiting…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(item.phase ?? String(localized: "Fetching info…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.progress)
                    .accessibilityLabel("Download progress")
                    .progressViewStyle(.linear)
                Text(downloadStats)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

        case .processing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                Text(item.phase ?? String(localized: "Finishing up…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finished where item.fileMissing:
            Label("File moved or deleted", systemImage: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .finished:
            HStack(spacing: 6) {
                Label(item.fileSize.map { String(localized: "Done · \(Format.bytes($0))") } ?? String(localized: "Done"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                if let count = item.chapterCount {
                    Label("\(count) chapters", systemImage: "list.number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Split into one file per chapter, in a folder")
                }
                if item.isLossless {
                    Text("Lossless")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(.secondary)
                        .help("The source was lossless and the file wasn’t converted to a lossy format")
                }
                if item.addedToMusic {
                    Label("Music", systemImage: "music.note.house")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Added to Apple Music")
                }
                if item.hasLyrics {
                    Label("Lyrics", systemImage: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Lyrics from LRCLIB are in the file")
                }
                if let source = item.sourceAudio {
                    // The quality that was actually downloaded, so a FLAC made from a 136 kbps
                    // stream doesn't pass for lossless.
                    Text("· \(source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Downloaded audio quality, before conversion")
                }
            }

        case .failed:
            Label(item.errorMessage ?? String(localized: "Download failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(item.errorMessage ?? "")

        case .paused:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .accessibilityLabel("Download progress")
                Label(String(localized: "Paused · \(Int(item.progress * 100))%"), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadStats: String {
        var parts = ["\(Int(item.progress * 100))%"]
        if item.conversion != nil { parts.insert(String(localized: "Converting"), at: 0) }
        if let speed = item.speed { parts.append("\(Format.bytes(Int64(speed)))/s") }
        if let eta = item.eta, eta > 0 { parts.append(String(localized: "\(Format.duration(eta)) left")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButton: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .downloading where item.conversion != nil, .queued where item.conversion != nil:
                cancelButton
            case .downloading, .queued:
                Button { manager.pause(item) } label: { Image(systemName: "pause.fill") }
                    .accessibilityLabel("Pause Download")
                    .help("Pause")
                cancelButton
            case .paused:
                Button { manager.resume(item) } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Resume Download")
                    .help("Resume")
                cancelButton
            case .starting, .processing:
                cancelButton
            case .finished where item.fileMissing && item.isLocalFile:
                EmptyView()
            case .finished where item.fileMissing:
                Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Download Again")
                    .help("Download Again")
            case .finished:
                if isAIEligible {
                    aiMenu
                }
                Button { reveal() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Show in Finder")
                    .help("Show in Finder")
            case .failed, .cancelled:
                Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Try Again")
                    .help("Try Again")
            }
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var cancelButton: some View {
        Button { manager.cancel(item) } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Cancel Download")
            .help("Cancel")
    }

    @ViewBuilder
    private var menu: some View {
        if item.existingFile != nil {
            Button("Open", action: open)
            Button("Quick Look", action: onQuickLook)
            Button("Show in Finder", action: reveal)
            if Resolve.isInstalled {
                Button(targets.count > 1 ? String(localized: "Send \(targets.count) Files to DaVinci Resolve")
                                         : String(localized: "Send to DaVinci Resolve")) {
                    Resolve.sendAndShow(targets.compactMap(\.existingFile))
                }
            }
            Divider()
        }
        if isAIEligible {
            aiActions
            Divider()
        }
        if item.conversion == nil, item.state == .downloading || item.state == .queued {
            Button("Pause") { manager.pause(item) }
        } else if item.state == .paused {
            Button("Resume") { manager.resume(item) }
        }
        if item.isActive || item.state == .paused {
            Button("Cancel") { manager.cancel(item) }
        } else if item.fileMissing, !item.isLocalFile {
            Button("Download Again") { manager.retry(item) }
        } else if item.state != .finished {
            Button("Try Again") { manager.retry(item) }
        }
        if item.isLocalFile {
            EmptyView()
        } else if let conversion = item.conversion {
            Button("Show Original in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: conversion.source)])
            }
        } else {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Button("Open Link in Browser") {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            }
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            withAnimation { manager.remove(item) }
        }
    }

    // MARK: - Local AI

    /// What the multi-file actions run on: every selected video or song, when this row is part of
    /// a bigger selection; otherwise just this one.
    private var targets: [DownloadItem] {
        guard batch.count > 1, batch.contains(where: { $0.id == item.id }) else { return [item] }
        let usable = batch.filter { $0.aiStatus == nil && ($0.existingFile.map(Converting.isMedia) ?? false) }
        return usable.isEmpty ? [item] : usable
    }

    /// A finished video or song (not a folder or photo) that local AI can work with.
    private var isAIEligible: Bool {
        guard let file = item.existingFile, !file.hasDirectoryPath else { return false }
        return Converting.isMedia(file)
    }

    private var aiMenu: some View {
        Menu {
            aiActions
        } label: {
            Image(systemName: "sparkles")
        }
        .menuIndicator(.hidden)
        .disabled(item.aiStatus != nil)
        .accessibilityLabel("Local AI")
        .help("Local AI: subtitles, summaries, shorts and more, made on this Mac")
    }

    @ViewBuilder
    private var aiActions: some View {
        Section("Local AI") {
            if targets.count > 1 {
                Text("Subtitles, silences and audio clean-up: all \(targets.count) selected")
            }
            Button("Subtitles & Transcript…", systemImage: "captions.bubble") { ai.subtitleBatch = AIStudio.Batch(targets) }
                .disabled(!LocalAI.canTranscribe || item.aiStatus != nil)
            Button("Summarize", systemImage: "text.badge.star") {
                ai.start(.summarize, item) { openWindow(value: $0) }
            }
            .disabled(!LocalAI.canSummarize || item.aiStatus != nil)
            Button("Add Chapters", systemImage: "list.number") {
                ai.start(.chapters, item) { openWindow(value: $0) }
            }
            .disabled(!LocalAI.canSummarize || item.aiStatus != nil)
            Button("Make Shorts…", systemImage: "rectangle.portrait.on.rectangle.portrait.angled") { ai.shortsItem = item }
                .disabled(!LocalAI.canTranscribe || item.aiStatus != nil || !(item.existingFile.map(Converting.isVideo) ?? false))
            Button("Remove Silences & Fillers…", systemImage: "scissors") { ai.tightenBatch = AIStudio.Batch(targets) }
                .disabled(item.aiStatus != nil)
            Button("Upscale & Smooth…", systemImage: "sparkles.tv") { ai.enhanceItem = item }
                .disabled(!Enhance.isSupported || item.aiStatus != nil || !(item.existingFile.map(Converting.isVideo) ?? false))
            Button("New Background…", systemImage: "person.and.background.dotted") { ai.backgroundItem = item }
                .disabled(item.aiStatus != nil || !(item.existingFile.map(Converting.isVideo) ?? false))
            Button("Privacy Blur…", systemImage: "eye.slash") { ai.blurItem = item }
                .disabled(item.aiStatus != nil || !(item.existingFile.map(Converting.isVideo) ?? false))
            Button("Clean Up Audio…", systemImage: "waveform") { ai.cleanupBatch = AIStudio.Batch(targets) }
                .disabled(!AudioCleanup.isSupported || item.aiStatus != nil)
            Button("Separate Stems", systemImage: "slider.vertical.3") { ai.separateStems(item) }
                .disabled(!Stems.isSupported || item.aiStatus != nil)
            Button("Open in Pluck Player", systemImage: "play.rectangle.on.rectangle") { openPlayer() }
        }
        if LocalAI.canTranscribe, let reason = LocalAI.summarizeUnavailableReason {
            Text(reason)
        }
        if !LocalAI.canTranscribe {
            Text("Local AI needs macOS 26 or later.")
        }
    }

    private func openPlayer(at start: Double? = nil) {
        guard let file = item.existingFile else { return }
        openWindow(value: PlayerTarget(filePath: file.path, transcriptID: item.transcriptID, start: start))
    }

    private func aiProgress(_ task: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = item.aiProgress {
                ProgressView(value: progress).progressViewStyle(.linear).tint(.purple)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.purple)
            }
            Label(item.aiProgress.map { "\(task) \(Int($0 * 100))%" } ?? task, systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func open() {
        guard let file = item.existingFile else { return }
        NSWorkspace.shared.open(file)
    }

    private func reveal() {
        guard let file = item.existingFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
