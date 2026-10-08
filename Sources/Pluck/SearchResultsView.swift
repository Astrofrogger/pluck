import SwiftUI

/// Results for words typed into the link field: download any of them with one click.
struct SearchResultsView: View {
    @Environment(DownloadManager.self) private var manager
    @Bindable var session: SearchSession

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            content
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 540, height: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Results for “\(session.query)”")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Picker("Search in", selection: Binding(get: { session.kind },
                                                   set: { manager.changeSearchKind($0) })) {
                ForEach(SearchSession.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("Search Didn’t Work", systemImage: "wifi.exclamationmark",
                                   description: Text("Check your internet connection and try again."))
                .frame(maxHeight: .infinity)
        case .ready where session.results.isEmpty:
            ContentUnavailableView.search(text: session.query)
                .frame(maxHeight: .infinity)
        case .ready:
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.results) { result in
                        SearchResultRow(result: result, isMusic: session.kind == .music,
                                        isAdded: session.added.contains(result.id),
                                        existing: manager.alreadyDownloaded(result.url, isAudio: isAudio)?.existingFile) {
                            manager.download(result, from: session)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private var isAudio: Bool { session.kind == .music || DownloadOptions.current.isAudio }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.kind == .music {
                Label("Saves as \(DownloadOptions.current.audioFormat.shortLabel)", systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Change the audio format in Settings → Format")
            } else {
                FormatMenu()
                    .controlSize(.large)
                    .glassButtonStyle()
                    .focusEffectDisabled()
            }
            Spacer()
            if !session.added.isEmpty {
                Text(session.added.count == 1 ? String(localized: "1 added")
                                              : String(localized: "\(session.added.count) added"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { manager.search = nil }
                .controlSize(.large)
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let isMusic: Bool
    let isAdded: Bool
    let existing: URL?
    let download: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnail) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: isMusic ? "music.note" : "play.rectangle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: isMusic ? 44 : 78, height: 44)
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let subtitle = result.subtitle { Text(subtitle) }
                    if let views = result.views {
                        Text("·")
                        Text(Searching.views(views))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            // Title, artist and views read as one item; the download button stays its own control.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let duration = result.duration {
                Text(Format.duration(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var action: some View {
        if isAdded {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 30)
                .accessibilityLabel("Added")
        } else if let existing {
            Button { NSWorkspace.shared.activateFileViewerSelecting([existing]) } label: {
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Already downloaded. Click to show it in Finder.")
        } else {
            Button(action: download) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download \(result.title)")
            .help(isMusic ? String(localized: "Download as audio") : String(localized: "Download"))
        }
    }
}
