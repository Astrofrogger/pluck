import AVFoundation
import SwiftUI

/// The small title over each part of Home.
private struct HomeHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// A panel on Home: a small title, and rows under it.
private struct HomeCard<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HomeHeading(title: title)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The quick ways in under Home's field.
struct HomeShortcuts: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        HStack(spacing: 20) {
            link("Open File…", symbol: "doc") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie, .audio]
                panel.allowsMultipleSelection = true
                panel.prompt = String(localized: "Open")
                guard panel.runModal() == .OK else { return }
                for url in panel.urls { nav.open(EditorTarget(path: url.path)) }
            }
            link("Search My Library", symbol: "sparkle.magnifyingglass") { nav.show(.search) }
            link("Record a Stream", symbol: "record.circle") { nav.open(.liveRecorder) }
        }
        .font(.callout)
    }

    private func link(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Continue editing

/// Home's files edited lately, as big cards: click one to carry on where you left off.
struct ContinueEditing: View {
    @State private var nav = StudioNavigator.shared

    private var files: [URL] {
        nav.recent.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading(title: "Continue Editing")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), alignment: .leading, spacing: 16) {
                    ForEach(files.prefix(4), id: \.self) { file in
                        EditCard(file: file, edited: nav.recentDates[file.path]) { nav.open(EditorTarget(path: file.path)) }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                Button("Remove from Continue Editing") { nav.forget(file.path) }
                            }
                    }
                }
            }
        }
    }
}

private struct EditCard: View {
    let file: URL
    let edited: Date?
    let open: () -> Void
    @State private var length: Double?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { FileThumbnail(file: file, audio: !Converting.isVideo(file)) }
                    .overlay(alignment: .bottomTrailing) {
                        if let length {
                            Text(Format.duration(length))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.65), in: .rect(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .overlay {
                        // Under the pointer: dimmed a little, with a play button.
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Design.Brand.gradient))
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous)
                            .strokeBorder(Design.Brand.gradient, lineWidth: 2)
                            .opacity(hovering ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.03 : 1)
                    .animation(.snappy(duration: 0.18), value: hovering)
                Text(file.deletingPathExtension().lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let edited {
                    Text("Edited \(edited, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.lastPathComponent)
        .task(id: file) {
            if let seconds = try? await AVURLAsset(url: file).load(.duration).seconds, seconds.isFinite, seconds > 0 {
                length = seconds
            }
        }
    }
}

// MARK: - Subscriptions and downloads

/// Home's two panels: what's new from subscriptions, and the downloads.
struct HomeActivity: View {
    @Binding var allDownloads: Bool
    @Environment(DownloadManager.self) private var manager
    @State private var subscriptions = Subscriptions.shared
    @State private var nav = StudioNavigator.shared

    private var followed: [Subscription] {
        subscriptions.list.sorted { ($0.lastFound ?? $0.added) > ($1.lastFound ?? $1.added) }
    }

    var body: some View {
        if !followed.isEmpty || !manager.items.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if !followed.isEmpty {
                    HomeCard(title: "New from Your Subscriptions") {
                        EmptyView()
                    } content: {
                        ForEach(followed.prefix(5)) { subscription in
                            subscriptionRow(subscription)
                        }
                    }
                }
                if !manager.items.isEmpty {
                    HomeCard(title: "Downloads") {
                        Button(allDownloads ? "Show Less" : "See All") { withAnimation(.snappy) { allDownloads.toggle() } }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } content: {
                        ForEach(manager.items.prefix(5)) { item in
                            DownloadLine(item: item)
                        }
                    }
                }
            }
        }
    }

    private func subscriptionRow(_ subscription: Subscription) -> some View {
        let fresh = subscription.lastFound.map { Date.now.timeIntervalSince($0) < 3 * 86_400 } ?? false
        return Button {
            nav.showLibrary(.subscription(subscription.id, subscription.title))
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(fresh ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .frame(width: 7, height: 7)
                Text(subscription.title).lineLimit(1)
                Spacer(minLength: 8)
                if subscriptions.checking.contains(subscription.id) {
                    ProgressView().controlSize(.mini)
                } else if let found = subscription.lastFound {
                    Text(found, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(minHeight: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show in the Library")
    }
}

/// One download on Home, in a line: how far it is, or that it's done.
private struct DownloadLine: View {
    let item: DownloadItem
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.title).lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .font(.callout)
            if item.isActive {
                // A slim bar in Pluck's colours.
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Design.Brand.gradient).frame(width: geometry.size.width * max(item.progress, 0.02))
                        }
                }
                .frame(height: 4)
                .animation(.smooth, value: item.progress)
            }
        }
        .frame(minHeight: 22)
        .contentShape(.rect)
        .onTapGesture {
            if let file = item.existingFile, EditorTarget.canOpen(file) { StudioNavigator.shared.open(EditorTarget(path: file.path)) }
        }
        .help(item.existingFile != nil ? Text("Open in the Editor") : Text(item.title))
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .failed:
            Button("Retry") { manager.retry(item) }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        default:
            Text(item.progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
