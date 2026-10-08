import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AppUpdater.self) private var appUpdater
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @State private var confirmUpdate = false
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @State private var urlText = ""
    @State private var lastAutofilled: String?
    @State private var isTargeted = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        if Spotify.parse(trimmed) != nil { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if appUpdater.showsBanner, let release = appUpdater.release {
                updateBanner(release)
            }
            if manager.ffmpegMissing {
                if toolsUpdater.isBusy || manager.toolsInstalling {
                    setupBanner
                } else {
                    ffmpegBanner
                }
            }
            inputBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

            if manager.items.isEmpty {
                emptyState
            } else {
                downloadList
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Pluck")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .overlay { if isTargeted { dropHighlight } }
        .dropDestination(for: URL.self) { urls, _ in
            let links = urls.filter { $0.scheme?.hasPrefix("http") == true }
            manager.add(links.map(\.absoluteString))
            return !links.isEmpty
        } isTargeted: { isTargeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            autofillFromClipboard()
        }
        .onAppear {
            autofillFromClipboard()
            fieldFocused = true
        }
    }

    private var subtitle: String {
        let active = manager.activeCount
        return active == 0 ? "" : "\(active) downloading"
    }

    // MARK: - Banners

    private func updateBanner(_ release: AppUpdater.Release) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pluck \(release.version) is available").font(.headline)
                Text("You have \(appUpdater.currentVersion).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if appUpdater.status == .installing {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            } else {
                Button("What’s New") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.borderless)
                Button("Later") { withAnimation { appUpdater.dismissedVersion = release.version } }
                    .buttonStyle(.glass)
                Button("Install & Relaunch") {
                    if manager.activeCount > 0 { confirmUpdate = true } else { install() }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .confirmationDialog("Downloads are still running", isPresented: $confirmUpdate) {
            Button("Install & Relaunch", role: .destructive, action: install)
        } message: {
            Text("Updating now quits Pluck and stops \(manager.activeCount) download(s).")
        }
    }

    private func install() {
        Task { await appUpdater.installAndRelaunch() }
    }

    private var setupBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Setting up yt-dlp and ffmpeg… Downloads will start as soon as they’re ready.")
                .font(.callout)
            Spacer()
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var ffmpegBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(UserDefaults.standard.bool(forKey: Prefs.autoUpdate)
                 ? "Couldn’t download ffmpeg, so merging video and converting audio will fail."
                 : "ffmpeg isn’t installed, so merging video and converting audio will fail.")
                .font(.callout)
            Spacer()
            if UserDefaults.standard.bool(forKey: Prefs.autoUpdate) {
                Button("Try Again") { Task { await toolsUpdater.check(force: true) } }
                    .buttonStyle(.glass)
                    .help(toolsUpdater.failureMessage ?? "")
            } else {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                }
                .buttonStyle(.glass)
                .help("brew install ffmpeg (needs Homebrew from brew.sh)")
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Input

    private var inputBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Paste a video, playlist or Spotify link", text: $urlText)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                    if !urlText.isEmpty {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)

                FormatMenu()
                    .controlSize(.large)
                    .buttonStyle(.glass)

                Button(action: submit) {
                    Image(systemName: "arrow.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
                .help("Download")
            }
        }
        .animation(.snappy(duration: 0.2), value: urlText.isEmpty)
    }

    private func submit() {
        guard isValid else { return }
        manager.add(trimmed)
        lastAutofilled = trimmed
        withAnimation(.snappy) { urlText = "" }
    }

    private func autofillFromClipboard() {
        guard urlText.isEmpty,
              let link = Clipboard.videoURL(),
              link != lastAutofilled,
              !manager.items.contains(where: { $0.url == link })
        else { return }
        lastAutofilled = link
        urlText = link
    }

    // MARK: - List

    private var downloadList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(manager.items) { item in
                    DownloadRow(item: item)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .animation(.smooth, value: manager.items.map(\.id))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Downloading", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Paste a link above, or drop one anywhere in this window.")
        } actions: {
            if let link = Clipboard.videoURL() {
                Button("Download from Clipboard") { manager.add(link) }
                    .buttonStyle(.glass)
                    .help(link)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: downloadPath))
            } label: {
                Label("Show Downloads Folder", systemImage: "folder")
            }
            .help("Open \((downloadPath as NSString).abbreviatingWithTildeInPath)")

            Button {
                withAnimation { manager.clearFinished() }
            } label: {
                Label("Clear Finished", systemImage: "checklist.checked")
            }
            .disabled(!manager.hasFinished)
            .help("Clear finished downloads")
        }
    }
}
