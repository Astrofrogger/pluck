import SwiftUI

/// Offload's page: a card (or folder) to one or more drives, and every offload so far with how
/// far it is. A drive that disconnects only pauses one; it carries on when it's back.
struct OffloadView: View {
    @AppStorage("offloadRoots") private var rootsText = ""
    @AppStorage("offloadEject") private var eject = false
    /// Into a new folder in each place (named below), or straight into the places chosen.
    @AppStorage("offloadNewFolder") private var newFolder = true
    /// Only the clips (and what the camera wrote beside them).
    @AppStorage("offloadOnlyVideo") private var onlyVideo = false
    /// Started by itself when a camera card goes in (see OffloadCenter).
    @AppStorage(OffloadCenter.autoKey) private var automatic = false
    /// What would be copied, and how much of it is already on every drive chosen.
    @State private var already: (count: Int, bytes: Int64)?
    @State private var droppingFrom = false
    @State private var droppingTo = false
    @State private var center = OffloadCenter.shared
    @State private var cards: [URL] = []
    @State private var source: URL?
    @State private var found: (count: Int, bytes: Int64)?
    private var planKey: String { [source?.path ?? "", "\(onlyVideo)", rootsText, "\(newFolder)", name].joined(separator: "|") }
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
        .task(id: planKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await plan()
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
            // The card on the left, the drives on the right: click or drop on either side, and
            // what's to know about each under it.
            HStack {
                Spacer()
                Toggle(isOn: $automatic) { Text("Start when a card goes in") }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Offloads a camera card like this by itself as soon as it goes in, wherever you are in Pluck")
            }
            .padding(.bottom, -18)
            HStack(alignment: .top, spacing: 12) {
                fromSide.frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 44)
                toSide.frame(maxWidth: .infinity)
            }
            HStack(spacing: Design.Spacing.controls) {
                if let problem { ProblemLabel(text: problem) }
                Spacer()
                Menu {
                    Button("Check a Copy…", systemImage: "checkmark.shield") { pickCheck() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Check a copy against its MHL, before a card is formatted or months later")
                Button(action: start) { Label(actionTitle, systemImage: "arrow.down.doc") }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(!canStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: From and to

    private var fromSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            sideTitle("From")
            ForEach(cards, id: \.self) { card in
                tile(selected: source == card, symbol: "sdcard", title: OffloadCenter.volumeName(card),
                     detail: source == card ? planText : Self.usedText(card)) { choose(card) }
            }
            // A folder chosen (not a card plugged in).
            if let source, !cards.contains(source) {
                tile(selected: true, symbol: "folder", title: source.lastPathComponent, detail: planText) {}
                    .help(source.path)
            }
            addTile(source == nil && cards.isEmpty ? "Choose a card or folder…" : "Folder…", symbol: "folder") { pickSource() }
            VStack(alignment: .leading, spacing: 6) {
                Self.check("Only video files", $onlyVideo)
                    .help("Only the clips, with the sound and files the camera wrote beside each one (XML, RED and BRAW sidecars); no photos or other files")
                Self.check("Eject when done", $eject)
                    .help("Ejects the card when it’s no longer needed")
            }
            .padding(.top, 4)
        }
        .dropZone(targeted: $droppingFrom) { urls in
            guard let folder = urls.first(where: Self.isFolder) else { return false }
            choose(folder)
            return true
        }
    }

    private var toSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            sideTitle("To")
            ForEach(roots, id: \.self) { root in
                DriveTile(root: root, needed: neededBytes) { removeRoot(root) }
            }
            if roots.count < 4 {
                addTile(roots.isEmpty ? "Choose a drive…" : "Add a drive…", symbol: "plus") { addRoot() }
            }
            HStack(spacing: 8) {
                Self.check("In a new folder", $newFolder)
                    .help("On: each drive gets a new folder with this name, the card’s files in it. Off: only the card’s contents go, straight into the places chosen.")
                if newFolder {
                    TextField("Folder", text: $name).textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 4)
        }
        .dropZone(targeted: $droppingTo) { urls in
            let folders = urls.filter(Self.isFolder)
            guard !folders.isEmpty else { return false }
            for folder in folders { add(root: folder) }
            return true
        }
    }

    private func sideTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func tile(selected: Bool, symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).frame(width: 26)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(0.04)),
                        in: .rect(cornerRadius: Design.Radius.box))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func addTile(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.quaternary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: What will happen

    /// What the chosen card holds for this offload, and how much of it is already there.
    private var planText: String {
        guard let found else { return String(localized: "Looking…") }
        let size = ByteCountFormatter.string(fromByteCount: found.bytes, countStyle: .file)
        var text = String(AttributedString(localized: "^[\(found.count) file](inflect: true), \(size)").characters)
        if let already, already.count > 0 { text += " · " + String(localized: "\(already.count) already there") }
        return text
    }

    /// Bytes still to copy onto each drive.
    private var neededBytes: Int64? {
        guard let found else { return nil }
        return found.bytes - (already?.bytes ?? 0)
    }

    private var remaining: Int? { found.map { $0.count - (already?.count ?? 0) } }

    private var canStart: Bool {
        source != nil && !roots.isEmpty && !starting && (!newFolder || !name.trimmingCharacters(in: .whitespaces).isEmpty)
            && (remaining ?? 1) > 0
    }

    /// The button says what it'll do.
    private var actionTitle: String {
        if source == nil { return String(localized: "Choose a Card") }
        if roots.isEmpty { return String(localized: "Choose a Drive") }
        if remaining == 0 { return String(localized: "Nothing New to Copy") }
        guard let bytes = neededBytes else { return String(localized: "Offload") }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return roots.count == 1 ? String(localized: "Offload \(size)") : String(localized: "Offload \(size) to \(roots.count) Drives")
    }

    /// How full a card is, for one not chosen yet.
    private static func usedText(_ volume: URL) -> String {
        guard let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey]), let total = values.volumeTotalCapacity,
              let free = OffloadCenter.freeSpace(volume) else { return "" }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(total) - free, countStyle: .file)) used")
    }

    private func free(_ root: URL) -> String {
        guard let bytes = OffloadCenter.freeSpace(root) else { return "" }
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
        name = OffloadCenter.suggestedName(for: url)
    }

    /// What the offload would copy, worked out again when anything it depends on changes.
    private func plan() async {
        guard let source else { found = nil; already = nil; return }
        let onlyVideo = onlyVideo, targets = roots.map { newFolder ? $0.appendingPathComponent(name).path : $0.path }
        found = nil
        already = nil
        let (list, there) = await Task.detached(priority: .userInitiated) {
            let list = OffloadCenter.files(in: source, onlyVideo: onlyVideo)
            return (list, targets.isEmpty ? [] : OffloadCenter.alreadyThere(list, in: targets))
        }.value
        guard !Task.isCancelled else { return }
        found = (list.count, list.reduce(0) { $0 + $1.size })
        let skipped = list.indices.filter { there.indices.contains($0) && !there[$0].contains(false) }
        already = (skipped.count, skipped.reduce(0) { $0 + list[$1].size })
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(root: url)
    }

    private func add(root url: URL) {
        guard !roots.contains(url), roots.count < 4, url != source else { return }
        rootsText = (roots + [url]).map(\.path).joined(separator: "\n")
        refreshCards()
    }

    /// A checkbox and its words (clicking them ticks it too).
    private static func check(_ title: LocalizedStringKey, _ on: Binding<Bool>) -> some View {
        Toggle(title, isOn: on).toggleStyle(.checkbox).font(.callout)
    }

    private static func isFolder(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
        let folder = newFolder ? name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-") : ""
        Task {
            problem = await center.add(source: source, roots: targets, name: folder, eject: eject, onlyVideo: onlyVideo)
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
            CardHeader(symbol: job.quick == true ? "doc.on.doc" : "externaldrive.badge.checkmark", title: Text(job.displayName),
                       subtitle: Text("\(job.sourceVolume) → \(job.rootVolumes.formatted(.list(type: .and)))"
                                      + ((job.skipped ?? 0) > 0 ? " · " + String(localized: "\(job.skipped ?? 0) already there") : "")),
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
                    let skipped = job.skipped ?? 0
                    Label(skipped > 0
                          ? String(localized: "\(job.files.count - job.problems.count - skipped) copied and checked, \(skipped) already there")
                          : String(AttributedString(localized: "^[\(job.files.count - job.problems.count) file](inflect: true) checked on every drive").characters),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    // Every file on every drive and checked: the card can be formatted.
                    if job.problems.isEmpty, job.quick != true, job.partial != true {
                        Label("Safe to Format", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.green.opacity(0.18), in: .capsule)
                            .foregroundStyle(.green)
                            .help("Every file of the card is on \(job.roots.count == 1 ? String(localized: "the drive") : String(localized: "every drive")) and checked against it")
                    }
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

private extension View {
    /// A part of the page that takes dropped folders, lit while they're over it.
    func dropZone(targeted: Binding<Bool>, perform: @escaping ([URL]) -> Bool) -> some View {
        self
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targeted.wrappedValue ? 1 : 0))
            .contentShape(.rect)
            .dropDestination(for: URL.self) { urls, _ in perform(urls) } isTargeted: { targeted.wrappedValue = $0 }
            .padding(-6)
    }
}

/// A drive the offload goes to: its name, the folder on it, and its room (orange when this
/// offload won't fit).
private struct DriveTile: View {
    let root: URL
    let needed: Int64?
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let free = OffloadCenter.freeSpace(root)
        let total = (try? root.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).flatMap { $0 }.map(Int64.init)
        let tight = (needed ?? 0) > 0 && free.map { $0 < needed! } == true
        HStack(spacing: 10) {
            Image(systemName: root.path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive")
                .font(.title3).frame(width: 26).foregroundStyle(tight ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(OffloadCenter.volumeName(root)).fontWeight(.semibold).lineLimit(1)
                    if root.lastPathComponent != OffloadCenter.volumeName(root) {
                        Text(root.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let free, let total, total > 0 {
                    ProgressView(value: Double(total - free), total: Double(total))
                        .progressViewStyle(.linear)
                        .tint(tight ? .orange : .accentColor)
                        .controlSize(.mini)
                }
                Text(tight ? String(localized: "Not enough room") : free.map { String(localized: "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free") } ?? "")
                    .font(.caption).foregroundStyle(tight ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: Design.Radius.box))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(tight ? Color.orange : .clear, lineWidth: 1.5))
        .onHover { hovering = $0 }
        .help(root.path)
    }
}
