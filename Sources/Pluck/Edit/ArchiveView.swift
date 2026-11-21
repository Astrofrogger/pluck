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
    @State private var relinking: ShrinkFolders.Run?
    @State private var relinkingBack: ShrinkFolders.Run?
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
        // "Safe" kept current: every 30 s while the page is showing, and when a drive comes or goes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await model.refreshSpace() }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in Task { await model.refreshSpace() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in Task { await model.refreshSpace() } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $relinking) { run in RelinkSheet(run: run) { center.markRelinked(run.id) } }
        .sheet(item: $relinkingBack) { run in RelinkSheet(run: run, back: true) { center.markRelinked(run.id, false) } }
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
                if model.freedSoFar > 0 {
                    Text("Freed so far \(bytes(model.freedSoFar))").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                        .help("Only what you’ve deleted from “Pluck · Originals to delete”")
                }
            }
            if let now = model.archivingNow { archiving(now) }
            if !model.waiting.isEmpty { waitingList }
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

    /// What's in each share's folder to delete: the space only comes back once it's deleted.
    private var waitingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Waiting to delete").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Spacer()
                Text(verbatim: bytes(model.waiting.reduce(Int64(0)) { $0 + $1.bytes })).font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.text)
            }
            ForEach(model.waiting) { place in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: place.share).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                        Spacer()
                        if place.safe > 0 {
                            Text("Safe to delete \(bytes(place.safe))").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.good)
                        }
                        if place.unsafe > 0 {
                            Text("Not checked \(bytes(place.unsafe))").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                        }
                        if place.notSafe > 0 {
                            Text("Not safe \(bytes(place.notSafe))").font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.bad)
                        }
                        Button("Check") { model.check(place) }.buttonStyle(.link).font(Design.Studio.hint)
                            .disabled(center.checking != nil || center.running).help("Reads every master again before you delete its original")
                        if !place.safeFiles.isEmpty {
                            Button { Task { NSWorkspace.shared.activateFileViewerSelecting(await model.safeToReveal(place)) } } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Show what’s safe to delete in Finder")
                        }
                    }
                    ForEach(place.notSafeFiles.prefix(5), id: \.self) { line in
                        Text(verbatim: line).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).lineLimit(1).truncationMode(.middle)
                    }
                    if !place.unsafeFiles.isEmpty {
                        let names = place.unsafeFiles.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (place.unsafeFiles.count > 3 ? "…" : "")
                        Text("Don’t delete yet: \(names)")
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).lineLimit(2)
                            .help(place.unsafeFiles.joined(separator: "\n"))
                    }
                    if let bin = place.recycle {
                        Text("Deleted files stay in \(bin) on this share until it’s emptied").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    }
                }
            }
            Text("Safe means a checked master exists — at master quality, not the original’s.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            Text("Space comes back once you delete these. On TrueNAS, snapshots keep deleted files until they expire.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
        }
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
            Text("Pauses only for editing on this Mac: another Mac using a file over the network can’t be seen")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            if !center.running, let why = center.runs.first(where: center.unfinished)?.paused {
                Text(verbatim: why).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
            }
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
        // Grouped by client, the clients that free most first; each client's switch turns all its projects on or off.
        let order: (ArchiveModel.ProjectRow, ArchiveModel.ProjectRow) -> Bool = { ($0.dim == nil ? 0 : 1, -$0.saving) < ($1.dim == nil ? 0 : 1, -$1.saving) }
        let clients = model.clients.map { ($0.name, $0.projects.sorted(by: order)) }
            .sorted { a, b in (a.1.reduce(Int64(0)) { $0 + $1.saving }, b.0) > (b.1.reduce(Int64(0)) { $0 + $1.saving }, a.0) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(showAll ? clients : Array(clients.prefix(15)), id: \.0) { name, rows in
                if rows.count == 1, rows[0].project.name == rows[0].project.client {
                    projectRow(rows[0])
                } else {
                    clientRow(name, rows)
                    ForEach(rows) { row in projectRow(row, grouped: true) }
                }
            }
            if clients.count > 15, !showAll {
                Button("\(clients.count - 15) more clients") { showAll = true }.buttonStyle(.link).font(Design.Studio.hint).padding(.top, 8)
            }
        }
    }

    /// A client's line: one switch for all its projects that can be archived (mixed when some are off).
    private func clientRow(_ name: String, _ rows: [ArchiveModel.ProjectRow]) -> some View {
        let open = rows.filter { $0.dim == nil }
        let on = open.filter(\.selected).count
        let saving = rows.filter { $0.selected && $0.dim == nil }.reduce(Int64(0)) { $0 + $1.saving }
        return HStack(spacing: 10) {
            Button { model.select(open.map(\.project), on < open.count) } label: {
                Image(systemName: on == 0 ? "square" : on == open.count ? "checkmark.square.fill" : "minus.square.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(on == 0 ? Design.Studio.textQuiet : Design.Brand.pink)
            }
            .buttonStyle(.plain)
            .disabled(open.isEmpty)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(on == 0 ? Text("Off") : on == open.count ? Text("On") : Text("Some"))
            Text(verbatim: name).font(Design.Studio.body.weight(.semibold)).foregroundStyle(Design.Studio.text).lineLimit(1)
            Text(verbatim: "\(rows.count)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            Spacer(minLength: 8)
            Text(verbatim: saving > 0 ? "−" + bytes(saving) : "").font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Brand.pink)
                .frame(width: 80, alignment: .trailing)
        }
        .frame(height: 30)
        .padding(.top, 6)
        .opacity(open.isEmpty ? 0.55 : 1)
        .help(String(localized: "All of this client's projects on or off"))
        .contextMenu { sizeMenu(rows.map(\.project)) }
    }

    private func projectRow(_ row: ArchiveModel.ProjectRow, grouped: Bool = false) -> some View {
        let project = row.project
        let below = Set(model.files.filter { $0.project == project.folder }.map { ($0.path as NSString).deletingLastPathComponent }).filter { $0 != project.folder }.sorted()
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { row.selected && row.dim == nil }, set: { model.select([project], $0) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(row.dim != nil)
            (grouped ? Text(verbatim: project.name).foregroundStyle(Design.Studio.text)
             : Text(verbatim: project.client).foregroundStyle(Design.Studio.text)
                + Text(verbatim: project.name == project.client ? "" : " – " + project.name).foregroundStyle(Design.Studio.textQuiet))
                .font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let choice = model.choices[project.folder] {
                Menu { sizeMenu([project]) } label: {
                    StudioChip(text: choice == .k4 ? Text(verbatim: "4K") : Text("Skip"), colour: choice == .skip ? Design.Studio.warn : Design.Studio.textQuiet, tinted: true)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize().help("This project’s size")
            }
            if let dim = row.dim { Text(verbatim: dim).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
            Text(verbatim: bytes(project.total)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).frame(width: 72, alignment: .trailing)
            Text(verbatim: row.saving > 0 ? "−" + bytes(row.saving) : "").font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Brand.pink)
                .frame(width: 80, alignment: .trailing)
        }
        .frame(height: 30)
        .padding(.leading, grouped ? 24 : 0)
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
            Divider()
            sizeMenu([project])
        }
    }

    /// Size: Default / Keep 4K / Skip, for a project or all of a client's.
    @ViewBuilder private func sizeMenu(_ projects: [ShrinkFolders.Project]) -> some View {
        Menu("Size") {
            Button("Default") { model.choose(projects, nil) }
            Button("Keep 4K") { model.choose(projects, .k4) }
            Button("Skip") { model.choose(projects, .skip) }
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
            if let short = model.spaceShort {
                HStack(spacing: 8) {
                    Text(verbatim: short).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).fixedSize(horizontal: false, vertical: true)
                    Button("To Another Folder or NAS…") { model.destination = pickFolder() ?? model.destination }.buttonStyle(.link).font(Design.Studio.hint)
                }
                .padding(.leading, 102)
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
                    if run.files.contains(where: { $0.state == .done }) {
                        Button("Relink in Resolve…") { relinking = run }.buttonStyle(.link)
                            .help("Points the clips of the Resolve projects you choose at their masters")
                    }
                    if run.files.contains(where: { $0.state == .done }) {
                        if center.checking == run.id {
                            Text("Checking…").foregroundStyle(Design.Studio.textQuiet)
                        } else {
                            Button("Check Before Deleting") { model.check(run) }.buttonStyle(.link).disabled(center.checking != nil)
                                .help("Reads every master again from the drive and looks at its original before you delete anything")
                        }
                    }
                    if center.canPutBack(run) {
                        Button("Put Originals Back") { model.putBack(run) }.buttonStyle(.link).disabled(center.checking != nil)
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
            ForEach(run.files.filter { $0.problem != nil }.prefix(10)) { file in
                Text(verbatim: "\((file.path as NSString).lastPathComponent): \(file.problem ?? "")").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    .lineLimit(2).truncationMode(.middle).help(file.path)
            }
            ForEach(run.proxyNotes.map { Array($0.values).sorted() } ?? [], id: \.self) { note in
                Text(verbatim: note).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            }
            ForEach(model.checks(run).filter { $0.checked > 0 || !$0.problems.isEmpty }) { project in
                if project.safe {
                    Text("\(project.title) · \(project.masters) masters checked · safe to delete").font(Design.Studio.hint).foregroundStyle(Design.Studio.good)
                } else {
                    Text(verbatim: project.title).font(Design.Studio.hint).foregroundStyle(project.problems.isEmpty ? Design.Studio.warn : Design.Studio.bad)
                    ForEach(project.problems.prefix(10), id: \.self) { problem in
                        Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).lineLimit(2).padding(.leading, 12)
                    }
                    if !project.finished {
                        Text("Not finished: don’t delete yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).padding(.leading, 12)
                    }
                    if project.checked < project.masters {
                        Text("\(project.masters - project.checked) not checked: don’t delete yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).padding(.leading, 12)
                    }
                }
            }
            if run.relinked != nil, !ShrinkRelink.map([run], back: true).isEmpty {
                HStack(spacing: 8) {
                    Text("Resolve projects relinked to these masters now point at removed files").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    Button("Relink to Originals…") { relinkingBack = run }.buttonStyle(.link).font(Design.Studio.hint)
                }
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


/// Relink in Resolve: the projects to point at this run's masters, chosen from Resolve's project
/// manager or as .drp files; nothing is opened that isn't chosen.
private struct RelinkSheet: View {
    let run: ShrinkFolders.Run
    /// Back to the originals after Put Back.
    var back = false
    var relinked: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [String] = []
    @State private var chosen: Set<String> = []
    @State private var files: [URL] = []
    @State private var results: [ShrinkRelink.Result]?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (back ? Text("Relink to Originals") : Text("Relink in Resolve")).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            (back ? Text("\(ShrinkRelink.map([run], back: true).count) originals. Their clips in the projects you choose point at them again; each project is saved.")
             : Text("\(ShrinkRelink.map([run]).count) masters. Their clips in the projects you choose are replaced; each project is saved."))
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(projects, id: \.self) { name in
                        Toggle(isOn: Binding(get: { chosen.contains(name) }, set: { if $0 { chosen.insert(name) } else { chosen.remove(name) } })) {
                            Text(verbatim: name).font(Design.Studio.body)
                        }
                        .toggleStyle(.checkbox)
                    }
                    ForEach(files, id: \.self) { file in
                        Text(verbatim: file.lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
            if let results {
                ForEach(results, id: \.project) { result in
                    Text(verbatim: result.project + " · " + String(localized: "\(result.replaced) relinked") + (result.failed.isEmpty ? "" : " · " + String(localized: "\(result.failed.count) failed")))
                        .font(Design.Studio.hint).foregroundStyle(result.failed.isEmpty ? Design.Studio.textQuiet : Design.Studio.warn)
                }
            }
            Text("A .drp is imported and saved again beside it as “… relinked.drp”. Resolve keeps its own project backups.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            HStack {
                Button("Add .drp…") { addFiles() }.buttonStyle(StudioFlatButtonStyle())
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Relink") { relink() }.buttonStyle(BrandButtonStyle(large: false)).disabled(busy || (chosen.isEmpty && files.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .task {
            do { projects = try await ShrinkRelink.projects() } catch { problem = String(localized: "Open DaVinci Resolve to choose its projects, or add .drp files") }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "drp") ?? .data]
        if panel.runModal() == .OK { files += panel.urls.filter { !files.contains($0) } }
    }

    private func relink() {
        busy = true
        problem = nil
        Task {
            do {
                let done = try await ShrinkRelink.relink([run], projects: projects.filter(chosen.contains), drp: files, back: back)
                results = done
                if done.contains(where: { $0.replaced > 0 }) { relinked() }
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}
