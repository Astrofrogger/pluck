import SwiftUI

/// The panel behind the menu bar icon: paste a link, pick a format, watch progress.
struct MenuBarView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @State private var urlText = ""
    @FocusState private var focused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        if Spotify.parse(trimmed) != nil { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private var recent: [DownloadItem] { Array(manager.items.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Paste a link", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!isValid)
                .help("Download")
            }

            HStack {
                FormatMenu()
                    .controlSize(.small)
                Spacer()
                if let link = Clipboard.videoURL(), trimmed.isEmpty {
                    Button("Paste & Download") { manager.add(link) }
                        .controlSize(.small)
                        .help(link)
                }
            }

            Divider()

            if recent.isEmpty {
                Text("No downloads yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent) { MenuBarRow(item: $0) }
                }
                if manager.items.count > recent.count {
                    Text("\(manager.items.count - recent.count) more in Pluck")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Open Pluck") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit Pluck")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func submit() {
        guard isValid else { return }
        manager.add(trimmed)
        urlText = ""
    }
}

private struct MenuBarRow: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.options.isAudio ? "waveform" : "film")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer(minLength: 0)
            if item.state == .finished, let file = item.fileURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else if item.isActive {
                Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading:
            ProgressView(value: item.progress).controlSize(.small)
        case .processing:
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        case .queued:
            caption("Waiting…")
        case .starting:
            caption(item.phase ?? "Starting…")
        case .finished:
            caption("Done").foregroundStyle(.green)
        case .failed:
            caption(item.errorMessage ?? "Failed").foregroundStyle(.red)
        case .cancelled:
            caption("Cancelled")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// The menu bar icon fills in while something is downloading.
struct MenuBarIcon: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        Image(systemName: manager.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
    }
}
