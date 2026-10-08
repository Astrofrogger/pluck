import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openPluckSettings) private var openSettings
    @Environment(AppUpdater.self) private var appUpdater
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @State private var confirmUpdate = false
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @State private var urlText = ""
    @State private var selection: DownloadItem.ID?
    @State private var shownPickID: PlaylistPick.ID?
    @State private var clipping = false
    @State private var clipStart = ""
    @State private var clipEnd = ""
    @State private var previewURL: URL?
    @FocusState private var listFocused: Bool
    @State private var lastAutofilled: String?
    @State private var isTargeted = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        if Spotify.parse(trimmed) != nil { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// Words rather than a link: Return searches YouTube.
    private var isSearch: Bool { !trimmed.isEmpty && !isValid && !clipping }

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
                .padding(.bottom, clipping ? 10 : 16)

            if clipping {
                clipBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

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
            AppDelegate.openMainWindow = { openWindow(id: "main"); NSApp.activate() }
            if !AppDelegate.didHandleLaunchWindow {
                AppDelegate.didHandleLaunchWindow = true
                if AppDelegate.startsHidden, manager.pendingLink == nil {
                    dismissWindow(id: "main")
                    return
                }
            }
            if !takePendingLink() { autofillFromClipboard() }
            fieldFocused = true
        }
        .onChange(of: manager.pendingLink) { _ = takePendingLink() }
        .alert(duplicateTitle, isPresented: Binding(
            get: { manager.picks.isEmpty && !manager.duplicates.isEmpty },
            set: { shown in if !shown, let prompt = manager.duplicates.first { manager.resolve(prompt, with: .cancel) } }
        ), presenting: manager.duplicates.first) { prompt in
            Button("Show in Finder") { manager.resolve(prompt, with: .showInFinder) }
            Button("Download Again") { manager.resolve(prompt, with: .downloadAgain) }
            Button("Cancel", role: .cancel) { manager.resolve(prompt, with: .cancel) }
        } message: { prompt in
            Text("It’s saved as “\(prompt.existing.existingFile?.lastPathComponent ?? prompt.existing.title)”.")
        }
        .sheet(item: Binding(get: { manager.picks.isEmpty ? manager.search : nil },
                             set: { if $0 == nil { manager.search = nil } })) { session in
            SearchResultsView(session: session)
                .environment(manager)
        }
        .sheet(item: Binding(get: { manager.picks.first }, set: { newValue in
            // Closing the sheet cancels only the playlist that was on screen, never the next one.
            if newValue == nil, let shown = manager.picks.first(where: { $0.id == shownPickID }) {
                manager.cancelPick(shown)
            }
        })) { pick in
            PlaylistPickerView(pick: pick)
                .environment(manager)
                .onAppear { shownPickID = pick.id }
        }
    }

    private var subtitle: String {
        let active = manager.activeCount
        return active == 0 ? "" : String(localized: "\(active) downloading")
    }

    private var duplicateTitle: String {
        guard let prompt = manager.duplicates.first else { return "" }
        return String(localized: "“\(prompt.existing.title)” is already downloaded")
    }

    // MARK: - Banners

    private func updateBanner(_ release: AppUpdater.Release) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
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
                    .glassButtonStyle()
                Button("Install & Relaunch") {
                    if manager.activeCount > 0 { confirmUpdate = true } else { install() }
                }
                .glassProminentButtonStyle()
            }
        }
        .padding(12)
        .glassBackground(in: .rect(cornerRadius: 16))
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
        .glassBackground(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var ffmpegBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Warning")
            Text(UserDefaults.standard.bool(forKey: Prefs.autoUpdate)
                 ? "Couldn’t download ffmpeg, so merging video and converting audio will fail."
                 : "ffmpeg isn’t installed, so merging video and converting audio will fail.")
                .font(.callout)
            Spacer()
            if UserDefaults.standard.bool(forKey: Prefs.autoUpdate) {
                Button("Try Again") { Task { await toolsUpdater.check(force: true) } }
                    .glassButtonStyle()
                    .help(toolsUpdater.failureMessage ?? "")
            } else {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                }
                .glassButtonStyle()
                .help("brew install ffmpeg (needs Homebrew from brew.sh)")
            }
        }
        .padding(12)
        .glassBackground(in: .rect(cornerRadius: 16), tint: .orange.opacity(0.15))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Input

    private var inputBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Paste a link, or type to search YouTube", text: $urlText)
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
                        .accessibilityLabel("Clear Link")
                        .help("Clear")
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .glassBackground(in: .capsule, interactive: true)

                FormatMenu()
                    .controlSize(.large)
                    .glassButtonStyle()

                Button {
                    withAnimation(.snappy(duration: 0.25)) { clipping.toggle() }
                } label: {
                    Image(systemName: "scissors")
                        .font(.body.weight(.medium))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(clipping ? Color.accentColor : Color.primary)
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel(clipping ? "Download Whole Video" : "Download a Clip")
                .help(clipping ? "Download the whole video" : "Download only part of the video")

                Button(action: submit) {
                    Image(systemName: isSearch ? "magnifyingglass" : "arrow.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassProminentButtonStyle()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!(isValid || isSearch) || (clipping && clip == nil))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(isSearch ? String(localized: "Search") : String(localized: "Download"))
                .help(isSearch ? String(localized: "Search YouTube") : String(localized: "Download"))
            }
        }
        .animation(.snappy(duration: 0.2), value: urlText.isEmpty)
    }

    // MARK: - Clip

    /// The range typed in the clip row, or nil when it isn't valid (or not set).
    private var clip: ClipRange? { ClipRange.from(start: clipStart, end: clipEnd) }

    private var clipIsInvalid: Bool {
        (!clipStart.isEmpty || !clipEnd.isEmpty) && clip == nil
    }

    private var clipBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Clip from")
            TextField("0:00", text: $clipStart)
                .frame(width: 72)
                .accessibilityLabel("Clip start")
            Text("to")
            TextField("end", text: $clipEnd)
                .frame(width: 72)
                .accessibilityLabel("Clip end")
            Group {
                if clipIsInvalid {
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
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassBackground(in: .capsule)
        .onSubmit(submit)
    }

    private func submit() {
        if isSearch {
            manager.startSearch(trimmed)
            return
        }
        guard isValid else { return }
        if clipping {
            guard let clip else { NSSound.beep(); return }
            manager.add(trimmed, clip: clip)
            withAnimation(.snappy(duration: 0.25)) { clipping = false }
            clipStart = ""
            clipEnd = ""
        } else {
            manager.add(trimmed)
        }
        lastAutofilled = trimmed
        withAnimation(.snappy) { urlText = "" }
    }

    /// Fills in a link handed over by a pluck:// URL. It's never started automatically.
    private func takePendingLink() -> Bool {
        guard let link = manager.pendingLink else { return false }
        manager.pendingLink = nil
        urlText = link
        lastAutofilled = link
        fieldFocused = true
        return true
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
                    DownloadRow(item: item,
                                isSelected: selection == item.id,
                                onSelect: { select(item.id) },
                                onQuickLook: { quickLook(item) })
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
        .softTopScrollEdge()
        // Click a row to select it; Space opens Quick Look, ↑/↓ move the selection.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let item = selectedItem else { return .ignored }
            quickLook(item)
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .quickLookPreview($previewURL)
    }

    private var selectedItem: DownloadItem? {
        manager.items.first { $0.id == selection }
    }

    private func select(_ id: DownloadItem.ID) {
        selection = id
        fieldFocused = false
        listFocused = true
    }

    private func quickLook(_ item: DownloadItem) {
        select(item.id)
        guard let file = item.existingFile else { NSSound.beep(); return }
        previewURL = previewURL == file ? nil : file
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = manager.items.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        selection = ids[next]
        if previewURL != nil { previewURL = manager.items[next].existingFile }
        return .handled
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Downloading", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("Paste a link above, or drop one anywhere in this window.")
        } actions: {
            if let link = Clipboard.videoURL() {
                Button("Download from Clipboard") { manager.add(link) }
                    .glassButtonStyle()
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

            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}
