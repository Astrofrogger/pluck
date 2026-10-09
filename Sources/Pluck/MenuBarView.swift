import SwiftUI

/// The panel behind the menu bar icon: paste a link, pick a format, follow progress.
struct MenuBarView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openPluckSettings) private var openSettings
    @State private var urlText = ""
    @FocusState private var focused: Bool

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var fieldLinks: [String] { Links.extract(fromText: trimmed) }
    private var isValid: Bool {
        if fieldLinks.count > 1 { return true }
        if Spotify.parse(trimmed) != nil { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// A clipboard link worth offering: not typed yet and not already downloaded.
    private var clipboardLink: String? {
        guard trimmed.isEmpty, let link = Clipboard.videoURL(),
              !manager.items.contains(where: { $0.url == link }) else { return nil }
        return link
    }

    private var recent: [DownloadItem] { Array(manager.items.prefix(6)) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            inputBar
                .padding(.horizontal, 16)

            if let link = clipboardLink {
                clipboardSuggestion(link)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            downloads
                .padding(.top, 14)

            footer
        }
        .frame(width: 360)
        .animation(.snappy(duration: 0.25), value: manager.items.map(\.id))
        .animation(.snappy(duration: 0.25), value: clipboardLink)
        .onAppear { focused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pluck").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Menu {
                Button("Open Pluck", action: openMain)
                Button("Settings…") { openSettings() }
                Divider()
                Button("Quit Pluck") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .help("More")
        }
    }

    private var summary: String {
        let running = manager.items.filter(\.isActive)
        guard !running.isEmpty else { return String(localized: "Ready") }
        let progress = running.map(\.progress).reduce(0, +) / Double(running.count)
        return String(localized: "\(running.count) downloading · \(Int(progress * 100))%")
    }

    // MARK: - Input

    private var inputBar: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Paste a link or search", text: $urlText)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(submit)
                    if !urlText.isEmpty {
                        Button { urlText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Clear Link")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassBackground(in: .capsule, interactive: true)

                FormatMenu()
                    .controlSize(.regular)
                    .glassButtonStyle()

                Button(action: submit) {
                    Image(systemName: "arrow.down")
                        .fontWeight(.semibold)
                        .frame(width: 20, height: 20)
                }
                .glassProminentButtonStyle()
                .buttonBorderShape(.circle)
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Download")
                .help("Download")
            }
        }
    }

    private func clipboardSuggestion(_ link: String) -> some View {
        Button { manager.add(link) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Download from Clipboard")
                        .font(.callout.weight(.medium))
                    Text(Self.shortLink(link))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(10)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(MenuBarCardStyle())
        .accessibilityLabel("Download from Clipboard")
        .accessibilityValue(Self.shortLink(link))
        .help(link)
    }

    static func shortLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host(percentEncoded: false) else { return link }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return site + (url.path(percentEncoded: false) == "/" ? "" : url.path(percentEncoded: false))
    }

    // MARK: - Downloads

    @ViewBuilder
    private var downloads: some View {
        if recent.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("Paste a link to start downloading")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 2) {
                    ForEach(recent) { MenuBarRow(item: $0) }
                }
                .padding(.horizontal, 8)
                if manager.items.count > recent.count {
                    Button("\(manager.items.count - recent.count) more in Pluck…", action: openMain)
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: openMain) {
                Label("Open Pluck", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Spacer()
            if manager.hasFinished {
                Button("Clear Finished") { manager.clearFinished() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.fill.quinary)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 12)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func submit() {
        // Words rather than a link: search in the main window.
        if !isValid, !trimmed.isEmpty {
            manager.startSearch(trimmed)
            urlText = ""
            return
        }
        guard isValid else { return }
        manager.add(fieldLinks.count > 1 ? fieldLinks : [trimmed])
        urlText = ""
    }
}

/// Subtle filled card that highlights on hover and press.
private struct MenuBarCardStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.fill.tertiary)
                    .opacity(configuration.isPressed ? 1 : hovering ? 0.8 : 0.5)
            }
            .onHover { hovering = $0 }
    }
}

private struct MenuBarRow: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            action
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let file = item.existingFile { NSWorkspace.shared.open(file) } }
        .onDrag {
            guard let file = item.existingFile else { return NSItemProvider() }
            return NSItemProvider(contentsOf: file) ?? NSItemProvider()
        }
        .accessibilityElement(children: .contain)
    }

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnail) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: item.options.isAudio ? "music.note" : "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 52, height: 30)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 8) {
                ThinProgressBar(value: item.progress)
                Text("\(Int(item.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading")
            .accessibilityValue("\(Int(item.progress * 100)) percent")
        case .processing:
            caption(item.phase ?? String(localized: "Finishing up…"))
        case .queued where item.phase != nil:
            caption(item.phase ?? "")
        case .queued:
            caption(String(localized: "Waiting…"))
        case .starting:
            caption(item.phase ?? String(localized: "Fetching info…"))
        case .finished where item.fileMissing:
            caption(String(localized: "File moved or deleted"))
        case .finished:
            Label(item.fileSize.map { String(localized: "Done · \(Format.bytes($0))") } ?? String(localized: "Done"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label(item.errorMessage ?? String(localized: "Failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(item.errorMessage ?? "")
        case .paused:
            caption(String(localized: "Paused · \(Int(item.progress * 100))%"))
        case .cancelled:
            caption(String(localized: "Cancelled"))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        Group {
            switch item.state {
            case .finished where item.fileMissing:
                iconButton("arrow.clockwise", label: "Download Again") { manager.retry(item) }
            case .finished:
                iconButton("magnifyingglass", label: "Show in Finder") {
                    if let file = item.existingFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            case .failed, .cancelled:
                iconButton("arrow.clockwise", label: "Try Again") { manager.retry(item) }
            case .paused:
                iconButton("play.fill", label: "Resume Download") { manager.resume(item) }
            case .downloading:
                iconButton("pause.fill", label: "Pause Download") { manager.pause(item) }
            default:
                iconButton("xmark", label: "Cancel Download") { manager.cancel(item) }
            }
        }
        .opacity(hovering || item.state != .finished ? 1 : 0.6)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A 4pt capsule progress bar, quieter than the system one at this size.
struct ThinProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.secondary)
                Capsule().fill(.tint)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.3), value: value)
    }
}

/// The menu bar icon: a down arrow, which becomes a progress ring while downloading.
struct MenuBarIcon: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = manager.items.filter(\.isActive)
        // Rounded to 5% steps so the menu bar isn't redrawn on every byte.
        let progress = running.isEmpty ? nil
            : ((running.map(\.progress).reduce(0, +) / Double(running.count)) * 20).rounded() / 20
        Image(nsImage: Self.render(progress: progress))
            .accessibilityLabel(running.isEmpty ? "Pluck" : String(localized: "Pluck, \(running.count) downloading"))
            .onAppear {
                AppDelegate.openMainWindow = { openWindow(id: "main"); NSApp.activate() }
            }
    }

    static func render(progress: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawRing(in: rect, progress: progress)
            drawGlyph(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The circle, or while downloading a faint track with a progress arc from 12 o'clock.
    static func drawRing(in rect: NSRect, progress: Double?) {
        let unit = rect.width / 18
        let ring = rect.insetBy(dx: 1.5 * unit, dy: 1.5 * unit)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let width = 1.6 * unit

        guard let progress else {
            NSColor.black.setStroke()
            let circle = NSBezierPath(ovalIn: ring)
            circle.lineWidth = width
            circle.stroke()
            return
        }
        NSColor.black.withAlphaComponent(0.3).setStroke()
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = width
        track.stroke()

        NSColor.black.setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: ring.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * max(progress, 0.03), clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        arc.stroke()
    }

    /// The app icon's glyph (arrow over a bar), drawn on an 18pt grid so its outer edges,
    /// round caps included, sit exactly on the centre: y 4.1…13.9 and x 5.1…12.9 around 9.
    static func drawGlyph(in rect: NSRect) {
        let unit = rect.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        let glyph = NSBezierPath()
        // Stem and arrowhead, tip just above the bar as in the app icon.
        glyph.move(to: p(9, 13.1))
        glyph.line(to: p(9, 6.6))
        glyph.move(to: p(6.1, 9.5))
        glyph.line(to: p(9, 6.6))
        glyph.line(to: p(11.9, 9.5))
        // Bar.
        glyph.move(to: p(5.9, 4.9))
        glyph.line(to: p(12.1, 4.9))

        glyph.lineWidth = 1.6 * unit
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        NSColor.black.setStroke()
        glyph.stroke()
    }
}
