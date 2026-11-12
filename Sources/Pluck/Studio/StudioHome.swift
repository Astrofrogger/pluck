import AVFoundation
import SwiftUI

// Pluck Studio's Home, as in page 1 of the 2026-11-12 layout reference: Continue, New from
// subscriptions, Downloading. (The paste field is in ContentView.)

/// A part of Home: its title, and something small on the right.
private struct HomeSection<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Spacer(minLength: 8)
                trailing.font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A small dark label on a picture: "Project", "12:04".
private struct PictureChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Design.Studio.hint.monospacedDigit())
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color(red: 15 / 255, green: 15 / 255, blue: 17 / 255).opacity(0.72), in: .rect(cornerRadius: 5, style: .continuous))
    }
}

/// A 16:9 picture with Studio's corners and the plum outline under the pointer.
private struct HomePicture<Picture: View>: View {
    let hovering: Bool
    @ViewBuilder var picture: Picture

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { picture }
            .background(Design.Studio.raised)
            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            // Calm hover: a plum outline just outside the picture, nothing moves.
            .overlay {
                RoundedRectangle(cornerRadius: Design.Studio.controlRadius + 3, style: .continuous)
                    .strokeBorder(Design.Brand.gradient, lineWidth: 2)
                    .padding(-3)
                    .opacity(hovering ? 1 : 0)
            }
            .animation(.snappy(duration: 0.18), value: hovering)
    }
}

// MARK: - Continue

/// Files and projects edited lately: click one to carry on where you left off.
struct ContinueEditing: View {
    @State private var nav = StudioNavigator.shared

    /// Files that are there, and projects.
    private var items: [String] {
        nav.recent.filter { key in
            if let id = StudioNavigator.projectID(in: key) { return FileManager.default.fileExists(atPath: ProjectStore.url(for: id).path) }
            return FileManager.default.fileExists(atPath: key)
        }
    }

    var body: some View {
        if !items.isEmpty {
            HomeSection(title: "Continue") {
                Button("All projects") { nav.show(.edit) }.buttonStyle(.plain)
            } content: {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), alignment: .leading, spacing: 18) {
                    ForEach(items.prefix(4), id: \.self) { key in
                        if let id = StudioNavigator.projectID(in: key), let project = ProjectStore.load(id) {
                            EditCard(file: project.clips.first?.file, project: project, edited: nav.recentDates[key]) { nav.open(project) }
                                .contextMenu {
                                    Button("Remove from Continue Editing") { nav.forget(key) }
                                }
                        } else {
                            let file = URL(fileURLWithPath: key)
                            EditCard(file: file, edited: nav.recentDates[key]) { nav.open(EditorTarget(path: key)) }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                    Button("Remove from Continue Editing") { nav.forget(key) }
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct EditCard: View {
    let file: URL?
    var project: Project?
    let edited: Date?
    let open: () -> Void
    @State private var hovering = false

    private var kind: String {
        if project != nil { return String(localized: "Project") }
        guard let file else { return "" }
        return Converting.isVideo(file) ? String(localized: "Video") : String(localized: "Audio")
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                HomePicture(hovering: hovering) {
                    if let file { FileThumbnail(file: file, audio: !Converting.isVideo(file)) }
                }
                .overlay(alignment: .bottomLeading) { PictureChip(text: kind).padding(8) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? file?.deletingPathExtension().lastPathComponent ?? "")
                        .font(Design.Studio.body)
                        .foregroundStyle(Design.Studio.text)
                        .lineLimit(1)
                    if let edited {
                        Text("Edited \(edited, format: .relative(presentation: .named))")
                            .font(Design.Studio.hint)
                            .foregroundStyle(Design.Studio.textQuiet)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(project?.name ?? file?.lastPathComponent ?? "")
    }
}

// MARK: - New from subscriptions and Downloading

/// Home's bottom row: what subscriptions brought in lately (left), and the downloads (right).
struct HomeActivity: View {
    @Binding var allDownloads: Bool
    @Environment(DownloadManager.self) private var manager
    @State private var subscriptions = Subscriptions.shared
    @State private var library = LibraryStore.shared
    @State private var nav = StudioNavigator.shared

    /// The newest saved videos that came from a subscription, with the subscription.
    private var fresh: [(entry: LibraryStore.Entry, subscription: Subscription)] {
        var found: [(entry: LibraryStore.Entry, subscription: Subscription)] = []
        for subscription in subscriptions.list {
            let downloaded = Set(subscription.downloaded)
            for entry in library.entries where entry.source.map({ downloaded.contains(Links.identity($0)) }) ?? false {
                found.append((entry, subscription))
            }
        }
        return Array(found.sorted { $0.entry.added > $1.entry.added }.prefix(6))
    }

    var body: some View {
        let fresh = fresh
        if !fresh.isEmpty || !manager.items.isEmpty {
            HStack(alignment: .top, spacing: 32) {
                if !fresh.isEmpty {
                    HomeSection(title: "New from subscriptions") {
                        Text("\(fresh.count) new")
                    } content: {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), alignment: .leading, spacing: 14) {
                            ForEach(fresh, id: \.entry.id) { pair in
                                HomeVideoCard(entry: pair.entry, channel: pair.subscription.title) {
                                    nav.showLibrary(.subscription(pair.subscription.id, pair.subscription.title))
                                }
                            }
                        }
                    }
                }
                if !manager.items.isEmpty {
                    downloading.frame(width: fresh.isEmpty ? nil : 360)
                }
            }
        }
    }

    private var downloading: some View {
        let active = manager.items.filter(\.isActive)
        return HomeSection(title: "Downloading") {
            HStack(spacing: 14) {
                if manager.hasFinished {
                    Button("Clear finished") { withAnimation { manager.clearFinished() } }.buttonStyle(.plain)
                }
                if manager.items.count > 4 {
                    Button(allDownloads ? "Show less" : "See all") { withAnimation(.snappy) { allDownloads.toggle() } }.buttonStyle(.plain)
                }
                if !active.isEmpty {
                    Button("Pause all") { for item in active { manager.pause(item) } }.buttonStyle(.plain)
                }
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(manager.items.prefix(4).enumerated()), id: \.element.id) { index, item in
                    DownloadLine(item: item)
                    if index < min(manager.items.count, 4) - 1 {
                        Rectangle().fill(Design.rgb(0x1F1F23)).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, Design.Studio.panelInset)
            .padding(.vertical, 6)
            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
        }
    }
}

/// A video a subscription brought in: picture with its length, name, the subscription.
private struct HomeVideoCard: View {
    let entry: LibraryStore.Entry
    let channel: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HomePicture(hovering: hovering) {
                    AsyncImage(url: entry.thumbnail) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = entry.duration, duration > 0 { PictureChip(text: Format.duration(duration)).padding(6) }
                }
                Text(entry.title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                Text(verbatim: channel).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).padding(.top, -4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show in the Library")
    }
}

/// One download: picture, name, how far it is, and a thin bar.
private struct DownloadLine: View {
    let item: DownloadItem
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 56, height: 32)
                .overlay {
                    AsyncImage(url: item.thumbnail) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
                .background(Design.Studio.raised)
                .clipShape(.rect(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Spacer(minLength: 8)
                    state
                }
                GeometryReader { geometry in
                    Capsule().fill(Design.Studio.line)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Design.Brand.gradient).frame(width: geometry.size.width * shownProgress)
                        }
                }
                .frame(height: Design.Studio.sliderTrack)
                .animation(.smooth, value: item.progress)
            }
        }
        .frame(height: 56)
        .contentShape(.rect)
        .onTapGesture {
            if let file = item.existingFile, EditorTarget.canOpen(file) { StudioNavigator.shared.open(EditorTarget(path: file.path)) }
        }
        .help(item.existingFile != nil ? Text("Open in the Editor") : Text(item.title))
    }

    private var shownProgress: Double {
        switch item.state {
        case .finished: 1
        case .queued: 0
        default: max(item.progress, 0)
        }
    }

    @ViewBuilder private var state: some View {
        Group {
            switch item.state {
            case .failed:
                Button("Retry") { manager.retry(item) }.buttonStyle(.plain).foregroundStyle(.orange)
            case .finished:
                Text("Done")
            case .paused:
                Text("Paused")
            case .cancelled:
                Text("Stopped")
            case .queued:
                Text("Waiting")
            default:
                if let eta = item.eta, eta > 0 {
                    Text("\(item.progress, format: .percent.precision(.fractionLength(0))) · \(Format.duration(eta))")
                } else {
                    Text(item.progress, format: .percent.precision(.fractionLength(0)))
                }
            }
        }
        .font(Design.Studio.hint.monospacedDigit())
        .foregroundStyle(Design.Studio.textQuiet)
        .lineLimit(1)
        .fixedSize()
    }
}
