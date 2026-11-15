import SwiftUI
import UniformTypeIdentifiers

/// Archive Project: a job's source (a Pluck project, the project open in Resolve, or a timeline
/// file), what will go and where, then the checked copy and, once confirmed, the caches cleaned.
struct ProjectArchiveView: View {
    /// What was chosen, kept while another page is open (the copy carries on there).
    @MainActor private enum Kept {
        static var sources: ProjectArchive.Sources?
        static var targets: [URL] = []
        static var trimmed = false
        static var run = ArchiveRun()
        static var masters = false
        static var settings = ProjectArchive.MasterSettings.compact
        static var overrides: [String: ProjectArchive.MasterSettings] = [:]
    }
    private typealias MasterSettings = ProjectArchive.MasterSettings
    @State private var sources = Kept.sources
    @State private var plan: ProjectArchive.Plan?
    @State private var targets = Kept.targets
    @State private var trimmed = Kept.trimmed
    @State private var handles = 2.0
    @State private var reading = false
    @State private var problem: String?
    @State private var run = Kept.run
    @State private var clean: Set<String> = []
    @State private var confirming = false
    @State private var left: [String] = []
    @State private var masters = Kept.masters
    @State private var settings = Kept.settings
    @State private var overrides = Kept.overrides
    /// Master bytes per original byte, from test encodes, by choice.
    @State private var ratios: [MasterSettings: Double] = [:]
    /// Each file's picture size (width, height), for the sizes offered.
    @State private var sizes: [String: [Int]] = [:]
    /// A timeline file to read when the view appears (screenshot mode).
    @MainActor static var openFile: URL?

    private var tool: (String) -> String? { { AppDelegate.shared?.manager.tool($0) } }
    private var busy: Bool { reading || run.phase == .preparing || run.phase == .copying }
    private let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Archive Project").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                sourceField
                if let problem {
                    row(StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad), Text("Couldn’t read the project"), Text(problem))
                }
                if sources == nil {
                    StudioEmptyState(symbol: "archivebox", title: "Choose what to archive",
                                     line: "Only the media the edit uses goes, with renders and project files, every file checked.")
                        .padding(.vertical, 48)
                        .studioDropZone(targeted: false)
                } else if let plan {
                    planBox(plan)
                    mastersBox(plan)
                    targetsBox
                    progress
                    if run.verified, !(plan.cleanables + run.replacedOriginals).isEmpty { cleanBox(plan) }
                } else if reading {
                    row(PlumSpinner(), Text(sources?.name ?? ""), Text("Reading what’s used…"))
                }
                StudioFootnote(text: "Originals only go to the Trash if you choose, after their masters are checked", symbol: "checkmark.shield")
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .studioPanel()
        .task(id: "\(trimmed)\(handles)\(sources?.name ?? "")\(sources?.renders.count ?? 0)\(sources?.extras.count ?? 0)\(sources?.projectFolder ?? "")") { await replan() }
        .onAppear { if let url = Self.openFile { Self.openFile = nil; read(url) } }
        .onChange(of: targets) { Kept.targets = targets }
        .onChange(of: trimmed) { Kept.trimmed = trimmed }
        .onChange(of: masters) { Kept.masters = masters }
        .onChange(of: settings) { Kept.settings = settings }
        .onChange(of: overrides) { Kept.overrides = overrides }
        .task(id: masters ? "\(plan?.items.count ?? 0) \(Set(chosenSettings.values).map(\.label).sorted())" : "") { await estimate() }
        .confirmationDialog("Move these to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { left = run.clean(chosen) }
        } message: {
            Text(chosen.map { item in
                item.master.map { "\((item.path as NSString).abbreviatingWithTildeInPath) (\(bytes(item.size))) → \(($0 as NSString).abbreviatingWithTildeInPath)" }
                    ?? "\(item.label): \((item.path as NSString).abbreviatingWithTildeInPath) (\(bytes(item.size)))"
            }.joined(separator: "\n"))
        }
    }

    private var chosen: [ProjectArchive.Cleanable] {
        ((plan?.cleanables ?? []) + run.replacedOriginals).filter { clean.contains($0.path) && !run.cleaned.contains($0.path) }
    }

    // MARK: The source

    private var sourceField: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox").font(.system(size: 14))
                .foregroundStyle(sources == nil ? Design.Studio.textFaint : Design.Brand.pink).accessibilityHidden(true)
            Group {
                if let sources { Text(verbatim: sources.name).foregroundStyle(Design.Studio.text) }
                else { Text("Choose a project").foregroundStyle(Design.Studio.textQuiet) }
            }
            .font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                let projects = ProjectStore.madeProjects()
                if !projects.isEmpty {
                    Section("Pluck") {
                        ForEach(projects) { project in Button(project.name) { use(project) } }
                    }
                }
                Button("Project Open in DaVinci Resolve", systemImage: "film") { readResolve() }
                Button("Timeline or Project File…", systemImage: "doc") { chooseFile() }
            } label: {
                StudioMenuLabel(title: sources == nil ? String(localized: "Choose") : String(localized: "Change"), quiet: true)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            if sources != nil {
                Rectangle().fill(Design.Studio.line).frame(width: 1, height: 18)
                Menu {
                    Button("None") { sources?.projectFolder = nil }
                    ForEach(OffloadProjects.shared.projects) { project in
                        if let drive = project.drives.first {
                            Button(project.name) { sources?.projectFolder = (drive as NSString).appendingPathComponent(FolderTemplate.safe(project.name)) }
                        }
                    }
                    Button("Folder…") { if let folder = pickFolder() { sources?.projectFolder = folder.path } }
                } label: {
                    StudioMenuLabel(title: sources?.projectFolder.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Project folder"), quiet: true)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("The folder the media keeps its layout below")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 48)
        .studioBox(outline: sources == nil ? Design.Studio.line : Design.rgb(0x8E4C64))
        .disabled(busy)
    }

    private func use(_ project: Project) {
        var made = ProjectArchive.Sources(name: project.name, uses: ProjectArchive.uses(of: project))
        made.pluck = project
        start(made)
    }

    private func start(_ made: ProjectArchive.Sources) {
        problem = nil
        plan = nil
        run = ArchiveRun()
        Kept.run = run
        clean = []
        left = []
        sources = made
    }

    private func readResolve() {
        reading = true
        problem = nil
        Task {
            defer { reading = false }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pluck/Archive/Resolve \(UUID().uuidString)", isDirectory: true)
            do { start(try await ProjectArchive.readResolve(into: folder)) } catch { problem = error.localizedDescription }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["fcpxml", "fcpxmld", "xml", "edl", "drp", "drt"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func read(_ url: URL) {
        reading = true
        problem = nil
        let search = [sources?.projectFolder].compactMap { $0 } + [url.deletingLastPathComponent().path]
        let ffprobe = tool("ffprobe")
        Task {
            let read = await Task.detached(priority: .userInitiated) { ProjectArchive.uses(file: url, search: search, ffprobe: ffprobe) }.value
            reading = false
            guard !read.uses.isEmpty else { problem = String(localized: "No media was found in \(url.lastPathComponent)."); return }
            var made = ProjectArchive.Sources(name: url.deletingPathExtension().lastPathComponent, uses: read.uses)
            made.projectFiles = [url.path]
            start(made)
            if !read.missing.isEmpty { problem = String(localized: "Not found: \(read.missing.formatted(.list(type: .and))).") }
        }
    }

    private func replan() async {
        Kept.sources = sources
        guard let sources else { return }
        let trimmed = trimmed, handles = handles, ffprobe = tool("ffprobe")
        let made = await Task.detached(priority: .userInitiated) { ProjectArchive.plan(sources, trimmed: trimmed, handles: handles, ffprobe: ffprobe) }.value
        guard !Task.isCancelled else { return }
        plan = made
        clean = Set(made.cleanables.filter(\.suggested).map(\.path))
    }

    // MARK: The plan

    private func planBox(_ plan: ProjectArchive.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let media = plan.items.filter { $0.kind == .media }
            line("film", Text("Media"), Text("\(media.count) used · \(bytes(plan.bytes(.media)))"))
            HStack(spacing: 14) {
                StudioSwitchRow(title: "Only the parts used", isOn: $trimmed)
                if trimmed {
                    StudioSegmented(options: [(1.0, "1 s"), (2.0, "2 s"), (5.0, "5 s")], selection: $handles)
                        .help("Handles each side")
                    let cut = media.filter { $0.trim != nil }.count
                    Text("\(cut) trimmed · raw stays whole").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .padding(.leading, 34)
            folderLines(.render, symbol: "play.rectangle", title: "Renders", list: \.renders)
            folderLines(.extra, symbol: "folder", title: "Graphics, music, documents", list: \.extras)
            let project = plan.items.filter { $0.kind == .project }
            if !project.isEmpty || sources?.pluck != nil {
                line("doc", Text("Project"), Text(verbatim: (project.map { ($0.relative as NSString).lastPathComponent } + (sources?.pluck.map { ["\($0.name).pluckproject"] } ?? [])).joined(separator: ", ")))
            }
            if !plan.missing.isEmpty {
                line("exclamationmark.triangle", Text("Not found"), Text("\(plan.missing.count) files the edit uses aren’t on this Mac"), colour: Design.Studio.warn)
            }
            Divider().overlay(Design.Studio.line).padding(.vertical, 6)
            line("sum", Text("Archive"), Text(verbatim: bytes(plan.bytes)))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
        .disabled(busy)
    }

    private func folderLines(_ kind: ProjectArchive.Kind, symbol: String, title: LocalizedStringKey, list: WritableKeyPath<ProjectArchive.Sources, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sources?[keyPath: list] ?? [], id: \.self) { folder in
                let size = plan?.items.filter { $0.kind == kind && $0.root == folder }.reduce(Int64(0)) { $0 + $1.size } ?? 0
                line(symbol, Text(verbatim: (folder as NSString).lastPathComponent), Text(verbatim: bytes(size))) {
                    removeButton { sources?[keyPath: list].removeAll { $0 == folder } }
                }
            }
            StudioDashedButton(title: title, height: 32) { if let folder = pickFolder() { sources?[keyPath: list].append(folder.path) } }
                .padding(.leading, 34)
        }
    }

    // MARK: Masters

    /// What each original that can have a master is made into (its own choice, else the default).
    private var chosenSettings: [String: MasterSettings] {
        guard masters, let plan else { return [:] }
        return Dictionary(plan.items.filter(ProjectArchive.masterable).map { ($0.original, overrides[$0.original] ?? settings) }, uniquingKeysWith: { a, _ in a })
    }

    /// A file's master size: the real one once made and checked, else the estimate.
    private func masterSize(_ item: ProjectArchive.Item) -> Int64? {
        if let check = run.masters[item.original], check.ok { return check.size }
        guard let choice = chosenSettings[item.original] else { return nil }
        if choice.codec == .original { return item.size }
        return ratios[choice].map { Int64(Double(item.size) * $0) }
    }

    private func estimate() async {
        guard masters, let plan, let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else { return }
        let items = plan.items.filter(ProjectArchive.masterable)
        let missing = Set(chosenSettings.values).filter { $0.codec != .original && ratios[$0] == nil }
        let unknown = items.map(\.source).filter { sizes[$0] == nil }
        let found = await Task.detached(priority: .utility) {
            (ProjectArchive.estimate(items, settings: missing, ffmpeg: ffmpeg, ffprobe: ffprobe),
             Dictionary(unknown.compactMap { path in ProjectArchive.reference(path, ffprobe: ffprobe, count: false).map { (path, [$0.width, $0.height]) } },
                        uniquingKeysWith: { a, _ in a }))
        }.value
        guard !Task.isCancelled else { return }
        ratios.merge(found.0) { _, new in new }
        sizes.merge(found.1) { _, new in new }
    }

    /// The sizes offered for these files: native, and those smaller than the largest of them.
    private func sizeOptions(_ paths: [String]) -> [MasterSettings.Size] {
        let long = paths.compactMap { sizes[$0]?.max() }.max() ?? .max
        return MasterSettings.Size.allCases.filter { $0 == .native || $0.rawValue < long }
    }

    private func mastersBox(_ plan: ProjectArchive.Plan) -> some View {
        let files = plan.items.filter(ProjectArchive.masterable)
        return VStack(alignment: .leading, spacing: 4) {
            StudioSwitchRow(title: "Archive masters", isOn: $masters)
                .help("Smaller copies that can replace the originals, log kept as log, checked frame by frame")
            if masters, !files.isEmpty {
                HStack(spacing: 10) {
                    StudioSegmented(options: [(0, "Master"), (1, "Compact"), (2, "Compact 4K")], selection: Binding(
                        get: { settings.codec == .prores ? 0 : settings.size == .k4 ? 2 : 1 },
                        set: { settings = [MasterSettings.master, .compact, .compact4K][$0].with(quality: settings.quality) }))
                    choiceMenu(settings, sizes: sizeOptions(files.map(\.source))) { settings = $0 }
                }
                .padding(.leading, 34)
                let before = files.reduce(Int64(0)) { $0 + $1.size }
                let after = files.map { masterSize($0) }
                if !after.contains(where: { $0 == nil }) {
                    let total = after.reduce(Int64(0)) { $0 + ($1 ?? 0) }
                    let done = files.allSatisfy { run.masters[$0.original]?.ok == true || chosenSettings[$0.original]?.codec == .original }
                    line("arrow.down.right.circle", Text("\(bytes(before)) → \(bytes(total))"),
                         Text(verbatim: String(localized: "Saves \(bytes(max(before - total, 0))) (\(Int((Double(before - total) / Double(max(before, 1)) * 100).rounded()))%)")
                              + (done ? "" : " · " + String(localized: "estimated from a test encode"))))
                } else {
                    line("hourglass", Text("\(bytes(before)) → …"), Text("Test encode…"))
                }
                ForEach(files, id: \.original) { item in fileLine(item) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
        .disabled(busy)
    }

    private func fileLine(_ item: ProjectArchive.Item) -> some View {
        let check = run.masters[item.original]
        let choice = chosenSettings[item.original] ?? settings
        let after = masterSize(item)
        return HStack(spacing: 10) {
            Image(systemName: check.map { $0.ok ? "checkmark.seal" : "exclamationmark.triangle" } ?? "film")
                .font(.system(size: 12)).frame(width: 22)
                .foregroundStyle(check.map { $0.ok ? Design.Studio.good : Design.Studio.bad } ?? Design.Studio.textFaint)
                .help(check.map { $0.ok ? String(localized: "Frames, timecode and sound match; plays to the end") : $0.problems.joined(separator: "\n") } ?? "")
            Text(verbatim: (item.relative as NSString).lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: "\(bytes(item.size)) → \(after.map(bytes) ?? "…")").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
            choiceMenu(choice, sizes: sizeOptions([item.source]), original: true) { overrides[item.original] = $0 }
        }
        .frame(height: 26)
        .padding(.leading, 34)
        .help(item.original)
    }

    /// Level, size and quality in one menu (`original`: keeping the file as it is is offered too).
    private func choiceMenu(_ current: MasterSettings, sizes: [MasterSettings.Size], original: Bool = false,
                            set: @escaping (MasterSettings) -> Void) -> some View {
        Menu {
            if original { Button("Original") { set(.original) } }
            Button("Master") { set(MasterSettings.master.with(size: current.size)) }
            Button("Compact") { set(MasterSettings.compact.with(size: current.size, quality: current.quality)) }
            Section("Size") {
                ForEach(sizes, id: \.self) { size in Button(size.label) { set((current.codec == .original ? .compact : current).with(size: size)) } }
            }
            if current.codec == .hevc {
                Section("Quality") {
                    ForEach(MasterSettings.Quality.allCases, id: \.self) { quality in Button(quality.label) { set(current.with(quality: quality)) } }
                }
            }
        } label: {
            StudioMenuLabel(title: current.label, quiet: true)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    // MARK: Where it goes

    private var targetsBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(targets, id: \.self) { target in
                let free = OffloadCenter.freeSpace(target)
                let enough = free.map { $0 >= plan?.bytes ?? 0 } ?? true
                line("externaldrive", Text(verbatim: OffloadCenter.volumeName(target)),
                     Text(verbatim: free.map { String(localized: "\(bytes($0)) free") } ?? target.path), colour: enough ? Design.Studio.text : Design.Studio.bad) {
                    removeButton { targets.removeAll { $0 == target } }
                }
            }
            HStack(spacing: 10) {
                StudioDashedButton(title: "NAS or archive drive", height: 32) { if let folder = pickFolder(), !targets.contains(folder) { targets.append(folder) } }
                Button("Archive", systemImage: "archivebox") { archive() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(targets.isEmpty || plan?.items.isEmpty != false || busy)
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    private func archive() {
        guard let plan else { return }
        let pluck = sources?.pluck, targets = targets
        let settings = chosenSettings
        Task { await run.start(plan, pluck: pluck, targets: targets, ffmpeg: tool("ffmpeg"), ffprobe: tool("ffprobe"), settings: settings) }
    }

    // MARK: Progress and the end

    @ViewBuilder private var progress: some View {
        switch run.phase {
        case .idle: EmptyView()
        case .preparing:
            if let made = run.mastering {
                row(PlumSpinner(), Text("Making masters"), Text("\(made.done) of \(made.total) · each checked against its original"))
            } else {
                row(PlumSpinner(), Text("Getting ready"), Text(trimmed ? "Cutting the clips…" : "Writing the project file…"))
            }
        case .copying, .paused:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    StudioTile(symbol: "externaldrive.badge.checkmark")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.phase == .paused ? "Paused" : "Copying and checking").font(.system(size: 13)).foregroundStyle(Design.Studio.text)
                        Text(run.share, format: .percent.precision(.fractionLength(0))).font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                    }
                    Spacer()
                    if run.phase == .copying { Button("Pause") { run.pause() }.buttonStyle(StudioFlatButtonStyle()) }
                    else { Button("Resume") { archive() }.buttonStyle(StudioFlatButtonStyle()) }
                }
                StudioProgress(share: run.share)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .studioBox()
        case .failed(let why):
            row(StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad), Text("The archive isn’t complete"), Text(why))
        case .done:
            let files = run.plan?.items.count ?? 0
            row(StudioTile(symbol: "checkmark", colour: Design.Studio.good), Text("Archived and checked"),
                Text(verbatim: ([String(localized: "\(files) files on \(run.folders.count) drives · \(bytes(run.plan?.bytes ?? 0))")] + run.notes).joined(separator: "\n"))) {
                iconButton("list.bullet.rectangle", label: "Inventory") {
                    if let folder = run.folders.first { NSWorkspace.shared.open(folder.appendingPathComponent("Inventory.html")) }
                }
                iconButton("folder", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(run.folders) }
            }
        }
    }

    private func cleanBox(_ plan: ProjectArchive.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clean up").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).padding(.bottom, 6)
            ForEach(plan.cleanables + run.replacedOriginals) { item in
                let gone = run.cleaned.contains(item.path)
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { clean.contains(item.path) }, set: { if $0 { clean.insert(item.path) } else { clean.remove(item.path) } })) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden().disabled(gone)
                    Text(verbatim: item.label).font(Design.Studio.body).foregroundStyle(gone ? Design.Studio.textFaint : Design.Studio.text)
                    Text(verbatim: (item.path as NSString).lastPathComponent).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(verbatim: gone ? String(localized: "In the Trash") : bytes(item.size)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                }
                .frame(height: 26)
                .help(item.path)
            }
            let originals = run.replacedOriginals.filter { !run.cleaned.contains($0.path) }
            if !originals.isEmpty {
                Text("Originals with a checked master: \(bytes(originals.reduce(Int64(0)) { $0 + $1.size })) freed once they’re in the Trash")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if !left.isEmpty {
                Text("\(left.count) couldn’t go to the Trash").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
            }
            HStack {
                Spacer()
                Button("Move to Trash…", systemImage: "trash") { confirming = true }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    // MARK: Pieces

    private func line<Actions: View>(_ symbol: String, _ title: Text, _ detail: Text, colour: Color = Design.Studio.text,
                                     @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(colour).frame(width: 22).accessibilityHidden(true)
            title.font(Design.Studio.body).foregroundStyle(Design.Studio.text)
            Spacer(minLength: 8)
            detail.font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            actions()
        }
        .frame(minHeight: 30)
    }

    private func row<Tile: View, Actions: View>(_ tile: Tile, _ title: Text, _ detail: Text, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            tile.frame(width: 40, height: 40).background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13)).foregroundStyle(Design.Studio.text).lineLimit(1)
                detail.font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .studioBox()
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        iconButton("xmark", label: "Remove", action: action)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
