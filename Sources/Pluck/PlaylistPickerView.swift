import SwiftUI

/// Choose which videos of a playlist to download: one, several or all.
struct PlaylistPickerView: View {
    @Environment(DownloadManager.self) private var manager
    @Bindable var pick: PlaylistPick

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            content
            Divider()
            footer
                .padding(16)
        }
        // Fits inside the main window at its default size.
        .frame(width: 540, height: 440)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: pick.entries.first?.spotify != nil ? "music.note.list" : "list.and.film")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.phase == .loading ? "Reading playlist…" : pick.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        switch pick.phase {
        case .loading: return "Looking up the videos in this link."
        case .failed: return "Couldn’t read this playlist."
        case .ready:
            var parts = [pick.entries.count == 1 ? "1 item" : "\(pick.entries.count) items"]
            if let owner = pick.owner { parts.append(owner) }
            if pick.hiddenCount > 0 { parts.append("\(pick.hiddenCount) unavailable hidden") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        switch pick.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn’t Read Playlist", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
                .frame(maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                HStack {
                    Toggle(isOn: Binding(get: { pick.allSelected },
                                         set: { $0 ? pick.selectAll() : pick.selectNone() })) {
                        Text("Select All")
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("\(pick.selected.count) of \(pick.entries.count) selected")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(pick.entries.enumerated()), id: \.element.id) { index, entry in
                                PlaylistEntryRow(entry: entry, number: index + 1,
                                                 isSelected: pick.selected.contains(entry.id)) {
                                    pick.toggle(entry)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        // A video link inside a playlist: show that video.
                        if pick.selected.count == 1, let only = pick.selected.first {
                            proxy.scrollTo(only, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if pick.entries.first?.spotify != nil {
                // Spotify always downloads audio, in the audio format from Settings.
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
            Button("Cancel", role: .cancel) { manager.cancelPick(pick) }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Button(downloadTitle) { manager.confirm(pick) }
                .controlSize(.large)
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(pick.phase != .ready || pick.selected.isEmpty)
        }
    }

    private var downloadTitle: String {
        switch pick.selected.count {
        case 0: "Download"
        case 1: "Download 1 Item"
        case pick.entries.count where pick.entries.count > 1: "Download All \(pick.entries.count)"
        default: "Download \(pick.selected.count) Items"
        }
    }
}

private struct PlaylistEntryRow: View {
    let entry: PlaylistEntry
    let number: Int
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
            AsyncImage(url: entry.thumbnail) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: entry.spotify != nil ? "music.note" : "play.rectangle")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 41)
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let duration = entry.duration {
                Text(Format.duration(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.fill.quaternary))
                .opacity(isSelected || hovering ? 1 : 0)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.title, entry.subtitle, entry.duration.map(Format.duration)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
    }
}
