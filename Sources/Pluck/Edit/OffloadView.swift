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
    @State private var projects = OffloadProjects.shared
    @State private var phone = OffloadPhone.shared
    @State private var showPhone = false
    /// The project being set up (a new one, or the one cards go into).
    @State private var editing: (project: OffloadProject, isNew: Bool)?
    @State private var cards: [URL] = []
    @State private var source: URL?
    @State private var found: (count: Int, bytes: Int64)?
    private var planKey: String {
        [source?.path ?? "", "\(onlyVideo)", rootsText, "\(newFolder)", name, project?.id.uuidString ?? ""].joined(separator: "|")
    }
    @State private var name = ""
    @State private var problem: String?
    /// For screenshots: these instead of the cards plugged in.
    @MainActor static var cardsShown: [URL]?
    /// A card to offload, chosen elsewhere (the Library's Locations).
    @MainActor static var startSource: URL?
    @State private var starting = false
    @State private var dropping = false

    /// Where copies go: the project's drives, or the drives chosen here.
    private var roots: [URL] {
        if let project { return project.drives.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        return rootsText.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    /// The project cards go into, if one is chosen.
    private var project: OffloadProject? { projects.current }

    var body: some View {
        // A new offload on the left, every offload so far on the right (layout board ToolOffload).
        HStack(spacing: Design.Studio.panelGap) {
            setup
                .frame(width: 400)
                .frame(maxHeight: .infinity)
                .studioPanel()
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel()
        }
        .foregroundStyle(Design.Studio.text)
        .frame(minWidth: 820, minHeight: 520)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { OffloadProjectSheet(project: editing.project, isNew: editing.isNew) }
        }
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

    // MARK: - The offloads so far

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Offloads").font(Design.Studio.sectionTitle)
                Text(verbatim: "\(center.jobs.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                if let project { OffloadWrapMenu(project: project) }
            }
            .padding(.bottom, 6)
            if center.jobs.isEmpty && center.checks.isEmpty && center.questions.isEmpty && center.backupQuestions.isEmpty {
                emptyList
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(center.questions) { question in OffloadQuestionCard(question: question) }
                        ForEach(center.backupQuestions) { question in OffloadBackupQuestionCard(question: question) }
                        ForEach(center.checks) { check in CheckRow(check: check) }
                        ForEach(center.jobs) { job in OffloadRow(job: job) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    /// No offloads yet: a dashed place to drop a card or folder.
    private var emptyList: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 22)).foregroundStyle(Design.Studio.textFaint)
            Text("Drop a card or folder").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
            Text("Copied to several drives at once, every file checked.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
                .strokeBorder(dropping ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Design.Studio.line),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .contentShape(.rect)
        .onTapGesture(perform: pickSource)
    }

    // MARK: - A new offload

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Offload").font(Design.Studio.pageTitle)
                Spacer()
                projectMenu
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StudioSwitchRow(title: "Start when a card goes in", isOn: $automatic)
                        .help("Offloads a camera card like this by itself as soon as it goes in, wherever you are in Pluck")
                    fromSide
                    toSide
                    VStack(alignment: .leading, spacing: 2) {
                        StudioSwitchRow(title: "Only video files", isOn: $onlyVideo)
                            .help("Only the clips, with the sound and files the camera wrote beside each one (XML, RED and BRAW sidecars); no photos or other files")
                        StudioSwitchRow(title: "Eject when done", isOn: $eject)
                            .help("Ejects the card when it’s no longer needed")
                        if project == nil {
                            HStack(spacing: 10) {
                                StudioSwitchRow(title: "In a new folder", isOn: $newFolder)
                                    .help("On: each drive gets a new folder with this name, the card’s files in it. Off: only the card’s contents go, straight into the places chosen.")
                                Spacer(minLength: 0)
                                if newFolder {
                                    TextField("Folder", text: $name)
                                        .textFieldStyle(.plain)
                                        .font(Design.Studio.body)
                                        .padding(.horizontal, 10)
                                        .frame(width: 150, height: 26)
                                        .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                                }
                            }
                        }
                    }
                    if let project { OffloadWrapStrip(project: project) }
                }
            }
            .scrollIndicators(.never)
            if let problem { OffloadNote(symbol: "exclamationmark.triangle", text: Text(problem), colour: Design.Studio.warn) }
            HStack(spacing: 6) {
                OffloadIconButton(symbol: phone.on ? "iphone.radiowaves.left.and.right" : "iphone", label: "Show on My Phone",
                                  colour: phone.on ? Design.Brand.pink : Design.Studio.textQuiet) { showPhone.toggle() }
                    .popover(isPresented: $showPhone, arrowEdge: .bottom) { OffloadPhoneView() }
                Menu {
                    Button("Check a Copy…", systemImage: "checkmark.shield") { pickCheck() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Check a copy against its MHL, before a card is formatted or months later")
                Button(action: start) {
                    Label(actionTitle, systemImage: "arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(!canStart)
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 6)
            }
            StudioFootnote(text: "Every copy is read back and checked", symbol: "checkmark.shield")
                .help("Every copy is read back and checked with xxHash64. A report (MHL) is saved with each copy, for DaVinci Resolve, Silverstack and OffShoot.")
        }
        .padding(24)
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
            StudioDashedButton(title: source == nil && cards.isEmpty ? "Choose a card or folder…" : "Folder…", symbol: "folder") { pickSource() }
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
                StudioDashedButton(title: roots.isEmpty ? "Choose a drive…" : "Add a drive…") { addRoot() }
            }
            if let project {
                Button { editing = (project, false) } label: {
                    Label(projectPath(project), systemImage: "folder.badge.person.crop")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Where cards go in this project. Click to change.")
                .padding(.top, 2)
            }
        }
        .dropZone(targeted: $droppingTo) { urls in
            let folders = urls.filter(Self.isFolder)
            guard !folders.isEmpty else { return false }
            for folder in folders { add(root: folder) }
            return true
        }
    }

    /// Choosing the project cards go into, or none (an offload to any folder).
    private var projectMenu: some View {
        Menu {
            Picker("Project", selection: Binding(get: { projects.active }, set: { projects.active = $0 })) {
                Text("No Project").tag(UUID?.none)
                ForEach(projects.projects) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Project…", systemImage: "plus") {
                var made = OffloadProject(name: String(localized: "New Project"))
                made.drives = rootsText.split(separator: "\n").map(String.init)
                made.operators = [.init(name: String(localized: "Operator A"), letter: "A")]
                editing = (made, true)
            }
            if let project {
                Button("Edit \(project.name)…", systemImage: "pencil") { editing = (project, false) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2").font(.system(size: 11))
                Text(project?.name ?? String(localized: "No project")).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Design.Studio.body)
            .foregroundStyle(project == nil ? Design.Studio.textQuiet : Design.Studio.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("A project knows who’s filming and files each card in their folder, under the next card number")
    }

    /// Where the next card of the last person goes ("Festival/2026-07-12/A_Operator A/A004/").
    private func projectPath(_ project: OffloadProject) -> String {
        guard let person = project.person(project.lastOperator) ?? project.operators.first else { return project.name }
        var shown = project
        shown.drives = []
        return OffloadProjectPlanner.plan(card: URL(fileURLWithPath: "/"), files: [], project: shown, operator: person, date: .now,
                                           firstOffload: project.firstOffload(in: center.jobs)).folder + "/"
    }

    private func sideTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
    }

    /// A card or folder to copy: plum outline and symbol when it's the one chosen.
    private func tile(selected: Bool, symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(selected ? Design.Brand.pink : Design.Studio.textQuiet)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioBox(outline: selected ? Design.rgb(0x8E4C64) : nil)
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
        if let project { return source != nil && !roots.isEmpty && !project.operators.isEmpty && !starting && (found?.count ?? 1) > 0 }
        return source != nil && !roots.isEmpty && !starting && (!newFolder || !name.trimmingCharacters(in: .whitespaces).isEmpty)
            && (remaining ?? 1) > 0
    }

    /// The button says what it'll do.
    private var actionTitle: String {
        if source == nil { return String(localized: "Choose a Card") }
        if roots.isEmpty { return String(localized: "Choose a Drive") }
        if remaining == 0 { return String(localized: "Nothing New to Copy") }
        guard let bytes = neededBytes else { return String(localized: "Offload") }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return roots.count == 1 ? String(localized: "Offload \(size)") : String(localized: "Offload \(size) to \(roots.count) drives")
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
        // (In a project, what's already there is worked out once the card's operator is known.)
        let onlyVideo = onlyVideo, targets = project != nil ? [] : roots.map { newFolder ? $0.appendingPathComponent(name).path : $0.path }
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
        if let project {
            projects.change(project.id) { $0.drives.append(url.path) }
            refreshCards()
            return
        }
        rootsText = (roots + [url]).map(\.path).joined(separator: "\n")
        refreshCards()
    }

    private static func isFolder(_ url: URL) -> Bool {
        url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func removeRoot(_ root: URL) {
        if let project {
            projects.change(project.id) { $0.drives.removeAll { $0 == root.path } }
            refreshCards()
            return
        }
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
        if let project {
            Task {
                problem = await center.offload(card: source, project: project.id, eject: eject, onlyVideo: onlyVideo)
                starting = false
            }
            return
        }
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
        let share = Double(live?.bytes ?? job.workDone) / Double(max(job.work, 1))
        VStack(alignment: .leading, spacing: 12) {
            OffloadBoxHeader(symbol: job.quick == true ? "doc.on.doc" : job.backup != nil ? "externaldrive.badge.timemachine" : "externaldrive",
                             tint: tint(state), title: Text(job.displayName), subtitle: Text(subtitle)) {
                if state == .copying || state == .paused || state == .queued {
                    Text(min(share, 1), format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 13).monospacedDigit())
                        .padding(.trailing, 6)
                }
                buttons(state)
            }
            if state != .done {
                if case .waiting = state {} else { StudioProgress(share: share) }
                if job.cascades, job.cardDone != nil, job.cardIsFree {
                    OffloadNote(symbol: "sdcard", text: Text("The card is done and can go back in the camera."), colour: Design.Studio.good)
                }
                status(state, live: live)
                if state == .copying, let history = center.speedLive[job.id] { OffloadSpeedLine(job: job, history: history) }
            } else {
                HStack(spacing: 10) {
                    // (A skipped file that then had a problem counts once, as a problem; older jobs only have the number.)
                    let skipped = job.files.contains { $0.skipped != nil } ? job.files.filter { $0.skipped == true && $0.problem == nil }.count
                        : min(job.skipped ?? 0, job.files.count - job.problems.count)
                    let there = skipped + (job.alreadyThere ?? 0)
                    OffloadNote(symbol: "checkmark",
                                text: Text(there > 0
                                           ? String(localized: "\(job.files.count - job.problems.count - skipped) copied and checked, \(there) already there")
                                           : String(AttributedString(localized: "^[\(job.files.count - job.problems.count) file](inflect: true) checked on every drive").characters)),
                                colour: Design.Studio.good, font: Design.Studio.body)
                    Text(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    // Every file on every drive and checked: the card can be formatted.
                    if job.problems.isEmpty, job.quick != true, job.partial != true, job.backup == nil {
                        StudioChip(text: Text("Safe to format"), symbol: "checkmark.seal", colour: Design.Studio.good, tinted: true)
                            .help("Every file of the card is on \(job.roots.count == 1 ? String(localized: "the drive") : String(localized: "every drive")) and checked against it")
                    }
                    if let finished = job.finished {
                        Text(finished.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(Design.Studio.textQuiet)
                            .help(Text(finished, style: .date))
                    }
                }
                .font(Design.Studio.body)
                if job.quick != true, job.backup == nil { OffloadClipGrid(job: job) }
            }
            if !job.problems.isEmpty {
                OffloadFold(isOpen: $showProblems,
                            label: Text(AttributedString(localized: "^[\(job.problems.count) file](inflect: true) couldn’t be copied")),
                            symbol: "exclamationmark.triangle", colour: Design.Studio.warn) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems, id: \.path) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(file.problem ?? "").foregroundStyle(Design.Studio.textQuiet)
                            }
                            .font(Design.Studio.hint)
                        }
                    }
                }
            }
        }
        .padding(16)
        .studioBox()
    }

    private var subtitle: String {
        "\(job.sourceVolume) → \(job.rootVolumes.joined(separator: ", "))"
            + ((job.skipped ?? 0) > 0 ? " · " + String(localized: "\(job.skipped ?? 0) already there") : "")
            + ((job.alreadyThere ?? 0) > 0 ? " · " + String(localized: "\(job.files.count) new clips · \(job.alreadyThere ?? 0) already there") : "")
    }

    @ViewBuilder private func status(_ state: OffloadCenter.State, live: OffloadCenter.Live?) -> some View {
        switch state {
        case .waiting(let drive):
            OffloadNote(symbol: "externaldrive.badge.exclamationmark", text: Text("Waiting for \(drive). Connect it again to carry on."),
                        colour: Design.Studio.warn)
        case .stopped(let problem):
            OffloadNote(symbol: "exclamationmark.triangle", text: Text(problem), colour: Design.Studio.warn)
        case .done:
            EmptyView()
        default:
            HStack(spacing: 6) {
                switch state {
                case .copying:
                    if let live, !live.file.isEmpty {
                        Text(live.checking ? "Checking \(live.file)" : "Copying \(live.file)").lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Starting…")
                    }
                case .queued: Text("Waiting for the offload before it")
                default: Text("Paused")
                }
                Spacer()
                if let live, live.speed > 0, state == .copying {
                    let left = Double(job.work - live.bytes) / live.speed
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(live.speed), countStyle: .file))/s · \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                }
            }
            .font(Design.Studio.hint.monospacedDigit())
            .foregroundStyle(Design.Studio.textQuiet)
        }
    }

    @ViewBuilder private func buttons(_ state: OffloadCenter.State) -> some View {
        HStack(spacing: 2) {
            switch state {
            case .copying, .queued:
                OffloadIconButton(symbol: "pause.fill", label: "Pause") { center.pause(job.id) }
            case .paused, .stopped, .waiting:
                OffloadIconButton(symbol: "play.fill", label: "Resume") { center.resume(job.id) }
            case .done:
                if !job.problems.isEmpty {
                    OffloadIconButton(symbol: "arrow.clockwise", label: "Try Again", help: "Copies the files that couldn’t be copied once more") {
                        center.retryProblems(job.id)
                    }
                }
                if let report = OffloadReport.url(job) {
                    OffloadIconButton(symbol: "doc.text", label: "Report", help: "The PDF report") { NSWorkspace.shared.open(report) }
                }
                OffloadIconButton(symbol: "folder", label: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(job.targets.map { URL(fileURLWithPath: $0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) })
                }
            }
            if state != .copying {
                OffloadIconButton(symbol: "xmark", label: "Remove from List", help: "Removes it from the list; the copies stay where they are") {
                    center.remove(job.id)
                }
            }
        }
    }

    private func tint(_ state: OffloadCenter.State) -> Color {
        switch state {
        case .done: job.problems.isEmpty ? Design.Studio.good : Design.Studio.warn
        case .waiting, .stopped: Design.Studio.warn
        case .paused, .queued: Design.Studio.textQuiet
        default: Design.Studio.text
        }
    }
}

/// A copy checked again against its MHL.
private struct CheckRow: View {
    let check: OffloadCheck
    @State private var center = OffloadCenter.shared
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OffloadBoxHeader(symbol: "checkmark.shield", tint: tint, title: Text(check.folder.lastPathComponent),
                             subtitle: Text(OffloadCenter.driveName(check.folder))) {
                OffloadIconButton(symbol: "xmark", label: "Remove from List") { center.removeCheck(check.id) }
            }
            if let problem = check.problem {
                OffloadNote(symbol: "exclamationmark.triangle", text: Text(problem), colour: Design.Studio.warn)
            } else if !check.finished {
                StudioProgress(share: Double(check.done) / Double(max(check.total, 1)))
                Text("Checking…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            } else if check.isGood {
                OffloadNote(symbol: "checkmark", text: Text("^[\(check.matched) file](inflect: true) match the MHL"),
                            colour: Design.Studio.good, font: Design.Studio.body)
            } else {
                OffloadNote(symbol: "exclamationmark.triangle",
                            text: Text([check.changed.isEmpty ? nil : String(localized: "\(check.changed.count) changed"),
                                        check.missing.isEmpty ? nil : String(localized: "\(check.missing.count) missing"),
                                        String(localized: "\(check.matched) match")].compactMap { $0 }.joined(separator: ", ")),
                            colour: Design.Studio.warn, font: Design.Studio.body)
            }
            if check.finished, check.unchecked > 0 {
                Text("^[\(check.unchecked) file](inflect: true) with a checksum Pluck can’t read (xxh3, xxh128 or C4)")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            let listed = check.changed.map { ($0, String(localized: "Changed")) } + check.missing.map { ($0, String(localized: "Missing")) }
                + check.extra.map { ($0, String(localized: "Not in the MHL")) }
            if check.finished, !listed.isEmpty {
                OffloadFold(isOpen: $showList, label: Text("^[\(listed.count) file](inflect: true) to look at")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(listed, id: \.0) { path, what in
                            HStack {
                                Text(path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(what).foregroundStyle(Design.Studio.textQuiet)
                            }
                            .font(Design.Studio.hint)
                        }
                    }
                }
            }
        }
        .padding(16)
        .studioBox()
    }

    private var tint: Color {
        guard check.finished else { return Design.Studio.text }
        return check.isGood ? Design.Studio.good : Design.Studio.warn
    }
}

private extension View {
    /// A part of the page that takes dropped folders, lit while they're over it.
    func dropZone(targeted: Binding<Bool>, perform: @escaping ([URL]) -> Bool) -> some View {
        self
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
                .strokeBorder(Design.Brand.gradient, lineWidth: 1)
                .opacity(targeted.wrappedValue ? 1 : 0))
            .contentShape(.rect)
            .dropDestination(for: URL.self) { urls, _ in perform(urls) } isTargeted: { targeted.wrappedValue = $0 }
            .padding(-6)
    }
}

/// A drive the offload goes to: its name, the folder on it, its free space and how full it is
/// (in the warning colour when this offload won't fit).
private struct DriveTile: View {
    let root: URL
    let needed: Int64?
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let free = OffloadCenter.freeSpace(root)
        let total = (try? root.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).flatMap { $0 }.map(Int64.init)
        let tight = (needed ?? 0) > 0 && free.map { $0 < needed! } == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: root.path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive")
                    .font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(tight ? Design.Studio.warn : Design.Studio.textQuiet)
                HStack(spacing: 4) {
                    Text(OffloadCenter.volumeName(root)).font(Design.Studio.body.weight(.medium)).lineLimit(1)
                    if root.lastPathComponent != OffloadCenter.volumeName(root) {
                        Text(root.lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if hovering {
                    Button("Remove", systemImage: "xmark", action: remove)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
                } else {
                    Text(tight ? String(localized: "Not enough room") : free.map { String(localized: "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free") } ?? "")
                        .font(Design.Studio.hint).foregroundStyle(tight ? Design.Studio.warn : Design.Studio.textQuiet)
                }
            }
            if let free, let total, total > 0 {
                Capsule().fill(Design.Studio.line).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(tight ? Design.Studio.warn : Design.Studio.textFaint)
                                .frame(width: geometry.size.width * CGFloat(total - free) / CGFloat(total), height: 3)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .studioBox(outline: tight ? Design.Studio.warn : nil)
        .onHover { hovering = $0 }
        .help(root.path)
    }
}

// MARK: - Pieces the offload boxes share (here and in the other Offload view files)

/// A 28 pt quiet icon button, as in the boxes' corners.
struct OffloadIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var help: LocalizedStringKey?
    var colour = Design.Studio.textQuiet
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(colour)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(help ?? label))
        .accessibilityLabel(Text(label))
    }
}

/// A box's first line: a 40 pt tile with the symbol in the state's colour, a name and a line, then its buttons.
struct OffloadBoxHeader<Accessory: View>: View {
    let symbol: String
    var tint = Design.Studio.text
    let title: Text
    let subtitle: Text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            StudioTile(symbol: symbol, colour: tint)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13)).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                subtitle.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

/// A coloured line with its symbol: a warning, a check.
struct OffloadNote: View {
    let symbol: String
    let text: Text
    let colour: Color
    var font = Design.Studio.hint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            text.fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .foregroundStyle(colour)
    }
}

/// "42 clips ⌄": a quiet line that opens what's under it.
struct OffloadFold<Content: View>: View {
    @Binding var isOpen: Bool
    let label: Text
    var symbol: String?
    var colour = Design.Studio.textQuiet
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.smooth(duration: 0.2)) { isOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                    label
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .font(Design.Studio.body)
                .foregroundStyle(colour)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen { content }
        }
    }
}
