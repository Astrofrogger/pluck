import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Delivery Check's window: drop a finished export, say where it's going, and go through what
/// it found, each one shown in the player at its moment.
struct DeliveryCheckView: View {
    /// A video to check as soon as the window opens (screenshots).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckDeliveryCheckOpen")
    @Environment(DownloadManager.self) private var manager
    @AppStorage("deliveryCheckDestination") private var destination = DeliveryCheck.Destination.online
    @State private var file: URL?
    @State private var report: DeliveryCheck.Report?
    @State private var running: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var stage = ""
    @State private var problem: String?
    @State private var selected: DeliveryCheck.Issue.ID?
    @State private var player = AVPlayer()
    @State private var dropping = false

    var body: some View {
        Group {
            if let report, running == nil {
                results(report)
            } else {
                ToolPage {
                    ToolWelcome(symbol: "checkmark.seal", title: Text("Delivery Check"),
                                subtitle: Text("Look over a finished export before it goes out: flash frames, black, sound, loudness, typos in titles and more."))
                    bar
                    if running != nil {
                        checking
                    } else {
                        dropZone
                    }
                    if let problem { ProblemLabel(text: problem) }
                    PageNote(text: Text("Runs on this Mac."), symbol: "desktopcomputer")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear {
            if let url = Self.openFile {
                Self.openFile = nil
                open(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; open(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                if let url = await providers.first?.load(URL.self), Converting.isVideo(url) { open(url) }
            }
            return true
        }
    }

    /// The video, where it's going, and the main action, like the main window's bar.
    private var bar: some View {
        GlassGroup(spacing: Design.Spacing.controls) {
            HStack(spacing: Design.Spacing.controls) {
                FileCapsule(file: file, symbol: "film", placeholder: Text("Drop a finished video, or choose one"))
                BarPicker(symbol: "paperplane", label: Text("Going to"), selection: $destination,
                          current: Text(destination.shortLabel)) {
                    ForEach(DeliveryCheck.Destination.allCases) { Text($0.label).tag($0) }
                }
                Button(file == nil ? "Choose Video…" : "Choose…") { choose() }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .disabled(running != nil)
                Button("Check", systemImage: "checkmark.seal") { check() }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(file == nil || running != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var dropZone: some View {
        DropZone(symbol: "film.stack",
                 text: Text("Flash frames, black, a frozen picture, sound dropping out, a silent channel, loudness for where it’s going, spelling in on-screen text, text too close to the edge, and the right size and frame rate."),
                 targeted: dropping)
    }

    private var checking: some View {
        ItemRow(symbol: "checkmark.seal", title: Text(file?.lastPathComponent ?? ""), subtitle: Text(stage)) {
            ProgressView(value: progress).padding(.top, 4)
        } actions: {
            RowButton(symbol: "stop.fill", label: "Stop") { running?.cancel(); running = nil }
        }
    }

    private func results(_ report: DeliveryCheck.Report) -> some View {
        VStack(spacing: 0) {
            bar
                .padding([.horizontal, .top], Design.Spacing.window)
                .padding(.bottom, Design.Spacing.section)
            HStack(alignment: .top, spacing: Design.Spacing.section) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Spacing.section) {
                        ZStack {
                            VideoPlayer(player: player)
                            if let box = selectedIssue?.box { highlight(box) }
                        }
                        .aspectRatio(report.size.width / report.size.height, contentMode: .fit)
                        .background(.black)
                        .clipShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
                        Card {
                            CardHeader(symbol: "info.circle", title: Text("The file"))
                            ForEach(report.facts, id: \.0) { fact in
                                CardField(label: Text(fact.0).foregroundStyle(.secondary)) {
                                    Text(fact.1).monospacedDigit().textSelection(.enabled)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(minWidth: 360, idealWidth: 460)
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    summary(report)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(report.issues) { issue in
                                row(issue, fps: report.fps)
                            }
                        }
                    }
                    PageNote(text: Text("Runs on this Mac."), symbol: "desktopcomputer")
                }
                .frame(minWidth: 380)
            }
            .padding([.horizontal, .bottom], Design.Spacing.window)
        }
    }

    private func summary(_ report: DeliveryCheck.Report) -> some View {
        let problems = report.issues.filter { $0.severity == .problem }.count
        let warnings = report.issues.filter { $0.severity == .warning }.count
        return CardHeader(symbol: problems > 0 ? "xmark.octagon" : warnings > 0 ? "exclamationmark.triangle" : "checkmark.seal",
                          title: problems == 0 && warnings == 0 ? Text("Ready to deliver")
                              : problems > 0 ? Text("^[\(problems) problem](inflect: true) to fix")
                              : Text("^[\(warnings) thing](inflect: true) to check"),
                          subtitle: problems > 0 && warnings > 0 ? Text("^[\(warnings) thing](inflect: true) to check") : Text(report.destination.label),
                          tint: problems > 0 ? .red : warnings > 0 ? .orange : .green) {
            Button("Save Report…") { save(report) }
                .buttonStyle(GlassCapsuleButtonStyle())
        }
    }

    private func row(_ issue: DeliveryCheck.Issue, fps: Double) -> some View {
        ItemRow(symbol: icon(issue.severity), tint: color(issue.severity), title: Text(issue.title), subtitle: Text(issue.detail)) {
            if let word = issue.word {
                Button("It’s Spelled Right") { learn(word) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Pluck remembers “\(word)” and won’t mark it again")
            }
        } actions: {
            if let time = issue.time {
                Text(DeliveryCheck.timecode(time, fps: fps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected == issue.id ? 2 : 0)
        }
        .contentShape(.rect)
        .onTapGesture {
            selected = issue.id
            if let time = issue.time { seek(time) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label(issue.severity)): \(issue.title)"))
        .accessibilityAddTraits(.isButton)
    }

    /// The text an issue is about, outlined on the picture.
    private func highlight(_ box: CGRect) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            Rectangle()
                .stroke(.yellow, lineWidth: 2)
                .frame(width: box.width * size.width + 8, height: box.height * size.height + 8)
                .position(x: box.midX * size.width, y: (1 - box.midY) * size.height)
        }
        .allowsHitTesting(false)
    }

    private var selectedIssue: DeliveryCheck.Issue? { report?.issues.first { $0.id == selected } }

    private func icon(_ severity: DeliveryCheck.Issue.Severity) -> String {
        switch severity {
        case .problem: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }

    private func color(_ severity: DeliveryCheck.Issue.Severity) -> Color {
        switch severity {
        case .problem: .red
        case .warning: .orange
        case .note: .secondary
        }
    }

    private func label(_ severity: DeliveryCheck.Issue.Severity) -> String {
        switch severity {
        case .problem: String(localized: "Problem")
        case .warning: String(localized: "To check")
        case .note: String(localized: "Note")
        }
    }

    // MARK: - Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        file = url
        report = nil
        problem = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        check()
    }

    private func check() {
        guard let file, running == nil else { return }
        guard let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            problem = Converting.Failure.noFFmpeg.localizedDescription
            return
        }
        report = nil
        problem = nil
        progress = 0
        let destination = destination
        running = Task {
            do {
                let result = try await DeliveryCheck.run(file, destination: destination, ffmpeg: ffmpeg, ffprobe: ffprobe) { value, text in
                    Task { @MainActor in
                        progress = value
                        if !text.isEmpty { stage = text }
                    }
                }
                report = result
                selected = result.issues.first?.id
                if let time = result.issues.first?.time { seek(time) }
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            running = nil
        }
    }

    private func seek(_ time: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: time + 0.02, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func learn(_ word: String) {
        DeliveryCheck.learn(word)
        report?.issues.removeAll { $0.word?.lowercased() == word.lowercased() }
    }

    private func save(_ report: DeliveryCheck.Report) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = report.file.deletingPathExtension().lastPathComponent + String(localized: " (delivery check).txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = [String(localized: "Delivery check: \(report.file.lastPathComponent)"),
                     String(localized: "Going to: \(report.destination.label)"), ""]
        lines += report.facts.map { "\($0.0): \($0.1)" }
        lines.append("")
        for issue in report.issues {
            let time = issue.time.map { DeliveryCheck.timecode($0, fps: report.fps) + "  " } ?? ""
            lines.append("[\(label(issue.severity))] \(time)\(issue.title): \(issue.detail)")
        }
        if report.issues.isEmpty { lines.append(String(localized: "Ready to deliver: nothing found.")) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
