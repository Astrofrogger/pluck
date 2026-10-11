import AppKit
import SwiftUI

/// The Edit Anywhere window: render from this Mac (at home), or let this Mac be the
/// office Mac others render on.
struct OfficeRenderView: View {
    enum Side: String { case home, office }
    @AppStorage("officeRenderSide") private var side = Side.home

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "globe.europe.africa", title: Text("Edit Anywhere"),
                        subtitle: Text("Work from home with the office Mac: DaVinci Resolve there renders your timelines with the originals on the office storage, and you get a preview back."),
                        subtitleIsName: false)
            Picker("", selection: $side) {
                Text("Render from This Mac").tag(Side.home)
                Text("This Mac Is the Office Mac").tag(Side.office)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch side {
            case .home: HomeRenderView()
            case .office: OfficeSideView()
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Spacing.window)
        .frame(minWidth: 560, minHeight: 560)
    }
}

// MARK: - At home

private struct HomeRenderView: View {
    @State private var client = OfficeRenderClient.shared
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?
    @State private var projects: [OfficeRenderClient.Project] = []
    @State private var project: OfficeRenderClient.Project?
    @State private var timelines: [String] = []
    @State private var presets: [String] = []
    @State private var timeline = ""
    @State private var preset = ""
    @State private var downloading: [String: Double] = [:]
    @State private var finder = OfficeFinder()
    @State private var picked: OfficeFinder.Found?
    @State private var inviteText = ""
    @State private var joining = false
    @AppStorage("editAnywherePane") private var pane = Pane.render

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            if let office = client.office {
                paired(office)
            } else {
                pairing
            }
            if joining {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to the office… The first time takes up to a minute.").foregroundStyle(.secondary)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { client.load() }
        .alert(Text("Join “\(client.pendingInvitation?.name ?? "")”?"),
               isPresented: Binding(get: { client.pendingInvitation != nil }, set: { if !$0 { client.pendingInvitation = nil } })) {
            Button("Join") {
                if let invitation = client.pendingInvitation { join(invitation) }
                client.pendingInvitation = nil
            }
            Button("Cancel", role: .cancel) { client.pendingInvitation = nil }
        } message: {
            Text("This Mac joins the office’s private network and pairs with that Mac, so you can render there from anywhere. Only accept invitations from your own team.")
        }
        .task(id: client.office?.device) {
            guard client.office != nil else { return }
            await run { try await client.refresh() }
            if client.jobs.contains(where: { $0.state == "rendering" || $0.makingPreview }) { client.follow() }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.controls) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Got an invitation from the office? Click the link in Messages or Mail, or paste it here.",
                          systemImage: "envelope.open")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Invitation", text: $inviteText, prompt: Text(verbatim: "pluck://edit-anywhere/join?…"))
                            .labelsHidden()
                        Button("Join") {
                            if let invitation = PrivateNetwork.Invitation(link: inviteText) { join(invitation) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(PrivateNetwork.Invitation(link: inviteText) == nil || working)
                    }
                    Text("Works from anywhere: home, a hotel, on the road. Nothing to install.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            Text("At the office, without an invitation").font(.headline).padding(.top, 6)
            Text("On the office Mac: Tools → Edit Anywhere → This Mac Is the Office Mac → Pair a Mac. Then pick it here and type the code.")
                .noteStyle()
            Form {
                if !finder.found.isEmpty {
                    Picker("Office Mac", selection: $picked) {
                        ForEach(finder.found) { Text($0.name).tag(Optional($0)) }
                        Text("Other (type its address)").tag(OfficeFinder.Found?.none)
                    }
                }
                if picked == nil {
                    TextField(finder.found.isEmpty ? "Office Mac" : "Address", text: $address,
                              prompt: Text("Its address on the office network, e.g. 10.0.0.13"))
                }
                LabeledContent("Pairing code") {
                    TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX"))
                        .font(.body.monospaced())
                        .labelsHidden()
                }
            }
            .formStyle(.columns)
            HStack {
                Button("Pair") {
                    let target: OfficeRenderClient.Target = picked.map { .found($0.endpoint) } ?? .address(address)
                    Task { await run { try await client.pair(target, code: code); code = "" } }
                }
                .disabled((picked == nil && address.trimmingCharacters(in: .whitespaces).isEmpty) || OfficeLink.normalised(code) == nil || working)
                if working, !joining { ProgressView().controlSize(.small) }
            }
            Label("Invitations and codes work once. Everything between the two Macs is encrypted, and the office Mac is never open to the internet.",
                  systemImage: "lock.shield")
                .noteStyle()
        }
        .onAppear {
            finder.start()
        }
        .onDisappear { finder.stop() }
        .onChange(of: finder.found) { _, found in
            if picked == nil, address.isEmpty, let first = found.first { picked = first }
        }
    }

    @ViewBuilder
    private func paired(_ office: OfficeRenderClient.Office) -> some View {
        HStack {
            Label(office.network != nil ? String(localized: "Paired with \(office.name), from anywhere")
                                        : String(localized: "Paired with \(office.name) (\(office.address))"),
                  systemImage: "checkmark.shield")
            Spacer()
            Button("Unpair") { client.forget(); projects = []; project = nil }
                .help("Forget the office Mac on this Mac. Remove this Mac on the office Mac too.")
        }
        Picker("", selection: $pane) {
            Text("Render").tag(Pane.render)
            Text("Search the Archive").tag(Pane.archive)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if pane == .archive {
            ArchiveSearchPane()
        } else {
            renderPane
        }
    }

    enum Pane: String { case render, archive }

    @ViewBuilder
    private var renderPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Design.Spacing.controls) {
                HStack {
                    Picker("Project", selection: $project) {
                        Text("Choose…").tag(OfficeRenderClient.Project?.none)
                        ForEach(projects) { project in
                            Text((project.folder + [project.name]).joined(separator: " › ")).tag(Optional(project))
                        }
                    }
                    Button(projects.isEmpty ? "Load Projects" : "Reload") {
                        Task { await run { projects = try await client.projects() } }
                    }
                    .disabled(working)
                }
                Picker("Timeline", selection: $timeline) {
                    ForEach(timelines, id: \.self) { Text($0).tag($0) }
                }
                .disabled(timelines.isEmpty)
                Picker("Render preset", selection: $preset) {
                    ForEach(presets, id: \.self) { Text($0).tag($0) }
                }
                .disabled(presets.isEmpty)
                HStack {
                    Button("Render on the Office Mac") {
                        guard let project else { return }
                        Task { await run { try await client.render(project, timeline: timeline, preset: preset) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(project == nil || timeline.isEmpty || preset.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }
            }
            .padding(6)
        }
        .onChange(of: project) { _, project in
            timelines = []; presets = []; timeline = ""; preset = ""
            guard let project else { return }
            Task {
                await run {
                    let details = try await client.details(project)
                    timelines = details.timelines
                    presets = details.presets
                    timeline = details.current ?? details.timelines.first ?? ""
                    preset = details.presets.first ?? ""
                }
            }
        }
        Text("Opening a project switches DaVinci Resolve on the office Mac to it. The render goes to the office render folder; you get a small preview.")
            .noteStyle()
        jobList
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Renders").font(.headline)
                Spacer()
                Button("Refresh") { Task { await run { try await client.refresh() } } }
                    .controlSize(.small)
            }
            if client.jobs.isEmpty {
                Text("Nothing rendered at the office yet.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(client.jobs) { job in row(job) }
                }
            }
        }
    }

    private func row(_ job: OfficeRenderClient.Job) -> some View {
        HStack(alignment: .center, spacing: Design.Spacing.controls) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.timeline).fontWeight(.medium).lineLimit(1)
                Text(verbatim: "\(job.project) · \(job.preset) · \(job.device)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch job.state {
                case "rendering":
                    ProgressView(value: job.progress)
                    if let remaining = job.remaining, remaining > 0 {
                        Text("About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case "done":
                    Text(job.makingPreview ? String(localized: "Rendered · making the preview…")
                         : job.file.map { String(localized: "Rendered · \($0)") } ?? String(localized: "Rendered"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                default:
                    Text(job.problem ?? (job.state == "cancelled" ? String(localized: "Cancelled") : String(localized: "Failed")))
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if job.state == "rendering" {
                Button("Cancel") { Task { await run { try await client.cancel(job) } } }
            } else if let size = job.previewSize {
                if let fraction = downloading[job.id] {
                    ProgressView(value: fraction).frame(width: 80)
                } else {
                    Button("Get Preview (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))") { fetch(job) }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Design.Radius.control))
    }

    private func fetch(_ job: OfficeRenderClient.Job) {
        downloading[job.id] = 0
        Task {
            await run {
                let file = try await client.downloadPreview(job) { fraction in
                    Task { @MainActor in downloading[job.id] = fraction }
                }
                NSWorkspace.shared.open(file)
            }
            downloading[job.id] = nil
        }
    }

    private func join(_ invitation: PrivateNetwork.Invitation) {
        Task {
            joining = true
            await run { try await client.join(invitation); inviteText = "" }
            joining = false
        }
    }

    private func run(_ work: () async throws -> Void) async {
        working = true
        problem = nil
        do { try await work() } catch { problem = error.localizedDescription }
        working = false
    }
}

// MARK: - On the office Mac

private struct OfficeSideView: View {
    @State private var server = OfficeRenderServer.shared
    @AppStorage(OfficeRenderServer.enabledKey) private var enabled = false
    @AppStorage(OfficeRenderServer.folderKey) private var folder = ""
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var inviting = false
    @State private var invitation: InvitationLink?
    @State private var inviteProblem: String?
    @State private var archive = OfficeArchive.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Toggle(isOn: Binding(get: { enabled }, set: { server.setEnabled($0) })) {
                Text("Let paired Macs render on this Mac")
                Text("Keep Pluck and DaVinci Resolve open on this Mac, logged in to the project library.")
            }
            .toggleStyle(.switch)

            if enabled {
                LabeledContent("Render folder") {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "Not chosen") : folder)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(folder.isEmpty ? .red : .primary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                if let problem = server.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if server.isRunning {
                    fromHome
                }
                if let inviteProblem {
                    Label(inviteProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                archiveBox
                pairingBox
                devicesBox
                if !server.jobs.isEmpty {
                    HStack {
                        Text("\(server.jobs.filter { $0.state == .rendering }.count) rendering, \(server.jobs.count) in the list")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Finished") { server.clearFinished() }
                    }
                }
            }
            Label("Only Macs paired with a code from this Mac get in, and only from the office network or a private connection to it; it never answers the open internet. Every message is encrypted and signed. Paired Macs can only list projects, timelines and presets, render into the render folder, cancel and fetch the preview.",
                  systemImage: "lock.shield")
                .noteStyle()
        }
    }

    /// The private network that lets Macs at home in: connect it once, then invite Macs.
    @ViewBuilder
    private var fromHome: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("From anywhere", systemImage: "globe.europe.africa").font(.headline)
                if PrivateNetwork.helper == nil {
                    Text("This build of Pluck doesn’t have the private network part.").foregroundStyle(.secondary)
                } else if !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
                    Text("To let Macs connect from home, connect this Mac to your Tailscale account once. Nobody else needs an account or the Tailscale app: they get an invitation link.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("Access token", text: $token, prompt: Text(verbatim: "tskey-api-…"))
                        Button("Connect") {
                            server.connectAccount(token: token)
                            token = ""
                            tokenSaved = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!token.trimmingCharacters(in: .whitespaces).hasPrefix("tskey-api-"))
                    }
                    Link("Make an access token in Tailscale (Settings → Keys → Generate access token)…",
                         destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!)
                        .font(.callout)
                } else {
                    switch server.network.state {
                    case .starting:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to the private network…").foregroundStyle(.secondary)
                        }
                    case .running(let name, let address):
                        Label("Ready: Macs you invite reach this one from anywhere.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("On the private network as \(name.isEmpty ? address : name).").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Invite a Mac…") { makeInvitation() }
                                .buttonStyle(.borderedProminent)
                            if inviting { ProgressView().controlSize(.small) }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Try Again") { server.startNetwork() }
                    case .off:
                        Button("Connect to the Private Network") { server.startNetwork() }
                    }
                    if let problem = server.networkProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .sheet(item: $invitation) { link in InvitationSheet(link: link.url) }
        LabeledContent("At the office") {
            Text(OfficeRenderServer.addresses().joined(separator: ", "))
                .textSelection(.enabled).font(.callout.monospaced())
        }
    }

    /// The footage paired Macs can search from home.
    private var archiveBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Footage to search from home", systemImage: "sparkle.magnifyingglass").font(.headline)
                if archive.folders.isEmpty {
                    Text("Add the folders with your footage (on the office storage). This Mac looks at every shot, like Find Shots, so paired Macs can search it by what’s in the picture and fetch just the shots they need.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(archive.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { archive.remove(folder) }.controlSize(.small)
                    }
                }
                HStack {
                    Button("Add Folder…") { addArchiveFolder() }
                    if let working = archive.working {
                        ProgressView(value: archive.progress).frame(width: 100)
                        Text("Looking at “\(working)” (\(archive.queued) more)").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else if !archive.folders.isEmpty {
                        Text("\(archive.indexes.count) of \(archive.fileCount) files searchable").font(.caption).foregroundStyle(.secondary)
                        Button("Look Again") { archive.scan() }.controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func addArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Folders with footage that paired Macs can search. Nothing in them is changed.")
        if panel.runModal() == .OK { for url in panel.urls { archive.add(url) } }
    }

    private func makeInvitation() {
        inviting = true
        Task {
            do {
                invitation = InvitationLink(url: try await server.invite())
            } catch {
                inviteProblem = error.localizedDescription
            }
            inviting = false
        }
    }

    @ViewBuilder
    private var pairingBox: some View {
        GroupBox {
            if let pairing = server.pairing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the other Mac, open Tools → Edit Anywhere and type:")
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Address").foregroundStyle(.secondary)
                            Text(OfficeRenderServer.addresses().first ?? "")
                                .font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        }
                        GridRow {
                            Text("Code").foregroundStyle(.secondary)
                            Text(OfficeLink.formatted(pairing.code))
                                .font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Text("Works once, until \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { server.cancelPairing() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } else {
                HStack {
                    if let name = server.justPaired {
                        Label("\(name) is paired.", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Text("A Mac at the office? Pair it here with a code.")
                    }
                    Spacer()
                    Button("Pair a Mac…") { server.startPairing() }
                        .help("For a Mac on the office network; Macs elsewhere get an invitation")
                        .disabled(!server.isRunning)
                }
                .padding(6)
            }
        }
    }

    private var devicesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired Macs").font(.headline)
            if server.devices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(server.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Group {
                            if let seen = server.lastSeen[device.id] {
                                Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted)) · last seen \(seen.formatted(.relative(presentation: .named)))")
                            } else {
                                Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { server.remove(device) }
                        .help("This Mac can’t render here any more until it’s paired again.")
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Render Here")
        panel.message = String(localized: "Renders for paired Macs go into this folder (on the office storage, for example).")
        if panel.runModal() == .OK, let url = panel.url { server.setRenderFolder(url) }
    }
}

private struct InvitationLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The invitation, ready to send.
private struct InvitationSheet: View {
    let link: URL
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "envelope.badge", title: Text("Invite a Mac"),
                        subtitle: Text("Send this link to a colleague. When they click it, Pluck on their Mac joins the office’s private network and pairs with this Mac."),
                        subtitleIsName: false)
            Text(link.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Design.Radius.control))
            Label("It works once, for 24 hours, and only for the Mac that uses it first. Send it only to your own team.",
                  systemImage: "lock.shield")
                .noteStyle()
            HStack {
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                }
                ShareLink(item: link, subject: Text("Edit Anywhere invitation"),
                          message: Text("Click this link on your Mac to connect Pluck to the office Mac:")) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
    }
}

/// Searching the office footage from here: what's in the picture, the shot size, the camera
/// move; each shot can be fetched as a light copy with a second of handles.
private struct ArchiveSearchPane: View {
    @State private var client = OfficeRenderClient.shared
    @State private var query = ""
    @State private var movement: VisualIndex.Movement?
    @State private var framing: VisualIndex.Framing?
    @State private var hits: [OfficeRenderClient.ArchiveHit] = []
    @State private var searching = false
    @State private var searched = false
    @State private var problem: String?
    @State private var status: (folders: Int, files: Int, indexed: Int, working: Bool)?
    @State private var fetching: [String: Double] = [:]
    @State private var fetched: [String: URL] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.controls) {
            HStack {
                TextField("Search", text: $query, prompt: Text("Describe a shot: “crowd with confetti”, “drone over the stage”"))
                    .onSubmit { search() }
                Picker("Move", selection: $movement) {
                    Text("Any Movement").tag(VisualIndex.Movement?.none)
                    ForEach(VisualIndex.Movement.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
                Picker("Framing", selection: $framing) {
                    Text("Any Framing").tag(VisualIndex.Framing?.none)
                    ForEach(VisualIndex.Framing.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
                Button("Search") { search() }
                    .buttonStyle(.borderedProminent)
                    .disabled(searching)
            }
            if let status {
                Text(status.folders == 0 ? String(localized: "The office Mac has no footage folders to search yet. Add them there, under Edit Anywhere.")
                     : status.working ? String(localized: "\(status.indexed) of \(status.files) files searchable; the office Mac is still looking at the rest.")
                     : String(localized: "\(status.indexed) files searchable."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if searching {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching the office archive…").foregroundStyle(.secondary) }
            } else if searched && hits.isEmpty {
                Text("Nothing found. Try other words.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(hits) { hit in card(hit) }
                }
            }
        }
        .task { status = try? await client.archiveStatus() }
    }

    private func card(_ hit: OfficeRenderClient.ArchiveHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let data = hit.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 96)
            .clipShape(.rect(cornerRadius: Design.Radius.small))
            Text(hit.description).font(.caption).lineLimit(2).help(hit.description)
            Text(hit.place).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(hit.place)
            if let url = fetched[hit.id] {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
            } else if let progress = fetching[hit.id] {
                ProgressView(value: progress).controlSize(.small)
            } else {
                Button("Get Clip") { fetch(hit) }
                    .controlSize(.small)
                    .help("A light 1080p copy of this shot with a second either side")
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Design.Radius.control))
    }

    private func search() {
        searching = true
        problem = nil
        Task {
            do {
                hits = try await client.searchArchive(query, movement: movement, framing: framing)
                searched = true
            } catch {
                problem = error.localizedDescription
            }
            searching = false
        }
    }

    private func fetch(_ hit: OfficeRenderClient.ArchiveHit) {
        fetching[hit.id] = 0
        Task {
            do {
                let url = try await client.fetchClip(hit) { value in
                    Task { @MainActor in fetching[hit.id] = value }
                }
                fetched[hit.id] = url
            } catch {
                problem = error.localizedDescription
            }
            fetching[hit.id] = nil
        }
    }
}
