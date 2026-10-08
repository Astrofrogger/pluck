import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver reads title, format, uploader and status as one item.
            .accessibilityElement(children: .combine)

            actionButton
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(hovering ? 1 : 0.6)
        }
        .contentShape(.rect(cornerRadius: 16))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { open() }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { open() }
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnail) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: item.options.isAudio ? "music.note" : "play.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 128, height: 72)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration = item.duration {
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

    private var details: some View {
        HStack(spacing: 6) {
            if item.spotify != nil || Spotify.isSpotify(item.url) {
                Text("Spotify")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: .capsule)
                    .help("Matched on YouTube Music and tagged with Spotify’s metadata")
            }
            Label(item.options.longLabel, systemImage: item.options.symbol)
                .labelStyle(.titleAndIcon)
            if let uploader = item.uploader {
                Text("·")
                Text(uploader)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued:
            Label("Waiting…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(item.phase ?? "Fetching info…")
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
                Text(item.phase ?? "Finishing up…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finished:
            Label(item.fileSize.map { "Done · \(Format.bytes($0))" } ?? "Done", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)

        case .failed:
            Label(item.errorMessage ?? "Download failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(item.errorMessage ?? "")

        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadStats: String {
        var parts = ["\(Int(item.progress * 100))%"]
        if let speed = item.speed { parts.append("\(Format.bytes(Int64(speed)))/s") }
        if let eta = item.eta, eta > 0 { parts.append("\(Format.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButton: some View {
        Group {
            switch item.state {
            case .queued, .starting, .downloading, .processing:
                Button { manager.cancel(item) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel Download")
                    .help("Cancel")
            case .finished:
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

    @ViewBuilder
    private var menu: some View {
        if item.state == .finished {
            Button("Open", action: open)
            Button("Show in Finder", action: reveal)
            Divider()
        }
        if item.isActive {
            Button("Cancel") { manager.cancel(item) }
        } else if item.state != .finished {
            Button("Try Again") { manager.retry(item) }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        }
        Button("Open Link in Browser") {
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            withAnimation { manager.remove(item) }
        }
    }

    private func open() {
        guard let file = item.fileURL else { return }
        NSWorkspace.shared.open(file)
    }

    private func reveal() {
        guard let file = item.fileURL else { return }
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
