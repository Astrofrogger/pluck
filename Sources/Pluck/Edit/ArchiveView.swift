import SwiftUI
import UniformTypeIdentifiers

/// Archive: a dashboard of what can be freed and what's being archived, New Archive in three
/// steps (Folders · Projects · Size and destination), and Archive Project's timeline mode as an
/// option. Everything it shows and does is ArchiveModel's.
struct ArchiveView: View {
    @Bindable private var model = ArchiveModel.shared
    @AppStorage("archiveMode") private var timeline = false
    @State private var renaming: ShrinkFolders.Project?
    @State private var newName = ""
    @State private var more = false
    @State private var showAll = false
    private var center: ShrinkCenter { model.center }
    private let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    private var flow: Bool { [.folders, .projects, .settings].contains(model.screen) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if timeline {
                ProjectArchiveView(embedded: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch model.screen {
                        case .dashboard: dashboard
                        case .folders: foldersStep
                        case .projects: projectsStep
                        case .settings: settingsStep
                        case .untouched: untouchedList
                        case .history: history
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                if flow { footer }
            }
        }
        .studioPanel()
        .task { await model.appeared() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 20) {
            Text("Archive").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
            if flow && !timeline {
                HStack(spacing: 14) {
                    step(.folders, "1 Folders")
                    step(.projects, "2 Projects")
                    step(.settings, "3 Size and destination")
                }
            }
            Spacer()
            if timeline {
                Button("Back") { timeline = false }.buttonStyle(.link)
            } else if model.screen == .dashboard {
                Button("New Archive…") { model.newArchive() }.buttonStyle(BrandButtonStyle(large: false)).disabled(center.running)
            } else if !flow {
                Button("Back") { model.screen = .dashboard }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 4)
        .frame(maxWidth: 924).frame(maxWidth: .infinity)
    }

    private func step(_ screen: ArchiveModel.Screen, _ title: LocalizedStringKey) -> some View {
        Text(title).font(Design.Studio.body).foregroundStyle(model.screen == screen ? Design.Studio.text : Design.Studio.textFaint)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(model.screen == .folders ? "Cancel" : "Back") { model.back() }.buttonStyle(StudioFlatButtonStyle())
            Spacer()
            if model.screen == .settings {
                Text("\(Set(model.picked.map(\.project)).count) projects · frees \(bytes(max(model.totals.saving, 0)))")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Button("Start") { model.next() }.buttonStyle(BrandButtonStyle(large: false)).disabled(!model.canStart)
            } else {
                Button("Next") { model.next() }.buttonStyle(BrandButtonStyle(large: false))
                    .disabled(model.screen == .folders ? model.folders.isEmpty : (model.scanning || model.picked.isEmpty))
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .frame(maxWidth: 924).frame(maxWidth: .infinity)
    }

    // MARK: Dashboard

    @ViewBuilder private var dashboard: some View {
        if model.survey == nil, model.archivingNow == nil {
            StudioEmptyState(symbol: "archivebox", title: "Free space on the NAS",
                             line: "Old rushes become checked 1080p masters. The originals move to a folder for you to delete.",
                             prominent: true, button: "New Archive…") { model.newArchive() }
                .padding(.vertical, 60)
        } else {
            let free = model.freeable
            VStack(alignment: .leading, spacing: 6) {
                Text("You can free").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Text(verbatim: bytes(free.saving)).font(.system(size: 34, weight: .semibold)).foregroundStyle(Design.Brand.pink)
                Text("of \(bytes(free.footage)) footage").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            if let now = model.archivingNow { archiving(now) }
            let places = model.whereItSits
            if !places.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Where it sits").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                    ForEach(places, id: \.share) { place in
                        VStack(alignment: .leading, spacing: 4) {
                            amountLine(Text(verbatim: place.share).foregroundStyle(Design.Studio.text), place.saving)
                            ForEach(place.projects, id: \.title) { project in
                                amountLine(Text(verbatim: project.title).foregroundStyle(Design.Studio.textQuiet), project.saving, quiet: true).padding(.leading, 18)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Not touched") { model.screen = .untouched }
                Text(verbatim: "·").foregroundStyle(Design.Studio.textFaint)
                Button("History") { model.screen = .history }
                Text(verbatim: "·").foregroundStyle(Design.Studio.textFaint)
                Button("Look Again") { model.rescan(cached: false) }.disabled(model.scanning || model.folders.isEmpty)
                if model.scanning { PlumSpinner().frame(width: 12, height: 12) }
            }
            .buttonStyle(.link).font(Design.Studio.hint)
        }
        StudioFootnote(text: "Pluck never deletes: originals and proxies go to “Pluck · Originals to delete”", symbol: "checkmark.shield")
    }

    private func amountLine(_ title: Text, _ amount: Int64, quiet: Bool = false) -> some View {
        HStack {
            title.font(quiet ? Design.Studio.hint : Design.Studio.body).lineLimit(1)
            Spacer()
            Text(verbatim: bytes(amount)).font((quiet ? Design.Studio.hint : Design.Studio.body).monospacedDigit())
                .foregroundStyle(quiet ? Design.Studio.textQuiet : Design.Studio.text)
        }
    }

    private func archiving(_ now: (title: String, freed: Int64, total: Int64, parts: [ArchiveModel.Progress])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Archiving now").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text(verbatim: now.title).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                Spacer()
                if center.running {
                    Button("Pause") { model.pause() }.buttonStyle(.link).font(Design.Studio.hint)
                } else if let run = center.runs.first(where: center.unfinished) {
                    Button("Resume") { model.resume(run) }.buttonStyle(.link).font(Design.Studio.hint)
                }
            }
            StudioProgress(share: Double(now.freed) / Double(max(now.total, 1)))
            HStack(spacing: 8) {
                Text("\(bytes(now.freed)) of \(bytes(now.total)) freed").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                if now.parts.isEmpty { Text("Paused").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
            }
            ForEach(Array(now.parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 8) {
                    if part.waitingForEdit {
                        Text("Paused while you edit").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                        Button("Run Anyway") { model.runAnyway() }.buttonStyle(.link).font(Design.Studio.hint)
                    } else {
                        Text(verbatim: part.machine + " · " + String(localized: "\(part.done) of \(part.total)")
                             + (part.left.map { " · " + String(localized: "\(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left") } ?? ""))
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
            }
        }
    }

    // MARK: Step 1: folders

    @ViewBuilder private var foldersStep: some View {
        Text("Choose shares or folders").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.folders, id: \.self) { folder in
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(Design.Studio.textQuiet)
                    Text(verbatim: folder.lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    let root = ShrinkFolders.real(folder).path
                    let used = (model.survey?.projects.values ?? [:].values).filter { $0.folder == root || $0.folder.hasPrefix(root + "/") }.reduce(Int64(0)) { $0 + $1.total }
                    if used > 0 { Text(verbatim: bytes(used)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet) }
                    if !FileManager.default.isWritableFile(atPath: folder.path) {
                        Text("Read-only").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).help("Masters can only go to another folder")
                    }
                    Button { model.remove(folder) } label: { Image(systemName: "xmark").foregroundStyle(Design.Studio.textQuiet) }
                        .buttonStyle(.plain).help("Remove")
                }
                .frame(height: 30)
            }
            StudioDashedButton(title: "Add Share or Folder", height: 34) { if let folder = pickFolder() { model.add(folder) } }
        }
    }

    // MARK: Step 2: projects

    @ViewBuilder private var projectsStep: some View {
        HStack {
            if model.scanning {
                PlumSpinner().frame(width: 16, height: 16)
                Text("Looking… \(model.found) videos").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Button("Stop") { model.stopScan() }.buttonStyle(.link)
            } else {
                Text("Projects").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            }
            Spacer()
            Menu {
                ForEach([0, 3, 6, 12, 24], id: \.self) { value in Button(monthsLabel(value)) { model.months = value } }
            } label: { StudioMenuLabel(title: monthsLabel(model.months), quiet: true) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("A project with a newer file is left as it is")
            Button(model.off.isEmpty ? "Select None" : "Select All") { model.selectAll(!model.off.isEmpty) }.buttonStyle(.link).font(Design.Studio.hint)
        }
        let rows = model.clients.flatMap(\.projects).sorted { ($0.dim == nil ? 0 : 1, -$0.saving) < ($1.dim == nil ? 0 : 1, -$1.saving) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(showAll ? rows : Array(rows.prefix(20))) { row in projectRow(row) }
            if rows.count > 20, !showAll {
                Button("\(rows.count - 20) more") { showAll = true }.buttonStyle(.link).font(Design.Studio.hint).padding(.top, 8)
            }
        }
    }

    private func projectRow(_ row: ArchiveModel.ProjectRow) -> some View {
        let project = row.project
        let below = Set(model.files.filter { $0.project == project.folder }.map { ($0.path as NSString).deletingLastPathComponent }).filter { $0 != project.folder }.sorted()
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { row.selected && row.dim == nil }, set: { model.select([project], $0) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(row.dim != nil)
            (Text(verbatim: project.client).foregroundStyle(Design.Studio.text)
             + Text(verbatim: project.name == project.client ? "" : " – " + project.name).foregroundStyle(Design.Studio.textQuiet))
                .font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let dim = row.dim { Text(verbatim: dim).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
            Text(verbatim: bytes(project.total)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).frame(width: 72, alignment: .trailing)
            Text(verbatim: row.saving > 0 ? "−" + bytes(row.saving) : "").font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Brand.pink)
                .frame(width: 80, alignment: .trailing)
        }
        .frame(height: 30)
        .opacity(row.dim == nil ? 1 : 0.55)
        .contentShape(.rect)
        .help(String(localized: "Rushes \(bytes(project.rushes)) · Proxies and caches \(bytes(project.proxies)) · Deliveries \(bytes(project.deliveries)) · Other \(bytes(project.other))"))
        .contextMenu {
            Button("Rename…") { newName = project.name; renaming = project }
            Button("Part of the Folder Above") { model.partOfParent(project) }
            if !below.isEmpty {
                Menu("This Folder Is a Project") {
                    ForEach(below, id: \.self) { folder in
                        Button(String(folder.dropFirst(project.folder.count + 1))) { model.isProject(folder, share: project.share) }
                    }
                }
            }
            Button("Detect Again") { model.detectAgain(project) }
        }
    }

    private func monthsLabel(_ value: Int) -> String {
        value == 0 ? String(localized: "Any age") : String(localized: "Older than \(value) months")
    }

    // MARK: Step 3: size and destination

    @ViewBuilder private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Size") {
                StudioSegmented(options: [(ShrinkFolders.Settings.Size.hd, "1080p"), (.k4, "4K")], selection: $model.size)
                StudioSegmented(options: [(false, "HEVC 10-bit"), (true, "ProRes 422 HQ")], selection: $model.prores)
                if !model.prores { StudioSegmented(options: [(false, "High"), (true, "Balanced")], selection: $model.balanced) }
            }
            field("Masters") {
                Menu {
                    Button("In place") { model.destination = nil }
                    Button("Another Folder…") { model.destination = pickFolder() ?? model.destination }
                } label: {
                    StudioMenuLabel(title: model.destination.map { String(localized: "To \($0.lastPathComponent)") } ?? String(localized: "In place"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("In place: each master takes its original’s name. Another folder: the same folders there, originals left as they are")
            }
            field("Runs on") {
                StudioSegmented(options: [(ArchiveModel.Machine.here, "This Mac"), (.office, "Always-on Mac"), (.both, "Both")], selection: $model.machine)
                    .disabled(model.officeProblem != nil)
                    .help(model.officeProblem ?? String(localized: "Both: the two Macs share the files"))
                StudioSwitchRow(title: "Run overnight", isOn: $model.overnight).help("Keeps this Mac awake while it runs")
            }
            if model.files.contains(where: { ProjectArchive.rawMasterKinds.contains(($0.path as NSString).pathExtension.lowercased()) || $0.codec == "prores_raw" }) {
                Text("RAW: ISO and white balance are baked in as shot, in the camera’s log").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            DisclosureGroup(isExpanded: $more) {
                VStack(alignment: .leading, spacing: 6) {
                    StudioSwitchRow(title: "Also unsorted videos", isOn: $model.other).help("Videos that aren’t clearly rushes. Deliveries are never touched")
                    StudioSwitchRow(title: "Clear proxies and caches", isOn: $model.moveProxies).help("They move to the folder to delete with the originals")
                    Button("Only What a Timeline Used…") { timeline = true }.buttonStyle(.link).font(Design.Studio.body)
                }
                .padding(.top, 6)
            } label: {
                Text("More").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).frame(width: 90, alignment: .leading)
            content()
            Spacer()
        }
    }

    // MARK: Not touched and history

    @ViewBuilder private var untouchedList: some View {
        let list = model.untouched
        HStack {
            Text("Not touched").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            Text(verbatim: bytes(list.reduce(Int64(0)) { $0 + $1.size })).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            Spacer()
            Button("Export CSV…") { export() }.buttonStyle(StudioFlatButtonStyle()).disabled(list.isEmpty)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(list.prefix(200)) { item in
                HStack(spacing: 10) {
                    Text(verbatim: (item.path as NSString).lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: item.project).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: item.reason).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                    Text(verbatim: bytes(item.size)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).frame(width: 72, alignment: .trailing)
                }
                .frame(height: 26)
                .help(item.path)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Not touched.csv")
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.untouchedCSV().write(to: url, atomically: true, encoding: .utf8)
    }

    @ViewBuilder private var history: some View {
        Text("History").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
        ForEach(model.problems, id: \.self) { problem in Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
        ForEach(center.runs.prefix(30)) { run in historyRow(run) }
    }

    private func historyRow(_ run: ShrinkFolders.Run) -> some View {
        let done = run.files.filter { $0.state == .done }
        let failed = run.files.filter { $0.state == .failed }
        let saved = done.reduce(Int64(0)) { $0 + $1.size - ($1.masterSize ?? 0) }
        let ready = center.readyToDelete(run)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(run.date, format: .dateTime.day().month().hour().minute()).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                Text(verbatim: [String(localized: "\(done.count) of \(run.files.count) · saved \(bytes(saved))"),
                                failed.isEmpty ? nil : String(localized: "\(failed.count) failed"),
                                ready.isEmpty ? nil : String(localized: "\(ready.count) originals ready to delete")].compactMap { $0 }.joined(separator: " · "))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                if !center.running {
                    if center.unfinished(run) { Button("Resume") { model.resume(run) }.buttonStyle(.link) }
                    if !ready.isEmpty {
                        Button("Move Originals") { model.moveOriginals(run) }.buttonStyle(.link)
                            .help("Moves the checked originals into “Pluck · Originals to delete” on their share")
                    }
                    if center.canPutBack(run) {
                        Button("Put Originals Back") { model.putBack(run) }.buttonStyle(.link)
                            .help(run.destination == nil ? "Masters to the Trash, originals back in their place" : "The masters of this run to the Trash")
                    }
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting(model.places(run)) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Show in Finder")
            }
            .font(Design.Studio.hint)
            ForEach(failed.prefix(10)) { file in
                Text(verbatim: "\((file.path as NSString).lastPathComponent): \(file.note ?? "")").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    .lineLimit(1).truncationMode(.middle).help(file.path)
            }
        }
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
