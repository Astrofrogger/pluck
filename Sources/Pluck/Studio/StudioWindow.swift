import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Pluck Studio's one window: a page at a time, with the page bar along the bottom, like an
/// editing program. Only Settings opens a window of its own.
struct StudioWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AIStudio.self) private var ai
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openPluckSettings) private var openSettings
    @State private var nav = StudioNavigator.shared

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PageBar(nav: nav)
        }
        .frame(minWidth: 1120, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            }
        }
        .modifier(DownloadSheets())
        .onAppear {
            // Screenshots: -PluckScreenshotPage <page> shows that page.
            if ScreenshotMode.scene != nil, let name = UserDefaults.standard.string(forKey: "PluckScreenshotPage"),
               let page = StudioNavigator.Page(rawValue: name) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { nav.show(page) }
            }
            AppDelegate.openMainWindow = { openWindow(id: "main"); NSApp.activate() }
            AppDelegate.openWindowByID = { nav.open(windowID: $0); openWindow(id: "main"); NSApp.activate() }
        }
        // A link handed over (pluck://, the Share menu) goes to Home's field.
        .onChange(of: manager.pendingLink) { if manager.pendingLink != nil { nav.show(.home) } }
        .onChange(of: ai.searchShown) {
            if ai.searchShown { ai.searchShown = false; nav.show(.search) }
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .home: ContentView()
        case .library: LibraryView()
        case .edit: EditPage(nav: nav)
        case .search: VisualSearchView()
        case .tools: ToolsPage(nav: nav)
        }
    }
}

// MARK: - Page bar

/// The pages along the bottom of the window (⌘1 to ⌘5).
private struct PageBar: View {
    @Bindable var nav: StudioNavigator
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StudioNavigator.Page.allCases) { page in
                Button { nav.show(page) } label: { item(page) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(page.shortcut, modifiers: .command)
                    .help(Text(page.title))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ page: StudioNavigator.Page) -> some View {
        let on = nav.page == page
        return VStack(spacing: 3) {
            Image(systemName: page.symbol)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(.secondary))
                .frame(height: 18)
                .overlay(alignment: .topTrailing) {
                    if page == .home, manager.activeCount > 0 {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 5, y: -1)
                    }
                }
            Text(page.title)
                .font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
        }
        .frame(width: 72, height: 40)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? Color.primary.opacity(0.08) : .clear))
        .overlay(alignment: .bottom) {
            if on {
                Capsule().fill(Design.Brand.gradient).frame(width: 22, height: 3).offset(y: 5)
                    .shadow(color: Design.Brand.pink.opacity(0.6), radius: 4)
            }
        }
        .contentShape(.rect)
        .animation(.snappy(duration: 0.2), value: on)
    }
}

// MARK: - Edit

/// The Edit page: the media on the left, the open files in tabs, and the Editor.
private struct EditPage: View {
    @Bindable var nav: StudioNavigator
    @AppStorage("studioMediaShown") private var mediaShown = true
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            if mediaShown {
                MediaPanel(nav: nav)
                    .frame(width: 250)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                if !nav.tabs.isEmpty {
                    TabStrip(nav: nav)
                    Divider()
                }
                if let tab = nav.current {
                    EditorView(target: tab.target, model: tab.model)
                        .id(tab.id)
                } else {
                    VStack(spacing: Design.Spacing.section) {
                        DropZone(symbol: "film", text: Text("Drop a video or song"), targeted: dropTargeted)
                        Button("Open…", action: openPanel)
                            .buttonStyle(BrandButtonStyle())
                    }
                    .padding(Design.Spacing.window)
                        .frame(maxWidth: 560, maxHeight: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy) { mediaShown.toggle() }
                } label: {
                    Label("Media", systemImage: "sidebar.left")
                }
                .help("Show or hide the media (⌥⌘L)")
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
        .navigationTitle(nav.current?.target.file.lastPathComponent ?? String(localized: "Edit"))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                for provider in providers {
                    if let url = await provider.load(URL.self), url.isFileURL, EditorTarget.canOpen(url) {
                        nav.open(EditorTarget(path: url.path))
                    }
                }
            }
            return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { nav.open(EditorTarget(path: url.path)) }
    }
}

/// The files open on the Edit page, as tabs.
private struct TabStrip: View {
    @Bindable var nav: StudioNavigator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(nav.tabs) { tab in
                    TabChip(title: tab.target.file.deletingPathExtension().lastPathComponent,
                            on: tab.id == nav.current?.id,
                            select: { nav.currentID = tab.id },
                            close: { nav.close(tab.id) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.background.secondary)
    }
}

private struct TabChip: View {
    let title: String
    let on: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || on ? 1 : 0)
            .accessibilityLabel("Close")
            .help("Close")
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(on ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .bottom) {
            if on { Capsule().fill(Design.Brand.gradient).frame(height: 2).padding(.horizontal, 8) }
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// The media to edit: what's downloading, and the Library's videos and songs.
private struct MediaPanel: View {
    @Bindable var nav: StudioNavigator
    @Environment(DownloadManager.self) private var manager
    @State private var library = LibraryStore.shared
    @State private var search = ""
    /// Files that aren't there (deleted, or on a drive that isn't plugged in): left out.
    @State private var missing: Set<String> = []

    private var media: [LibraryStore.Entry] {
        let terms = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.entries
            .filter { ($0.kind == .video || $0.kind == .audio) && !missing.contains($0.path)
                && (terms.isEmpty || $0.title.lowercased().contains(terms)) }
            .sorted { $0.added > $1.added }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneSearchField(prompt: "Search media", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let active = manager.items.filter(\.isActive)
                    if !active.isEmpty {
                        SidebarSection(title: Text("Downloading")) {
                            ForEach(active) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.callout).lineLimit(1)
                                    ProgressView(value: item.progress).controlSize(.small)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    SidebarSection(title: Text("Media")) {
                        ForEach(media) { entry in
                            MediaRow(entry: entry, on: nav.current?.target.path == entry.path)
                                .onTapGesture { nav.open(EditorTarget(path: entry.path)) }
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(.background.secondary)
        .task(id: library.entries.count) {
            let paths = library.entries.map(\.path)
            missing = await Task.detached { Set(paths.filter { !FileManager.default.fileExists(atPath: $0) }) }.value
        }
    }
}

private struct MediaRow: View {
    let entry: LibraryStore.Entry
    let on: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnail(file: entry.file, remote: entry.thumbnail, audio: entry.kind == .audio)
                .frame(width: 56, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(1)
                if let duration = entry.duration {
                    Text(Format.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? AnyShapeStyle(Design.Brand.gradient.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(entry.title)
    }
}

/// A small picture of a file: its saved thumbnail, or one Quick Look makes.
struct FileThumbnail: View {
    let file: URL
    var remote: URL?
    var audio = false
    @State private var image: NSImage?

    var body: some View {
        // The picture fills the frame it's given, cut to it, never wider.
        Color.primary.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: audio ? "waveform" : "film").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: file) {
            if let remote, remote.isFileURL, let saved = NSImage(contentsOf: remote) { image = saved; return }
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 160, height: 90),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tools

/// The Tools page: every tool as a tile, and the one that's open.
private struct ToolsPage: View {
    @Bindable var nav: StudioNavigator

    private var tools: [PluckTool] { PluckTool.allCases.filter { $0 != .library && $0 != .findShots } }

    var body: some View {
        if let tool = nav.tool {
            toolView(tool)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { nav.tool = nil } label: { Label("Tools", systemImage: "chevron.left") }
                            .help("All tools")
                    }
                }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)], spacing: 18) {
                    ForEach(tools) { tool in
                        Button { nav.tool = tool } label: { ToolTile(tool: tool) }
                            .buttonStyle(.plain)
                            .help(Text(tool.detail))
                    }
                }
                .padding(32)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Tools")
        }
    }

    @ViewBuilder private func toolView(_ tool: PluckTool) -> some View {
        switch tool {
        case .derush: DerushView()
        case .liveRecorder: LiveRecorderView()
        case .deliveryCheck: DeliveryCheckView()
        case .logoAnimator: LogoAnimatorView()
        case .brandPack: BrandPackView()
        case .musicFit: MusicFitView()
        case .officeRender: OfficeRenderView()
        case .library, .findShots: EmptyView()
        }
    }
}

private struct ToolTile: View {
    let tool: PluckTool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tool.tint.gradient, in: .rect(cornerRadius: 12))
                .shadow(color: tool.tint.opacity(hovering ? 0.6 : 0.3), radius: hovering ? 12 : 6, y: 4)
            Text(tool.name).font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(LinearGradient(colors: [tool.tint.opacity(hovering ? 0.22 : 0.12), Color.primary.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(tool.tint.opacity(hovering ? 0.5 : 0.15), lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}
