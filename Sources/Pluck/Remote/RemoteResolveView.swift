import AppKit
import SwiftUI

/// Edit Anywhere's Resolve pane on the editor's Mac: start a project (built on the host, or add the
/// proxies to the open one), render on the host with a preset, the queue, and check-out/versions.
struct RemoteResolvePane: View {
    let host: String
    @State private var model = RemoteResolve.shared
    @State private var shares: [OfficeRenderClient.RemoteShare] = []
    @State private var folders: [String] = []
    @State private var share = ""
    @State private var folder = ""
    @State private var projectID = ""
    @State private var timeline = ""
    @State private var preset = ""
    @State private var working = false
    @State private var problem: String?
    @State private var downloading: [String: Double] = [:]
    @State private var pullingParts = false
    /// A pre-flight that found something the office lacks, shown before sending.
    @State private var pending: RemoteMissing.Plan?

    private var project: RemoteResolve.HostProject? { model.projects.first { $0.id == projectID } }

    var body: some View {
        HStack {
            Text("DaVinci Resolve").font(Design.Studio.sectionTitle)
            Spacer()
            if let step = model.step {
                Text(step).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if working { PlumSpinner() }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(StudioFlatButtonStyle())
                .help("Reload")
                .accessibilityLabel("Reload")
                .disabled(working)
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                .fixedSize(horizontal: false, vertical: true)
        }
        start
        render
        list("Queue", count: model.queue.count, empty: "Nothing queued on \(host).") { ForEach(model.queue) { queueRow($0) } }
        list("Projects", count: model.projects.count, empty: "No projects on \(host) yet.") { ForEach(model.projects) { projectRow($0) } }
            .task(id: share) { await loadFolders() }
            .task { await load() }
    }

    // MARK: Start

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                menu(shares.first { $0.id == share }?.name ?? String(localized: "Share"), quiet: share.isEmpty) {
                    Picker("Share", selection: $share) {
                        ForEach(shares) { Text($0.name).tag($0.id) }
                    }
                }
                menu(folder.isEmpty ? String(localized: "Whole share") : folder) {
                    Picker("Folder", selection: $folder) {
                        Text("Whole share").tag("")
                        ForEach(folders, id: \.self) { Text($0).tag($0) }
                    }
                }
                .disabled(share.isEmpty)
                Spacer(minLength: 0)
                Button { act { try await model.build(share: share, path: folder) } } label: {
                    Label("New project", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(share.isEmpty || working)
                .help("\(host) makes a Resolve project from the originals, with the proxies linked, and opens it here")
            }
            Divider().overlay(Design.Studio.line)
            HStack(spacing: 10) {
                Image(systemName: model.linkable.isEmpty ? "circle.dashed" : "link").foregroundStyle(model.linkable.isEmpty ? Design.Studio.textQuiet : Design.Studio.good)
                if model.linkable.isEmpty {
                    Text("No proxies on this Mac yet").foregroundStyle(Design.Studio.textQuiet)
                } else {
                    Text(model.linkable.map { "\($0.name) · \($0.clips)" }.joined(separator: "   ")).lineLimit(1)
                }
                if let link = model.lastLink {
                    Text("\(link.linked) linked · \(link.added) added").foregroundStyle(Design.Studio.textQuiet)
                }
                Spacer(minLength: 0)
                Button { act { try await model.addFootage() } } label: {
                    Label("Add to current project", systemImage: "film.stack")
                }
                .buttonStyle(StudioFlatButtonStyle())
                .disabled(model.linkable.isEmpty || working)
                .help("Adds this Mac’s proxies to the project open in DaVinci Resolve, a bin per shared folder")
            }
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studioBox()
    }

    // MARK: Render

    private var render: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                menu(project.map { $0.name } ?? String(localized: "New project"), quiet: project == nil) {
                    Picker("Project", selection: $projectID) {
                        Text("New project").tag("")
                        ForEach(model.projects.filter { $0.holder == nil || $0.mine }) { Text($0.name).tag($0.id) }
                    }
                }
                menu(timeline.isEmpty ? "—" : timeline, quiet: timeline.isEmpty) {
                    Picker("Timeline", selection: $timeline) { ForEach(model.local?.timelines ?? [], id: \.self) { Text($0).tag($0) } }
                }
                .disabled(model.local == nil)
                menu(preset.isEmpty ? String(localized: "Preset") : preset, quiet: preset.isEmpty) {
                    Picker("Render preset", selection: $preset) { ForEach(model.presets, id: \.self) { Text($0).tag($0) } }
                }
                .disabled(model.presets.isEmpty)
                Spacer(minLength: 0)
                Button { pullingParts = true } label: { Label("Pull originals…", systemImage: "scissors") }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(model.local == nil || timeline.isEmpty || working)
                    .help("Pulls only the parts of the originals this timeline uses, to finish on this Mac")
                    .sheet(isPresented: $pullingParts) { RemotePiecesSheet(timeline: timeline) }
                Button { act { try await preflightAndRender() } } label: {
                    Label("Render on \(host)", systemImage: "play.fill")
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(model.local == nil || timeline.isEmpty || preset.isEmpty || working)
                .help("Sends the project open in Resolve as a new version, then \(host) renders it from the originals")
            }
            Text(model.local.map { String(localized: "Open in Resolve: \($0.project)") } ?? String(localized: "DaVinci Resolve isn’t open on this Mac."))
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
            if let pending { missing(pending) }
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studioBox()
        .onChange(of: model.local) { _, local in
            if let local, !local.timelines.contains(timeline) { timeline = local.timeline ?? local.timelines.first ?? "" }
        }
        .onChange(of: model.presets) { _, presets in if !presets.contains(preset) { preset = presets.first ?? "" } }
    }

    /// What the office lacks, with what can be done about it.
    private func missing(_ plan: RemoteMissing.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Design.Studio.line)
            if !plan.send.isEmpty {
                line(String(localized: "Only on this Mac: \(RemoteMissing.summary(plan.send))"))
                if !plan.takesFiles { hint(String(localized: "The office Mac needs a newer Pluck to receive them.")) }
            }
            if !plan.stuck.isEmpty {
                line(String(localized: "Read by Fusion or a grade, only on this Mac: \(plan.stuck.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))"))
                hint(String(localized: "Copy them into a share and relink them in DaVinci Resolve."))
            }
            ForEach(plan.fonts, id: \.self) { line(RemoteMissing.problem($0)) }
            ForEach(plan.effects, id: \.self) { line(RemoteMissing.problem($0)) }
            if !plan.fonts.isEmpty || !plan.effects.isEmpty {
                hint(String(localized: "Resolve would use another font or leave the effect out. Install them on the office Mac (licences apply)."))
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { pending = nil }.buttonStyle(StudioFlatButtonStyle())
                if plan.canSend {
                    Button { renderWith(plan) } label: { Label("Send Missing Files and Render", systemImage: "arrow.up.doc") }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32)).disabled(working)
                } else if plan.canRenderAnyway {
                    Button { renderWith(plan) } label: { Label("Render Anyway", systemImage: "play.fill") }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32)).disabled(working)
                }
            }
        }
    }

    private func line(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
    }

    private func preflightAndRender() async throws {
        pending = nil
        let plan = try await model.preflight()
        if plan.clean { try await model.render(project, timeline: timeline, preset: preset, plan: plan) } else { pending = plan }
    }

    /// The editor has seen the list: missing fonts and effects don't stop this render.
    private func renderWith(_ plan: RemoteMissing.Plan) {
        pending = nil
        act { try await model.render(project, timeline: timeline, preset: preset, plan: plan, anyway: true) }
    }

    // MARK: Rows

    private func queueRow(_ item: RemoteResolve.QueueItem) -> some View {
        let (symbol, colour) = Self.look(item.state)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StudioTile(symbol: symbol, colour: colour, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.timeline).font(.system(size: 13)).lineLimit(1)
                    Text(verbatim: "\(item.project) v\(item.version) · \(item.preset) · \(item.device)")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                switch item.state {
                case "queued": StudioChip(text: Text("\(item.position ?? 1) in line"))
                case "preparing": StudioChip(text: Text("Checking footage"), symbol: "circle.dotted")
                case "rendering": Text(item.progress, format: .percent.precision(.fractionLength(0))).font(.system(size: 13).monospacedDigit())
                default: EmptyView()
                }
                if item.mine, item.open {
                    Button { act { try await model.cancel(item) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(StudioFlatButtonStyle()).help("Cancel").accessibilityLabel("Cancel")
                } else if item.mine, let size = item.previewSize {
                    if let fraction = downloading[item.id] {
                        StudioProgress(share: fraction).frame(width: 70)
                    } else {
                        Button { fetch(item) } label: {
                            Label("Preview · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))", systemImage: "arrow.down")
                        }
                        .buttonStyle(StudioFlatButtonStyle())
                    }
                }
            }
            if item.state == "rendering" { StudioProgress(share: item.progress) }
            if item.state == "done" {
                Text(item.makingPreview ? String(localized: "Rendered · making the preview…") : item.file.map { String(localized: "Rendered · \($0)") } ?? String(localized: "Rendered"))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.good).lineLimit(1).truncationMode(.middle)
            }
            ForEach(item.problems.prefix(8), id: \.self) { line in
                Text(line).font(Design.Studio.hint).foregroundStyle(item.state == "problems" ? Design.Studio.warn : Design.Studio.bad).lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studioBox()
    }

    private func projectRow(_ project: RemoteResolve.HostProject) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: project.mine ? "lock.fill" : project.holder != nil ? "lock" : "doc", colour: project.mine ? Design.Studio.good : Design.Studio.textQuiet, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 13)).lineLimit(1)
                Text(verbatim: "v\(project.latest) · " + (project.mine ? String(localized: "Checked out here") : project.holder.map { String(localized: "\($0) has it") } ?? String(localized: "Free")))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(project.versions.reversed(), id: \.number) { version in
                    Menu("v\(version.number) · \(version.date.formatted(date: .abbreviated, time: .shortened)) · \(version.by)") {
                        Button("Open in Resolve") { act { try await model.open(project, version: version.number) } }
                        Button("Restore as newest") { act { try await model.restore(project, version: version.number) } }
                            .disabled(version.number == project.latest || (project.holder != nil && !project.mine))
                    }
                }
            } label: { StudioMenuLabel(title: String(localized: "Versions")) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button("Open") { act { try await model.open(project, version: project.latest) } }
                .buttonStyle(StudioFlatButtonStyle())
                .help("Opens the newest version in DaVinci Resolve here, with this Mac’s proxies")
            if project.mine {
                Button("Check in") { act { try await model.checkIn(project, keep: false) } }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .help("Sends the project open in Resolve as a new version and frees it for others")
                Button("Release") { act { try await model.release(project) } }
                    .buttonStyle(StudioFlatButtonStyle())
            } else {
                Button("Check out") { act { try await model.checkOut(project) } }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(project.holder != nil)
            }
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .studioBox()
    }

    // MARK: Pieces

    private func list<Rows: View>(_ title: LocalizedStringKey, count: Int, empty: LocalizedStringKey, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(Design.Studio.sectionTitle)
                Text(verbatim: "\(count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.top, 8)
            if count == 0 {
                Text(empty).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                rows()
            }
        }
    }

    private func menu<Items: View>(_ title: String, quiet: Bool = false, @ViewBuilder items: () -> Items) -> some View {
        Menu { items().pickerStyle(.inline) } label: { StudioMenuLabel(title: title, quiet: quiet) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    static func look(_ state: String) -> (String, Color) {
        switch state {
        case "queued": ("clock", Design.Studio.textQuiet)
        case "preparing", "rendering": ("film", Design.Studio.text)
        case "done": ("checkmark", Design.Studio.good)
        case "cancelled": ("xmark", Design.Studio.textQuiet)
        case "problems": ("exclamationmark.triangle", Design.Studio.warn)
        default: ("exclamationmark.triangle", Design.Studio.bad)
        }
    }

    // MARK: Actions

    private func load() async {
        await run {
            shares = try await OfficeRenderClient.shared.shares()
            if share.isEmpty || !shares.contains(where: { $0.id == share }) { share = shares.first?.id ?? "" }
            try await model.refresh()
        }
        await model.readLocal()
        await model.scanFolders()
        try? await model.loadPresets()
    }

    private func loadFolders() async {
        folders = []
        folder = ""
        guard !share.isEmpty else { return }
        folders = ((try? await OfficeRenderClient.shared.browse(share: share, path: "")) ?? []).filter(\.folder).map(\.name)
    }

    private func fetch(_ item: RemoteResolve.QueueItem) {
        downloading[item.id] = 0
        act {
            defer { downloading[item.id] = nil }
            let file = try await model.downloadPreview(item) { fraction in Task { @MainActor in downloading[item.id] = fraction } }
            NSWorkspace.shared.open(file)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task { await run(work) }
    }

    private func run(_ work: () async throws -> Void) async {
        working = true
        problem = nil
        do { try await work() } catch { problem = error.localizedDescription }
        working = false
    }
}

/// On the host: editors' Resolve renders in line and their projects (who has which, versions).
struct RemoteResolveHostSection: View {
    @State private var queue = RemoteRenderQueue.shared
    @State private var checkout = RemoteCheckout.shared

    var body: some View {
        if !queue.items.isEmpty || !checkout.projects.isEmpty {
            HStack(spacing: 8) {
                Text("Resolve projects from editors").font(Design.Studio.sectionTitle)
                Spacer(minLength: 0)
                if queue.items.contains(where: { !$0.open }) {
                    Button("Clear finished") { queue.clearFinished() }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            .padding(.top, 8)
            ForEach(queue.items.reversed()) { item in
                let (symbol, colour) = RemoteResolvePane.look(item.state.rawValue)
                HStack(spacing: 12) {
                    StudioTile(symbol: symbol, colour: colour, size: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.timeline).font(.system(size: 13)).lineLimit(1)
                        Text(verbatim: "\(item.projectName) v\(item.version) · \(item.preset) · \(item.device)")
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                        if let first = item.problems.first {
                            Text(first).font(Design.Studio.hint).foregroundStyle(item.state == .problems ? Design.Studio.warn : Design.Studio.bad).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if item.state == .rendering { StudioProgress(share: item.progress).frame(width: 90) }
                    if item.state == .queued, let position = queue.position(item.id) { StudioChip(text: Text("\(position) in line")) }
                    if item.open {
                        Button { Task { try? await queue.cancel(item.id, by: nil) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(StudioFlatButtonStyle()).help("Cancel").accessibilityLabel("Cancel")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .studioBox()
            }
            ForEach(checkout.projects) { project in
                HStack(spacing: 12) {
                    StudioTile(symbol: project.holder != nil ? "lock" : "doc", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name).font(.system(size: 13)).lineLimit(1)
                        Text(verbatim: "v\(project.latest) · " + (project.holderName.map { String(localized: "\($0) has it") } ?? String(localized: "Free")))
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if project.holder != nil {
                        Button("Release") { try? checkout.release(project.id, by: nil) }
                            .buttonStyle(StudioFlatButtonStyle())
                            .help("Frees the project so another Mac can check it out")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .studioBox()
            }
        }
    }
}
