import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Delivery Check's window: drop one or more finished exports, pick the spec they're going out
/// to, and go through what it found, each one shown in the player at its moment.
struct DeliveryCheckView: View {
    /// A video to check as soon as the window opens (screenshots).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckDeliveryCheckOpen")

    /// Sends a finished file to Delivery Check in Tools (from the Editor).
    @MainActor static func check(_ url: URL) {
        openFile = url
        StudioNavigator.shared.open(windowID: "deliveryCheck")
        NotificationCenter.default.post(name: openNotification, object: url)
    }

    /// Sends a finished file to Delivery Check in Deliver (it joins the queue).
    @MainActor static func check(_ url: URL, nav: StudioNavigator) {
        openFile = url
        nav.deliver = .deliveryCheck
        NotificationCenter.default.post(name: openNotification, object: url)
    }
    @Environment(DownloadManager.self) private var manager
    /// The spec's id (the destinations' raw values are the presets' ids, so older choices carry over).
    @AppStorage("deliveryCheckDestination") private var specID = DeliveryCheck.Destination.online.rawValue
    /// The client's brand profile checked along (logo placement, colours, texts), if any.
    @AppStorage("deliveryCheckBrand") private var brandID = ""
    /// A brand that names a delivery spec sets it.
    private var brand: Binding<UUID?> {
        Binding(get: { UUID(uuidString: brandID) }, set: {
            brandID = $0?.uuidString ?? ""
            if let id = DeliveryCheck.specID(matching: BrandProfiles.shared.profile($0)?.deliverySpec) { specID = id }
        })
    }
    /// The queue lives in the store: it goes on when this page is left.
    private let store = DeliveryCheckStore.shared
    private var items: [Item] { get { store.items } nonmutating set { store.items = newValue } }
    private var current: Item.ID? { get { store.current } nonmutating set { store.current = newValue } }
    private var running: Task<Void, Never>? { store.running }
    private var progress: Double { store.progress }
    private var stage: String { store.stage }
    private var problem: String? { get { store.problem } nonmutating set { store.problem = newValue } }
    @State private var selected: DeliveryCheck.Issue.ID?
    @State private var player = AVPlayer()
    /// What the player has loaded.
    @State private var shown: Item.ID?
    @State private var dropping = false
    @State private var filter: DeliveryCheck.Issue.Severity?
    @State private var showHidden = false
    @State private var showTransitions = false
    @State private var intended: Set<String> = []
    @State private var thumbnails: [Double: CGImage] = [:]
    @State private var editingSpec: DeliveryCheck.Spec?
    @State private var specs = DeliveryCheck.specs

    typealias Item = DeliveryCheckStore.Item

    /// The queue's spec; a file can have its own.
    private var spec: DeliveryCheck.Spec { specs.first { $0.id == specID } ?? DeliveryCheck.Destination.online.spec }
    private var item: Item? { items.first { $0.id == current } }
    private var report: DeliveryCheck.Report? { item?.report }

    var body: some View {
        VStack(spacing: Design.Studio.panelGap) {
            bar
            if items.count > 1 { queue }
            if let report, running == nil {
                HStack(spacing: Design.Studio.panelGap) {
                    playerPanel(report)
                    resultsPanel(report)
                }
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    if running != nil { checking } else { dropZone }
                    if let problem = problem ?? item?.failed {
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
        .frame(minWidth: 760)
        .onAppear {
            if let url = Self.openFile {
                Self.openFile = nil
                open([url], append: true)
            } else if current != nil {
                show(current)
            }
        }
        .onChange(of: store.revision) {
            intended = report.map { DeliveryCheck.intended($0.fileKey) } ?? []
            if selected == nil, let first = report?.issues.first { pick(first) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; open([url], append: true) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers { if let url = await provider.load(URL.self), Converting.isVideo(url) { urls.append(url) } }
                if !urls.isEmpty { open(urls) }
            }
            return true
        }
        .sheet(item: $editingSpec) { spec in
            DeliveryCheckSpecSheet(spec: spec) { id in
                specs = DeliveryCheck.specs
                specID = id ?? DeliveryCheck.Destination.online.rawValue
            }
        }
        .task(id: report.map { "\($0.file.path)|\($0.issues.count)" }) { await loadThumbnails() }
    }

    /// The video, the spec it's checked against, and the main action, in one 48 pt field (board ToolDelivery).
    private var bar: some View {
        HStack(spacing: 12) {
            Image(systemName: items.count > 1 ? "film.stack" : "film").font(.system(size: 14)).foregroundStyle(Design.Studio.textQuiet)
            Group {
                if items.count > 1 {
                    Text("^[\(items.count) video](inflect: true)").foregroundStyle(Design.Studio.text)
                } else if let item {
                    Text(item.file.lastPathComponent).foregroundStyle(Design.Studio.text)
                } else {
                    Text("Drop finished videos, or choose them").foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            BrandProfilePicker(selection: brand)
            Menu {
                Picker("Spec", selection: $specID) {
                    ForEach(specs) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Button(spec.builtIn ? "New Spec from This…" : "Edit Spec…") { editingSpec = spec }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane").font(.system(size: 11))
                    Text(spec.shortTitle)
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
            .help("Spec")
            Rectangle().fill(Design.Studio.line).frame(width: 1, height: 18)
            Button { choose() } label: {
                Text(items.isEmpty ? "Choose Videos…" : "Choose…")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(running != nil)
            Button { check(all: true) } label: {
                Label(items.contains { $0.report != nil } ? "Check again" : "Check", systemImage: "checkmark.seal")
            }
            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            .disabled(items.isEmpty || running != nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: Design.Studio.line)
        .studioToolTitle("Delivery Check")
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .studioPanel()
    }

    /// Each file in the queue with what was found in it; click one to see it.
    private var queue: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let counts = item.report.map { counts($0) }
                    Button { show(item.id) } label: {
                        HStack(spacing: 8) {
                            if item.report == nil, item.failed == nil {
                                Image(systemName: "clock").foregroundStyle(Design.Studio.textFaint)
                            } else if let counts {
                                Image(systemName: counts.problems > 0 ? "xmark.octagon" : counts.warnings > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                                    .foregroundStyle(counts.problems > 0 ? Design.Studio.bad : counts.warnings > 0 ? Design.Studio.warn : Design.Studio.good)
                            } else {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Design.Studio.bad)
                            }
                            Text(item.file.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                            if let own = item.specID {
                                Text(DeliveryCheck.spec(id: own).shortTitle).foregroundStyle(Design.Studio.textQuiet)
                            }
                            if let counts, counts.problems + counts.warnings > 0 {
                                Text(verbatim: "\(counts.problems) · \(counts.warnings)").monospacedDigit().foregroundStyle(Design.Studio.textQuiet)
                            }
                        }
                        .font(Design.Studio.body)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .studioBox(outline: item.id == current ? Design.rgb(0x8E4C64) : nil)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Picker("Spec", selection: Binding(get: { item.specID }, set: { store.setSpec($0, for: item.id, manager: manager) })) {
                            Text("Same as queue").tag(String?.none)
                            ForEach(specs) { Text($0.title).tag(String?.some($0.id)) }
                        }
                        .pickerStyle(.inline)
                    }
                    .help(item.file.path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .studioPanel()
    }

    private var dropZone: some View {
        StudioEmptyState(symbol: "checkmark.seal", title: "Drop finished videos",
                         line: "Pluck looks for flash frames, dropouts, loudness, typos and the wrong size before it goes out.",
                         targeted: dropping, button: "Choose Videos…") { choose() }
            .studioDropZone(targeted: dropping)
            .onTapGesture { choose() }
    }

    private var checking: some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "checkmark.seal")
            VStack(alignment: .leading, spacing: 6) {
                Text(item?.file.lastPathComponent ?? "").font(.system(size: 13)).lineLimit(1)
                Text(stage).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                StudioProgress(share: progress)
            }
            Button("Stop", systemImage: "stop.fill") { store.running?.cancel() } // (the task clears `running` once its ffmpeg has stopped)
                .buttonStyle(StudioFlatButtonStyle())
                .help("Stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .studioBox()
    }

    // MARK: - Results

    /// The picture at 400 pt high, its scrub row with every finding on it, and the file's facts.
    private func playerPanel(_ report: DeliveryCheck.Report) -> some View {
        let aspect = report.size.height > 0 ? report.size.width / report.size.height : 16 / 9
        let marked = visible(report, filtered: false).filter { $0.time != nil }
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
                             ticks: marked.map { ($0.time ?? 0, color($0.severity)) },
                             onTick: { index in pick(marked[index]) })
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
                    if let approved = item?.approved {
                        HStack(spacing: 0) {
                            Text("Approved").foregroundStyle(Design.Studio.textQuiet).frame(width: 110, alignment: .leading)
                            Text(approved.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(Design.Studio.body)
                        .frame(height: 30)
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
        let shown = visible(report, filtered: true)
        let transitions = shown.filter { $0.kind == .transition }
        let hidden = report.issues.filter { intended.contains($0.key) }.count
        return VStack(alignment: .leading, spacing: 10) {
            summary(report).padding(.horizontal, 4)
            HStack(spacing: 8) {
                StudioSegmented(options: [(nil, "All"), (.problem, "Problems"), (.warning, "To check"), (.note, "Notes")], selection: $filter)
                Spacer(minLength: 0)
                if hidden > 0 {
                    Button { showHidden.toggle() } label: {
                        Label(showHidden ? "Hide intended" : "Show \(hidden) hidden", systemImage: showHidden ? "eye.slash" : "eye")
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(shown.filter { $0.kind != .transition }) { issue in
                        row(issue, fps: report.fps)
                    }
                    if !transitions.isEmpty {
                        transitionGroup(transitions, fps: report.fps)
                    }
                }
                .padding(1)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .studioPanel()
    }

    private func counts(_ report: DeliveryCheck.Report) -> (problems: Int, warnings: Int) {
        let marks = DeliveryCheck.intended(report.fileKey)
        let open = report.issues.filter { !marks.contains($0.key) }
        return (open.filter { $0.severity == .problem }.count, open.filter { $0.severity == .warning }.count)
    }

    private func summary(_ report: DeliveryCheck.Report) -> some View {
        let open = report.issues.filter { !intended.contains($0.key) }
        let problems = open.filter { $0.severity == .problem }.count
        let warnings = open.filter { $0.severity == .warning }.count
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
                        Text(report.spec.title)
                    }
                }
                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Compare with Approved Version…", systemImage: "square.on.square") { compare() }
                Divider()
                Button("PDF Report…", systemImage: "doc.richtext") { export(report, as: .pdf) }
                Button("CSV…", systemImage: "tablecells") { export(report, as: .csv) }
                Button("Resolve Markers (EDL)…", systemImage: "bookmark") { export(report, as: .edl) }
            } label: {
                StudioMenuLabel(title: String(localized: "Export"))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func row(_ issue: DeliveryCheck.Issue, fps: Double) -> some View {
        let hidden = intended.contains(issue.key)
        return HStack(alignment: .top, spacing: 12) {
            thumbnail(issue)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon(issue.severity)).font(.system(size: 12)).foregroundStyle(color(issue.severity))
                    Text(issue.title).font(.system(size: 13))
                    if issue.isNew { StudioChip(text: Text("New"), colour: Design.Brand.pink, tinted: true) }
                }
                Text(issue.detail).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                HStack(spacing: 14) {
                    if let word = issue.word {
                        Button("It’s spelled right") { learn(word) }
                            .help("Pluck remembers “\(word)” and won’t mark it again")
                    }
                    Button(hidden ? "Show again" : "Intended") { setIntended(issue, !hidden) }
                        .help(hidden ? "Show this again" : "Hide this for this file")
                }
                .buttonStyle(.plain)
                .font(Design.Studio.hint)
                .foregroundStyle(Design.Brand.pink)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let time = issue.time {
                Text(DeliveryCheck.timecode(time, fps: fps))
                    .font(Design.Studio.hint.monospacedDigit())
                    .foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .opacity(hidden ? 0.5 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .studioBox(outline: selected == issue.id ? Design.rgb(0x8E4C64) : nil)
        .contentShape(.rect)
        .onTapGesture { pick(issue) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(DeliveryCheck.severityLabel(issue.severity)): \(issue.title)"))
        .accessibilityAddTraits(.isButton)
    }

    /// The transitions found, in one box: a line each, opened on request.
    private func transitionGroup(_ transitions: [DeliveryCheck.Issue], fps: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth) { showTransitions.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    Text("Transitions").font(.system(size: 13))
                    StudioChip(text: Text(verbatim: "\(transitions.count)"))
                    Spacer(minLength: 0)
                    Image(systemName: showTransitions ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.Studio.textQuiet)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showTransitions {
                ForEach(transitions) { issue in
                    let hidden = intended.contains(issue.key)
                    HStack(spacing: 10) {
                        thumbnail(issue, width: 48)
                        Text(issue.detail).font(Design.Studio.body)
                        Spacer(minLength: 0)
                        Button(hidden ? "Show again" : "Intended") { setIntended(issue, !hidden) }
                            .buttonStyle(.plain).font(Design.Studio.hint).foregroundStyle(Design.Brand.pink)
                        if let time = issue.time {
                            Text(DeliveryCheck.timecode(time, fps: fps)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                        }
                    }
                    .opacity(hidden ? 0.5 : 1)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(selected == issue.id ? Design.Studio.raised : .clear)
                    .contentShape(.rect)
                    .onTapGesture { pick(issue) }
                }
            }
        }
        .studioBox()
    }

    /// The frame at the finding's moment (a symbol when it's about the whole file).
    private func thumbnail(_ issue: DeliveryCheck.Issue, width: CGFloat = 72) -> some View {
        Group {
            if let time = issue.time, let image = thumbnails[time] {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: issue.time == nil ? "doc" : "photo").font(.system(size: 11)).foregroundStyle(Design.Studio.textFaint)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .background(Design.Studio.raised)
        .clipShape(.rect(cornerRadius: 4, style: .continuous))
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

    /// What's listed: without those marked intended (unless shown), and of the chosen severity.
    private func visible(_ report: DeliveryCheck.Report, filtered: Bool) -> [DeliveryCheck.Issue] {
        report.issues.filter { (showHidden || !intended.contains($0.key)) && (!filtered || filter == nil || $0.severity == filter) }
    }

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

    // MARK: - Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, !panel.urls.isEmpty { open(panel.urls) }
    }

    private func open(_ urls: [URL], append: Bool = false) {
        guard running == nil || append else { return }
        store.open(urls, append: append, manager: manager)
        show(current)
    }

    private func show(_ id: Item.ID?) {
        guard id != shown || player.currentItem == nil else { return }
        shown = id
        current = id
        selected = nil
        thumbnails = [:]
        intended = item?.report.map { DeliveryCheck.intended($0.fileKey) } ?? []
        player.replaceCurrentItem(with: item.map { AVPlayerItem(url: $0.file) })
        if let first = item?.report?.issues.first { pick(first) }
    }

    private func check(all: Bool) { store.check(all: all, manager: manager) }

    /// Checks an approved earlier version too, and marks what changed since.
    private func compare() {
        guard running == nil, let index = items.firstIndex(where: { $0.id == current }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = String(localized: "Compare")
        panel.message = String(localized: "The approved earlier version")
        guard panel.runModal() == .OK, let url = panel.url, running == nil, items.indices.contains(index) else { return }
        store.setApproved(url, for: items[index].id, manager: manager)
    }

    private func pick(_ issue: DeliveryCheck.Issue) {
        selected = issue.id
        if let time = issue.time { seek(time) }
    }

    private func seek(_ time: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: time + 0.02, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func learn(_ word: String) {
        DeliveryCheck.learn(word)
        guard let index = items.firstIndex(where: { $0.id == current }) else { return }
        items[index].report?.issues.removeAll { $0.word?.lowercased() == word.lowercased() }
    }

    private func setIntended(_ issue: DeliveryCheck.Issue, _ on: Bool) {
        guard let report else { return }
        DeliveryCheck.setIntended(issue, fileKey: report.fileKey, on)
        intended = DeliveryCheck.intended(report.fileKey)
    }

    private func loadThumbnails() async {
        guard let report else { return }
        let times = report.issues.compactMap(\.time).filter { thumbnails[$0] == nil }
        guard !times.isEmpty else { return }
        let found = await DeliveryCheck.thumbnails(report.file, times: times, width: 240)
        guard !Task.isCancelled, self.report?.file == report.file else { return }
        thumbnails.merge(found) { $1 }
    }

    private enum ExportKind { case pdf, csv, edl }

    private func export(_ report: DeliveryCheck.Report, as kind: ExportKind) {
        let panel = NSSavePanel()
        let base = report.file.deletingPathExtension().lastPathComponent + String(localized: " (delivery check)")
        switch kind {
        case .pdf: panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = base + ".pdf"
        case .csv: panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = base + ".csv"
        case .edl: panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .plainText]; panel.nameFieldStringValue = base + ".edl"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // What's open: findings marked intended stay out.
        let issues = report.issues.filter { !intended.contains($0.key) }
        switch kind {
        case .pdf:
            let thumbnails = thumbnails
            Task {
                var frames = thumbnails
                let missing = issues.compactMap(\.time).filter { frames[$0] == nil }
                if !missing.isEmpty { frames.merge(await DeliveryCheck.thumbnails(report.file, times: missing, width: 240)) { $1 } }
                do { try DeliveryCheck.pdf(report, issues: issues, thumbnails: frames).write(to: url) } catch { problem = error.localizedDescription }
            }
        case .csv:
            do { try DeliveryCheck.csv(report, issues: issues).write(to: url, atomically: true, encoding: .utf8) } catch { problem = error.localizedDescription }
        case .edl:
            do { try DeliveryCheck.markerEDL(report, issues: issues).write(to: url, atomically: true, encoding: .utf8) } catch { problem = error.localizedDescription }
        }
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

/// Play, the time, a thin track with a marker at each finding's moment (click one to go there), and the length.
private struct ScrubRow: View {
    let player: AVPlayer
    let duration: Double
    let ticks: [(Double, Color)]
    var onTick: (Int) -> Void = { _ in }
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
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            guard duration > 0 else { return }
                            let seconds = min(max(drag.location.x / max(width, 1), 0), 1) * duration
                            time = seconds
                            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        })
                    ForEach(ticks.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1).fill(ticks[index].1)
                            .frame(width: 2, height: 12)
                            .frame(width: 8, height: 16)
                            .contentShape(.rect)
                            .onTapGesture { onTick(index) }
                            .offset(x: duration > 0 ? width * min(ticks[index].0 / duration, 1) - 4 : 0)
                    }
                }
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
