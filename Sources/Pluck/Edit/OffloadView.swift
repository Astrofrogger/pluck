import SwiftUI

/// Offload's page: a card (or folder) to one or more drives, and every offload so far with how
/// far it is. A drive that disconnects only pauses one; it carries on when it's back.
struct OffloadView: View {
    @AppStorage("offloadRoots") private var rootsText = ""
    @AppStorage("offloadCascade") private var cascade = true
    @AppStorage("offloadEject") private var eject = false
    @State private var center = OffloadCenter.shared
    @State private var cards: [URL] = []
    @State private var source: URL?
    @State private var found: (count: Int, bytes: Int64)?
    @State private var name = ""
    @State private var problem: String?
    /// For screenshots: these instead of the cards plugged in.
    @MainActor static var cardsShown: [URL]?
    /// A card to offload, chosen elsewhere (the Library's Locations).
    @MainActor static var startSource: URL?
    @State private var starting = false
    @State private var dropping = false

    private var roots: [URL] {
        rootsText.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    var body: some View {
        ToolPage {
            if center.jobs.isEmpty {
                ToolWelcome(symbol: "externaldrive.badge.checkmark", title: Text("Offload"),
                            subtitle: Text("Copy a card to several drives at once, every file checked. If a drive disconnects, it carries on when it’s back."))
            }
            setup
            ForEach(center.checks) { check in CheckRow(check: check) }
            if !center.jobs.isEmpty {
                ForEach(center.jobs) { job in OffloadRow(job: job) }
            }
            PageNote(text: Text("Every copy is read back and checked with xxHash64."), symbol: "checkmark.shield",
                     detail: Text("A report (MHL) is saved with each copy, for DaVinci Resolve, Silverstack and OffShoot."))
        }
        .frame(minWidth: 640, minHeight: 520)
        .task {
            if let start = Self.startSource { Self.startSource = nil; choose(start) }
            refreshCards()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshCards() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshCards() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                if let url = await providers.first?.load(URL.self), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    choose(url)
                }
            }
            return true
        }
    }

    // MARK: - A new offload

    private var setup: some View {
        Card {
            CardField(label: Text("From")) {
                HStack(spacing: 8) {
                    ForEach(cards, id: \.self) { card in
                        Button { choose(card) } label: {
                            Label(OffloadCenter.volumeName(card), systemImage: "sdcard").lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(source == card ? .accentColor : nil)
                    }
                    Button("Choose…", systemImage: "folder") { pickSource() }
                }
            }
            if let source {
                HStack(spacing: 6) {
                    Text(source.path).lineLimit(1).truncationMode(.middle)
                    if let found {
                        Text(verbatim: "·")
                        Text("^[\(found.count) file](inflect: true), \(ByteCountFormatter.string(fromByteCount: found.bytes, countStyle: .file))")
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Divider()
            CardField(label: Text("To")) {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(roots, id: \.self) { root in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            Text(OffloadCenter.volumeName(root)).fontWeight(.medium)
                            Text(root.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(free(root)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Remove", systemImage: "xmark.circle.fill") { removeRoot(root) }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .help(root.path)
                    }
                    if roots.count < 4 {
                        Button(roots.isEmpty ? "Choose a Drive…" : "Add a Drive…", systemImage: "plus") { addRoot() }
                    }
                }
            }
            Divider()
            CardField(label: Text("Card")) {
                HStack(spacing: 14) {
                    if roots.count > 1 {
                        Toggle("Free it first", isOn: $cascade)
                            .help("Copies the card to the first drive, then that drive to the others, so the card can go back in the camera sooner")
                    }
                    Toggle("Eject when done", isOn: $eject)
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            CardField(label: Text("Folder")) {
                TextField("Folder", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            HStack {
                if let problem { ProblemLabel(text: problem) }
                Spacer()
                Button("Check a Copy…", systemImage: "checkmark.shield") { pickCheck() }
                    .help("Reads a copy back and compares it with its MHL, before a card is formatted or months later")
                Button("Offload", systemImage: "arrow.down.doc") { start() }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(source == nil || roots.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || starting)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func free(_ root: URL) -> String {
        guard let bytes = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return "" }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free")
    }

    private func refreshCards() {
        // Not the drives the copies go to.
        let targets = Set(roots.compactMap { (try? $0.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path })
        cards = (Self.cardsShown ?? OffloadCenter.cards()).filter { !targets.contains($0.standardizedFileURL.path) }
        if source == nil, let card = cards.first { choose(card) }
        if let source, !FileManager.default.fileExists(atPath: source.path) { self.source = nil; found = nil }
    }

    private func choose(_ url: URL) {
        source = url
        found = nil
        problem = nil
        name = Self.suggestedName(for: url)
        Task {
            let list = await Task.detached(priority: .userInitiated) { OffloadCenter.files(in: url) }.value
            guard source == url else { return }
            found = (list.count, list.reduce(0) { $0 + $1.size })
        }
    }

    /// The card's name with the day, as offload folders usually are ("2026-10-17 A001").
    private static func suggestedName(for url: URL) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return day.string(from: .now) + " " + OffloadCenter.volumeName(url)
    }

    private func pickCheck() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Check")
        panel.message = String(localized: "Choose the folder of a copy, with its MHL file.")
        if panel.runModal() == .OK, let url = panel.url { center.check(url) }
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url, !roots.contains(url) else { return }
        rootsText = (roots + [url]).map(\.path).joined(separator: "\n")
        refreshCards()
    }

    private func removeRoot(_ root: URL) {
        rootsText = roots.filter { $0 != root }.map(\.path).joined(separator: "\n")
        refreshCards()
    }

    private func start() {
        guard let source else { return }
        let targets = roots
        // Not into the card itself.
        if targets.contains(where: { $0.path.hasPrefix(source.path + "/") || $0 == source }) {
            problem = String(localized: "A copy can’t go onto the card it comes from.")
            return
        }
        starting = true
        problem = nil
        let folder = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        Task {
            problem = await center.add(source: source, roots: targets, name: folder, cascade: cascade, eject: eject)
            starting = false
        }
    }
}

/// One offload: where from and to, how far, and what's left to do.
private struct OffloadRow: View {
    let job: OffloadJob
    @State private var center = OffloadCenter.shared
    @State private var showProblems = false

    var body: some View {
        let state = center.state(job)
        let live = center.live[job.id]
        Card {
            CardHeader(symbol: "externaldrive.badge.checkmark", title: Text(job.name),
                       subtitle: Text("\(job.sourceVolume) → \(job.rootVolumes.formatted(.list(type: .and)))"),
                       tint: tint(state)) {
                buttons(state)
            }
            if state != .done {
                let done = live?.bytes ?? job.workDone
                ProgressView(value: Double(done), total: Double(max(job.work, 1)))
                if job.cascades, job.cardDone != nil {
                    Label("The card is done and can go back in the camera.", systemImage: "sdcard")
                        .font(.callout).foregroundStyle(.green)
                }
                HStack(spacing: 6) {
                    status(state, live: live)
                    Spacer()
                    if let live, live.speed > 0, state == .copying {
                        let left = Double(job.work - live.bytes) / live.speed
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(live.speed), countStyle: .file))/s · \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: Design.Spacing.controls) {
                    Label("^[\(job.files.count - job.problems.count) file](inflect: true) checked on every drive", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    if let finished = job.finished { Text(finished, style: .date).foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
            if !job.problems.isEmpty {
                DisclosureGroup(isExpanded: $showProblems) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems, id: \.path) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(file.problem ?? "").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                } label: {
                    ProblemLabel(text: String(AttributedString(localized: "^[\(job.problems.count) file](inflect: true) couldn’t be copied").characters))
                }
            }
        }
    }

    @ViewBuilder private func status(_ state: OffloadCenter.State, live: OffloadCenter.Live?) -> some View {
        switch state {
        case .copying:
            if let live, !live.file.isEmpty {
                Text(live.checking ? "Checking \(live.file)" : "Copying \(live.file)").lineLimit(1).truncationMode(.middle)
            } else {
                Text("Starting…")
            }
        case .queued: Text("Waiting for the offload before it")
        case .paused: Text("Paused")
        case .waiting(let drive):
            Label("Waiting for \(drive). Connect it again to carry on.", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .stopped(let problem): ProblemLabel(text: problem)
        case .done: EmptyView()
        }
    }

    @ViewBuilder private func buttons(_ state: OffloadCenter.State) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .copying, .queued:
                Button("Pause", systemImage: "pause.fill") { center.pause(job.id) }
            case .paused, .stopped, .waiting:
                Button("Resume", systemImage: "play.fill") { center.resume(job.id) }
            case .done:
                if !job.problems.isEmpty {
                    Button("Try Again", systemImage: "arrow.clockwise") { center.retryProblems(job.id) }
                        .help("Copies the files that couldn’t be copied once more")
                }
                if let report = OffloadReport.url(job) {
                    Button("Report", systemImage: "doc.richtext") { NSWorkspace.shared.open(report) }
                        .help("The PDF report")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(job.targets.map { URL(fileURLWithPath: $0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) })
                }
            }
            if state != .copying {
                Button("Remove from List", systemImage: "xmark") { center.remove(job.id) }
                    .help("Removes it from the list; the copies stay where they are")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private func tint(_ state: OffloadCenter.State) -> Color {
        switch state {
        case .done: job.problems.isEmpty ? .green : .orange
        case .waiting, .stopped: .orange
        default: .accentColor
        }
    }
}

/// A copy checked again against its MHL.
private struct CheckRow: View {
    let check: OffloadCheck
    @State private var center = OffloadCenter.shared
    @State private var showList = false

    var body: some View {
        Card {
            CardHeader(symbol: "checkmark.shield", title: Text(check.folder.lastPathComponent),
                       subtitle: Text(OffloadCenter.driveName(check.folder)), tint: tint) {
                Button("Remove from List", systemImage: "xmark") { center.removeCheck(check.id) }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            if let problem = check.problem {
                ProblemLabel(text: problem)
            } else if !check.finished {
                ProgressView(value: Double(check.done), total: Double(max(check.total, 1)))
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            } else if check.isGood {
                Label("^[\(check.matched) file](inflect: true) match the MHL", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProblemLabel(text: [check.changed.isEmpty ? nil : String(localized: "\(check.changed.count) changed"),
                                    check.missing.isEmpty ? nil : String(localized: "\(check.missing.count) missing"),
                                    String(localized: "\(check.matched) match")].compactMap { $0 }.joined(separator: ", "))
            }
            if check.finished, check.unchecked > 0 {
                Text("^[\(check.unchecked) file](inflect: true) with a checksum Pluck can’t read (xxh3, xxh128 or C4)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let listed = check.changed.map { ($0, String(localized: "Changed")) } + check.missing.map { ($0, String(localized: "Missing")) }
                + check.extra.map { ($0, String(localized: "Not in the MHL")) }
            if check.finished, !listed.isEmpty {
                DisclosureGroup(isExpanded: $showList) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(listed, id: \.0) { path, what in
                            HStack {
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(what).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                } label: {
                    Text("^[\(listed.count) file](inflect: true) to look at").font(.callout)
                }
            }
        }
    }

    private var tint: Color {
        guard check.finished else { return .accentColor }
        return check.isGood ? .green : .orange
    }
}
