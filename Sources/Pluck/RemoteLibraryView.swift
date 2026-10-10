import AVKit
import SwiftUI

/// Another Mac's shared Library, in this Mac's Library window: browse, play, copy here, and
/// send that Mac a link to download.
struct RemoteLibraryView: View {
    let peer: NetworkLibraries.Peer
    let search: String
    @State private var libraries = NetworkLibraries.shared
    @State private var base: URL?
    @State private var library: NetworkLibraries.Library?
    @State private var needsCode = false
    @State private var code = ""
    @State private var problem: String?
    @State private var loading = true
    @State private var playing: NetworkLibraries.Item?
    @State private var copying: Set<String> = []
    @State private var link = ""
    @State private var sent: String?

    private var shown: [NetworkLibraries.Item] {
        let items = library?.items ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedStandardContains(query) || ($0.uploader?.localizedStandardContains(query) ?? false) }
    }

    var body: some View {
        Group {
            if needsCode {
                codeForm
            } else if let library {
                VStack(spacing: 0) {
                    if library.canDownload == true { sendBar }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 18) {
                            ForEach(shown) { item in card(item) }
                        }
                        .padding(Design.Spacing.window)
                    }
                    .overlay {
                        if shown.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "Nothing Here Yet" : "Nothing Found", systemImage: "books.vertical")
                        }
                    }
                }
            } else if loading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(peer.name, systemImage: "desktopcomputer")
                } description: {
                    Text(problem ?? "")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .task(id: peer) { await load() }
        .sheet(item: $playing) { item in
            if let base { RemotePlayer(item: item, base: base) }
        }
    }

    private var codeForm: some View {
        VStack(spacing: Design.Spacing.section) {
            Image(systemName: "desktopcomputer").font(Design.Typography.sheetSymbol).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(peer.name).font(Design.Typography.sheetTitle)
            Text("Type the access code shown in that Mac’s Library window, under Share on This Network.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            TextField("Access code", text: $code)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .onSubmit { Task { await load(code: code) } }
            if let problem { Text(problem).foregroundStyle(.red) }
            Button("Open") { Task { await load(code: code) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.filter(\.isNumber).count != 6)
        }
        .padding(Design.Spacing.sheet)
    }

    /// Links to download on that Mac (the team's download Mac).
    private var sendBar: some View {
        HStack(spacing: Design.Spacing.controls) {
            Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Paste a link to download on \(peer.name)", text: $link)
                .textFieldStyle(.plain)
                .onSubmit(sendLink)
            if let sent { Text(sent).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Button("Download There", action: sendLink)
                .disabled(Links.validated(link) == nil)
        }
        .font(Design.Typography.control)
        .barControl()
        .padding(.horizontal, Design.Spacing.window)
        .padding(.top, 12)
    }

    private func card(_ item: NetworkLibraries.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let thumb = item.thumb, let base, let url = URL(string: thumb, relativeTo: base) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    } else {
                        Image(systemName: item.kind == "audio" ? "music.note" : item.kind == "photo" ? "photo" : "film")
                            .font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .clipShape(.rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = item.duration, duration > 0 {
                        Text(Format.duration(duration))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: .rect(cornerRadius: Design.Radius.badge))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay {
                    if copying.contains(item.id) { ProgressView().controlSize(.small) }
                }
            Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
            Text([item.site ?? item.uploader, item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { playing = item }
        .contextMenu {
            Button("Play") { playing = item }
            Button("Copy to This Mac") { copy(item) }.disabled(copying.contains(item.id))
        }
        .help(item.title)
    }

    private func load(code typed: String? = nil) async {
        loading = true
        problem = nil
        do {
            let (url, library) = try await libraries.library(of: peer, code: typed)
            base = url
            self.library = library
            needsCode = false
        } catch NetworkLibraries.Failure.wrongCode {
            needsCode = true
            problem = typed == nil ? nil : NetworkLibraries.Failure.wrongCode.localizedDescription
        } catch {
            library = nil
            problem = error.localizedDescription
        }
        loading = false
    }

    private func sendLink() {
        guard let base, let valid = Links.validated(link) else { return }
        Task {
            do {
                try await libraries.send(link: valid, to: base)
                link = ""
                sent = String(localized: "Downloading on \(peer.name)")
            } catch {
                sent = error.localizedDescription
            }
        }
    }

    private func copy(_ item: NetworkLibraries.Item) {
        guard let base else { return }
        copying.insert(item.id)
        Task {
            defer { copying.remove(item.id) }
            do {
                let file = try await libraries.copy(item, from: base, manager: LibraryServer.shared.manager)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Plays a file from another Mac, streamed.
private struct RemotePlayer: View {
    let item: NetworkLibraries.Item
    let base: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                VideoPlayer(player: player).frame(minWidth: 640, minHeight: 360)
            }
            HStack {
                Text(item.title).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onAppear {
            let url = base.appendingPathComponent("file/\(item.id)")
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: NetworkLibraries.shared.cookies(for: base)])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}
