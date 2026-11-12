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
        VStack(spacing: Design.Studio.panelGap) {
            bar
            if let report, running == nil {
                HStack(spacing: Design.Studio.panelGap) {
                    playerPanel(report)
                    resultsPanel(report)
                }
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    if running != nil { checking } else { dropZone }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    StudioFootnote(text: "Runs on this Mac.", symbol: "desktopcomputer")
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel()
            }
        }
        .foregroundStyle(Design.Studio.text)
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

    /// The video, where it's going, and the main action, in one 48 pt field (board ToolDelivery).
    private var bar: some View {
        HStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 14)).foregroundStyle(Design.Studio.textQuiet)
            Group {
                if let file {
                    Text(file.lastPathComponent).foregroundStyle(Design.Studio.text)
                } else {
                    Text("Drop a finished video, or choose one").foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Picker("Going to", selection: $destination) {
                    ForEach(DeliveryCheck.Destination.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane").font(.system(size: 11))
                    Text(destination.shortLabel)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(Design.Studio.body)
                .foregroundStyle(Design.Studio.textQuiet)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Going to")
            Rectangle().fill(Design.Studio.line).frame(width: 1, height: 18)
            Button { choose() } label: {
                Text(file == nil ? "Choose Video…" : "Choose…")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(running != nil)
            Button { check() } label: {
                Label(report == nil ? "Check" : "Check again", systemImage: "checkmark.seal")
            }
            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            .disabled(file == nil || running != nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: Design.Studio.line)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .studioPanel()
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 26)).foregroundStyle(Design.Studio.textQuiet)
            Text("Drop a finished video, or choose one").font(Design.Studio.sectionTitle)
            Text("Flash frames, black, a frozen picture, sound dropping out, a silent channel, loudness for where it’s going, spelling in on-screen text, text too close to the edge, and the right size and frame rate.")
                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(32)
        .frame(maxWidth: 640, minHeight: 220)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropping ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Design.Studio.line),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .contentShape(.rect)
        .onTapGesture { choose() }
    }

    private var checking: some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "checkmark.seal")
            VStack(alignment: .leading, spacing: 6) {
                Text(file?.lastPathComponent ?? "").font(.system(size: 13)).lineLimit(1)
                Text(stage).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                StudioProgress(share: progress)
            }
            Button("Stop", systemImage: "stop.fill") { running?.cancel(); running = nil }
                .buttonStyle(StudioFlatButtonStyle())
                .help("Stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .studioBox()
    }

    // MARK: - Results

    /// The picture at 400 pt high, its scrub row with the issues on it, and the file's facts.
    private func playerPanel(_ report: DeliveryCheck.Report) -> some View {
        let aspect = report.size.height > 0 ? report.size.width / report.size.height : 16 / 9
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 18) {
                    ZStack {
                        PlayerSurface(player: player)
                        if let box = selectedIssue?.box { highlight(box) }
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .frame(maxHeight: 400)
                    ScrubRow(player: player, duration: report.duration,
                             ticks: report.issues.compactMap { issue in
                                 guard let time = issue.time, issue.severity != .note else { return nil }
                                 return (time, issue.severity == .problem ? Design.Studio.bad : Design.Studio.warn)
                             })
                }
                .frame(maxWidth: 400 * aspect)
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("The file").font(Design.Studio.sectionTitle).padding(.bottom, 8)
                    ForEach(report.facts, id: \.0) { fact in
                        HStack(spacing: 0) {
                            Text(fact.0).foregroundStyle(Design.Studio.textQuiet).frame(width: 110, alignment: .leading)
                            Text(fact.1).monospacedDigit().textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(Design.Studio.body)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) { Rectangle().fill(Design.Studio.raised).frame(height: 1) }
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioPanel()
    }

    private func resultsPanel(_ report: DeliveryCheck.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summary(report).padding(.horizontal, 4).padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(report.issues) { issue in
                        row(issue, fps: report.fps)
                    }
                }
                .padding(1)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 440)
        .frame(maxHeight: .infinity, alignment: .top)
        .studioPanel()
    }

    private func summary(_ report: DeliveryCheck.Report) -> some View {
        let problems = report.issues.filter { $0.severity == .problem }.count
        let warnings = report.issues.filter { $0.severity == .warning }.count
        return HStack(spacing: 12) {
            StudioTile(symbol: problems > 0 ? "xmark.octagon" : warnings > 0 ? "exclamationmark.triangle" : "checkmark.seal",
                       colour: problems > 0 ? Design.Studio.bad : warnings > 0 ? Design.Studio.warn : Design.Studio.good)
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if problems == 0 && warnings == 0 {
                        Text("Ready to deliver")
                    } else if problems > 0 {
                        Text("^[\(problems) problem](inflect: true) to fix")
                    } else {
                        Text("^[\(warnings) thing](inflect: true) to check")
                    }
                }
                .font(Design.Studio.sectionTitle)
                Group {
                    if problems > 0 && warnings > 0 {
                        Text("^[\(warnings) thing](inflect: true) to check")
                    } else {
                        Text(report.destination.label)
                    }
                }
                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Save report…") { save(report) }
                .buttonStyle(StudioFlatButtonStyle())
        }
    }

    private func row(_ issue: DeliveryCheck.Issue, fps: Double) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(issue.severity))
                .font(.system(size: 14))
                .foregroundStyle(color(issue.severity))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.system(size: 13))
                Text(issue.detail).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                if let word = issue.word {
                    Button("It’s spelled right") { learn(word) }
                        .buttonStyle(.plain)
                        .font(Design.Studio.hint)
                        .foregroundStyle(Design.Brand.pink)
                        .padding(.top, 4)
                        .help("Pluck remembers “\(word)” and won’t mark it again")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let time = issue.time {
                Text(DeliveryCheck.timecode(time, fps: fps))
                    .font(Design.Studio.hint.monospacedDigit())
                    .foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .studioBox(outline: selected == issue.id ? Design.rgb(0x8E4C64) : nil)
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
            RoundedRectangle(cornerRadius: 3)
                .stroke(Design.rgb(0xE6C34A), lineWidth: 2)
                .frame(width: box.width * size.width + 8, height: box.height * size.height + 8)
                .position(x: box.midX * size.width, y: (1 - box.midY) * size.height)
        }
        .allowsHitTesting(false)
    }

    private var selectedIssue: DeliveryCheck.Issue? { report?.issues.first { $0.id == selected } }

    private func icon(_ severity: DeliveryCheck.Issue.Severity) -> String {
        switch severity {
        case .problem: "xmark.octagon"
        case .warning: "exclamationmark.triangle"
        case .note: "info.circle"
        }
    }

    private func color(_ severity: DeliveryCheck.Issue.Severity) -> Color {
        switch severity {
        case .problem: Design.Studio.bad
        case .warning: Design.Studio.warn
        case .note: Design.Studio.textQuiet
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

/// The picture, without the player's own controls (the scrub row below is the control).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Play, the time, a thin track with a tick at each issue's moment, and the length.
private struct ScrubRow: View {
    let player: AVPlayer
    let duration: Double
    let ticks: [(Double, Color)]
    @State private var time = 0.0
    @State private var playing = false
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if playing { player.pause() } else { player.play() }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play")
            Text(Self.clock(time)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    StudioProgress(share: duration > 0 ? time / duration : 0)
                    ForEach(ticks.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1).fill(ticks[index].1)
                            .frame(width: 2, height: 12)
                            .offset(x: duration > 0 ? width * min(ticks[index].0 / duration, 1) - 1 : 0)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard duration > 0 else { return }
                    let seconds = min(max(drag.location.x / max(width, 1), 0), 1) * duration
                    time = seconds
                    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                })
            }
            .frame(height: 16)
            Text(Self.clock(duration)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
        }
        .onAppear {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { now in
                MainActor.assumeIsolated {
                    time = now.seconds.isFinite ? now.seconds : 0
                    playing = player.rate != 0
                }
            }
        }
        .onDisappear {
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
