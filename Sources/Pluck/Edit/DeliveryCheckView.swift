import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Delivery Check's window: drop a finished export, say where it's going, and go through what
/// it found, each one shown in the player at its moment.
struct DeliveryCheckView: View {
    /// A video to check as soon as the window opens (screenshots).
    @MainActor static var openFile: URL?
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Spacing.section) {
                SheetHeader(symbol: "checkmark.seal", title: Text("Delivery Check"),
                            subtitle: Text("Look over a finished export before it goes out: flash frames, black, sound, loudness, typos in titles and more. Runs on this Mac."),
                            subtitleIsName: false)
                controls
            }
            .padding(Design.Spacing.window)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            if let url = Self.openFile {
                Self.openFile = nil
                open(url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                if let url = await providers.first?.load(URL.self), Converting.isVideo(url) { open(url) }
            }
            return true
        }
    }

    private var controls: some View {
        HStack(spacing: Design.Spacing.controls) {
            Button("Choose Video…") { choose() }
            if let file {
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Going to", selection: $destination) {
                ForEach(DeliveryCheck.Destination.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Button("Check") { check() }
                .buttonStyle(.borderedProminent)
                .disabled(file == nil || running != nil)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        if running != nil {
            VStack(spacing: 12) {
                ProgressView(value: progress).frame(width: 320)
                Text(stage).foregroundStyle(.secondary)
                Button("Stop") { running?.cancel(); running = nil }
            }
        } else if let report {
            results(report)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 40)).foregroundStyle(dropping ? .blue : .secondary)
                    .accessibilityHidden(true)
                Text("Drop a finished video here").font(.title3.weight(.semibold))
                Text("Flash frames, black, a frozen picture, sound dropping out, a silent channel, loudness for where it’s going, spelling in on-screen text, text too close to the edge, and the right size and frame rate.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private func results(_ report: DeliveryCheck.Report) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: Design.Spacing.controls) {
                ZStack {
                    VideoPlayer(player: player)
                    if let box = selectedIssue?.box { highlight(box) }
                }
                .aspectRatio(report.size.width / report.size.height, contentMode: .fit)
                .background(.black)
                .clipShape(.rect(cornerRadius: Design.Radius.control))
                ForEach(report.facts, id: \.0) { fact in
                    LabeledContent(fact.0) { Text(fact.1).monospacedDigit().textSelection(.enabled) }
                        .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Spacing.inset)
            .frame(minWidth: 380, idealWidth: 460)

            VStack(alignment: .leading, spacing: 0) {
                summary(report)
                    .padding(Design.Spacing.inset)
                Divider()
                List(selection: $selected) {
                    ForEach(report.issues) { issue in
                        row(issue, fps: report.fps).tag(issue.id)
                    }
                }
                .onChange(of: selected) { _, id in
                    if let issue = report.issues.first(where: { $0.id == id }), let time = issue.time { seek(time) }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Save Report…") { save(report) }
                }
                .padding(Design.Spacing.inset)
            }
            .frame(minWidth: 420)
        }
    }

    private func summary(_ report: DeliveryCheck.Report) -> some View {
        let problems = report.issues.filter { $0.severity == .problem }.count
        let warnings = report.issues.filter { $0.severity == .warning }.count
        return Group {
            if problems == 0 && warnings == 0 {
                Label("Ready to deliver", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label {
                    if problems > 0 {
                        Text("^[\(problems) problem](inflect: true) to fix, ^[\(warnings) thing](inflect: true) to check")
                    } else {
                        Text("^[\(warnings) thing](inflect: true) to check")
                    }
                } icon: {
                    Image(systemName: problems > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(problems > 0 ? .red : .orange)
            }
        }
        .font(.headline)
    }

    private func row(_ issue: DeliveryCheck.Issue, fps: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(issue.severity))
                .foregroundStyle(color(issue.severity))
                .accessibilityLabel(label(issue.severity))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(issue.title).fontWeight(.medium)
                    Spacer()
                    if let time = issue.time {
                        Text(DeliveryCheck.timecode(time, fps: fps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let word = issue.word {
                    Button("It’s Spelled Right") { learn(word) }
                        .controlSize(.small)
                        .help("Pluck remembers “\(word)” and won’t mark it again")
                }
            }
        }
        .padding(.vertical, 4)
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
