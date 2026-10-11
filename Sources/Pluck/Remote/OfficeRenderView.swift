import AppKit
import SwiftUI

/// The Edit Anywhere window: render and search footage on another Mac (the host) from this one,
/// or share this Mac as the host others connect to. Laid out like the main window: cards with
/// the download rows' fill, glass bars and round glass buttons.
struct OfficeRenderView: View {
    enum Side: String { case home, office }
    @AppStorage("officeRenderSide") private var side = Side.home

    var body: some View {
        ScrollView {
            Group {
                switch side {
                case .home: HomeRenderView()
                case .office: OfficeSideView()
                }
            }
            .padding(Design.Spacing.window)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .softTopScrollEdge()
        .frame(minWidth: 620, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("This Mac", selection: $side) {
                    Label("Use Another Mac", systemImage: "laptopcomputer").tag(Side.home)
                    Label("Share This Mac", systemImage: "desktopcomputer").tag(Side.office)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .help("Use another Mac from this one, or share this Mac with others")
            }
        }
    }
}

/// The lock line at the bottom of both sides; the details are in its hint.
private struct PrivacyNote: View {
    let text: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .help(Text(detail))
    }
}

/// A small round glass button for an action in a row (cancel, fetch, remove).
private struct RowButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .buttonStyle(BarButtonStyle())
        .controlSize(.small)
        .scaleEffect(0.82)
        .accessibilityLabel(Text(label))
        .help(Text(label))
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
    @State private var pairingWithCode = false
    @AppStorage("editAnywherePane") private var pane = Pane.render

    enum Pane: String { case render, archive }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            if let office = client.office {
                paired(office)
            } else {
                welcome
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
            Text("This Mac joins that Mac’s private network and pairs with it, so you can render there from anywhere. Only accept invitations from people you trust.")
        }
        .task(id: client.office?.device) {
            guard client.office != nil else { return }
            await run { try await client.refresh() }
            if client.jobs.contains(where: { $0.state == "rendering" || $0.makingPreview }) { client.follow() }
        }
    }

    // MARK: Not connected yet

    private var welcome: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "globe.europe.africa")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 84, height: 84)
                    .background(Color.accentColor.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                Text("Edit from anywhere").font(.title2.weight(.semibold))
                Text("Render on another Mac and search its footage, from home or on the road.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 28)

            VStack(spacing: Design.Spacing.controls) {
                GlassGroup(spacing: Design.Spacing.controls) {
                    HStack(spacing: Design.Spacing.controls) {
                        HStack(spacing: Design.Spacing.controls) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: Design.Size.icon - 2, weight: .medium))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField("Paste the invitation link you received", text: $inviteText)
                                .textFieldStyle(.plain)
                                .font(Design.Typography.control)
                                .onSubmit(joinTyped)
                        }
                        .barControl()
                        Button("Join", action: joinTyped)
                            .buttonStyle(BarCapsuleButtonStyle())
                            .disabled(PrivateNetwork.Invitation(link: inviteText) == nil || working)
                    }
                }
                .frame(maxWidth: 560)
                activity
            }

            Button(pairingWithCode ? "Hide pairing with a code" : "On the same network? Pair with a code instead") {
                withAnimation(.snappy(duration: 0.25)) { pairingWithCode.toggle() }
            }
            .buttonStyle(.link)
            .font(.callout)

            if pairingWithCode {
                codePairing
                    .frame(maxWidth: 560)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            PrivacyNote(text: "Private and encrypted. Invitations and codes work once.",
                        detail: "Everything between the two Macs is encrypted and signed, and the host Mac is never open to the internet.")
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.found) { _, found in
            if picked == nil, address.isEmpty, let first = found.first { picked = first }
        }
    }

    private var codePairing: some View {
        Card {
            CardHeader(symbol: "number", title: Text("Pair with a code"),
                       subtitle: Text("On the host Mac: Share This Mac → Pair a Mac."))
            VStack(spacing: Design.Spacing.controls) {
                if !finder.found.isEmpty {
                    Picker("Host Mac", selection: $picked) {
                        ForEach(finder.found) { Text($0.name).tag(Optional($0)) }
                        Text("Other (type its address)").tag(OfficeFinder.Found?.none)
                    }
                    .pickerStyle(.menu)
                }
                if picked == nil {
                    TextField("Host Mac address", text: $address, prompt: Text("Its address on the local network, e.g. 10.0.0.13"))
                        .textFieldStyle(.plain)
                        .font(Design.Typography.control)
                        .barControl()
                }
                HStack(spacing: Design.Spacing.controls) {
                    TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX"))
                        .textFieldStyle(.plain)
                        .font(Design.Typography.control.monospaced())
                        .barControl()
                    Button("Pair") {
                        let target: OfficeRenderClient.Target = picked.map { .found($0.endpoint) } ?? .address(address)
                        Task { await run { try await client.pair(target, code: code); code = "" } }
                    }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled((picked == nil && address.trimmingCharacters(in: .whitespaces).isEmpty) || OfficeLink.normalised(code) == nil || working)
                }
            }
        }
    }

    /// Joining or pairing in progress, or what went wrong.
    @ViewBuilder
    private var activity: some View {
        if joining {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting… The first time takes up to a minute.").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Connected

    @ViewBuilder
    private func paired(_ office: OfficeRenderClient.Office) -> some View {
        Card {
            CardHeader(symbol: "desktopcomputer", title: Text(office.name),
                       subtitle: office.network != nil ? Text("Connected from anywhere") : Text("Connected on the local network (\(office.address))"),
                       tint: .green) {
                Menu {
                    Button("Unpair This Mac", role: .destructive) { client.forget(); projects = []; project = nil }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(BarButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Forget the host Mac on this Mac. Remove this Mac on the host Mac too.")
            }
        }

        Picker("", selection: $pane) {
            Label("Render", systemImage: "play.rectangle").tag(Pane.render)
            Label("Search the Archive", systemImage: "sparkle.magnifyingglass").tag(Pane.archive)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)

        if pane == .archive {
            ArchiveSearchPane()
        } else {
            renderPane
        }
        activity
    }

    @ViewBuilder
    private var renderPane: some View {
        Card {
            CardHeader(symbol: "play.rectangle.on.rectangle", title: Text("Render on the host Mac"),
                       subtitle: Text("With the originals on its storage; you get a small preview back.")) {
                Button {
                    Task { await run { projects = try await client.projects() } }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BarButtonStyle())
                .disabled(working)
                .help(projects.isEmpty ? "Load the projects" : "Reload the projects")
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Project").foregroundStyle(.secondary)
                    Picker("Project", selection: $project) {
                        Text(projects.isEmpty ? String(localized: "Load the projects first") : String(localized: "Choose…"))
                            .tag(OfficeRenderClient.Project?.none)
                        ForEach(projects) { project in
                            Text((project.folder + [project.name]).joined(separator: " › ")).tag(Optional(project))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Timeline").foregroundStyle(.secondary)
                    Picker("Timeline", selection: $timeline) {
                        ForEach(timelines, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(timelines.isEmpty)
                }
                GridRow {
                    Text("Preset").foregroundStyle(.secondary)
                    Picker("Render preset", selection: $preset) {
                        ForEach(presets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(presets.isEmpty)
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    guard let project else { return }
                    Task { await run { try await client.render(project, timeline: timeline, preset: preset) } }
                } label: {
                    Label("Render", systemImage: "play.fill")
                }
                .buttonStyle(BarCapsuleButtonStyle())
                .disabled(project == nil || timeline.isEmpty || preset.isEmpty || working)
                .help("Opening a project switches DaVinci Resolve on the host Mac to it")
            }
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

        HStack {
            Text("Renders").font(.headline)
            Spacer()
            Button {
                Task { await run { try await client.refresh() } }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Refresh")
        }
        .padding(.top, 4)
        if client.jobs.isEmpty {
            Text("Nothing rendered on the host Mac yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            VStack(spacing: 8) {
                ForEach(client.jobs) { job in row(job) }
            }
        }
    }

    private func row(_ job: OfficeRenderClient.Job) -> some View {
        let (symbol, colour) = Self.look(job.state)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: Design.Size.icon, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 40, height: 40)
                .background(colour.opacity(0.14), in: .rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.timeline).fontWeight(.semibold).lineLimit(1)
                Text(verbatim: "\(job.project) · \(job.preset) · \(job.device)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch job.state {
                case "rendering":
                    ProgressView(value: job.progress).tint(colour)
                    if let remaining = job.remaining, remaining > 0 {
                        Text("About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case "done":
                    Text(job.makingPreview ? String(localized: "Rendered · making the preview…")
                         : job.file.map { String(localized: "Rendered · \($0)") } ?? String(localized: "Rendered"))
                        .font(.caption).foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                default:
                    Text(job.problem ?? (job.state == "cancelled" ? String(localized: "Cancelled") : String(localized: "Failed")))
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if job.state == "rendering" {
                RowButton(symbol: "xmark", label: "Cancel the render") {
                    Task { await run { try await client.cancel(job) } }
                }
            } else if let size = job.previewSize {
                if let fraction = downloading[job.id] {
                    ProgressView(value: fraction).frame(width: 70)
                } else {
                    RowButton(symbol: "arrow.down", label: "Get the preview (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))") {
                        fetch(job)
                    }
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(0.6)
        }
    }

    private static func look(_ state: String) -> (String, Color) {
        switch state {
        case "rendering": ("film", .accentColor)
        case "done": ("checkmark", .green)
        case "cancelled": ("xmark", .secondary)
        default: ("exclamationmark.triangle", .red)
        }
    }

    // MARK: Actions

    private func joinTyped() {
        if let invitation = PrivateNetwork.Invitation(link: inviteText) { join(invitation) }
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
            Card {
                CardHeader(symbol: "desktopcomputer", title: Text("Share this Mac"),
                           subtitle: Text("Paired Macs render and search footage on this Mac. Keep Pluck and DaVinci Resolve open.")) {
                    Toggle("On", isOn: Binding(get: { enabled }, set: { server.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if let problem = server.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }

            if enabled {
                rendersCard
                anywhereCard
                archiveCard
                devicesCard
            }

            PrivacyNote(text: "Only Macs you pair get in. Never open to the internet.",
                        detail: "Only Macs paired with a code or invitation from this Mac get in, and only from the local network or the private network; it never answers the open internet. Every message is encrypted and signed. Paired Macs can only list projects, timelines and presets, render into the render folder, cancel, fetch previews and search the footage folders.")
                .padding(.top, 4)
        }
        .sheet(item: $invitation) { link in InvitationSheet(link: link.url) }
    }

    // MARK: Renders

    private var rendersCard: some View {
        Card {
            let rendering = server.jobs.filter { $0.state == .rendering }.count
            CardHeader(symbol: "film", title: Text("Renders"),
                       subtitle: Text("Where renders for paired Macs go.")) {
                if rendering > 0 {
                    StatusChip(text: Text("^[\(rendering) render](inflect: true) running"), colour: .accentColor, busy: true)
                }
            }
            HStack(spacing: Design.Spacing.controls) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(folder.isEmpty ? Color.orange : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(folder.isEmpty ? String(localized: "No render folder chosen yet") : folder)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                        .help(folder)
                }
                .font(Design.Typography.control)
                .frame(maxWidth: .infinity, alignment: .leading)
                .barControl()
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(GlassCapsuleButtonStyle())
            }
            if server.jobs.contains(where: { $0.state != .rendering }) {
                HStack {
                    Text("^[\(server.jobs.count) render](inflect: true) in the list").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Finished") { server.clearFinished() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: From anywhere

    private var anywhereCard: some View {
        Card {
            CardHeader(symbol: "globe.europe.africa", title: Text("From anywhere"),
                       subtitle: Text("Other Macs connect from anywhere over a private network built into Pluck.")) {
                anywhereStatus
            }
            if PrivateNetwork.helper == nil {
                Text("This build of Pluck doesn’t have the private network part.").foregroundStyle(.secondary)
            } else if !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
                HStack(spacing: Design.Spacing.controls) {
                    HStack(spacing: Design.Spacing.controls) {
                        Image(systemName: "key").foregroundStyle(.secondary).accessibilityHidden(true)
                        SecureField("Tailscale access token", text: $token, prompt: Text("Tailscale access token (tskey-api-…)"))
                            .textFieldStyle(.plain)
                            .font(Design.Typography.control)
                    }
                    .barControl()
                    Button("Connect") {
                        server.connectAccount(token: token)
                        token = ""
                        tokenSaved = true
                    }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(!token.trimmingCharacters(in: .whitespaces).hasPrefix("tskey-api-"))
                }
                Link("Where do I get a token?", destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!)
                    .font(.caption)
                    .help("In your Tailscale account: Settings → Keys → Generate access token. Nobody else needs an account or the Tailscale app.")
            } else {
                switch server.network.state {
                case .running(let name, let address):
                    HStack {
                        Text("Reachable as \(name.isEmpty ? address : name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if inviting { ProgressView().controlSize(.small) }
                        Button {
                            makeInvitation()
                        } label: {
                            Label("Invite a Mac", systemImage: "envelope")
                        }
                        .buttonStyle(BarCapsuleButtonStyle())
                        .disabled(inviting)
                        .help("A one-time link for the Mac you want to connect, valid for a day")
                    }
                case .failed(let message):
                    HStack {
                        Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") { server.startNetwork() }.buttonStyle(GlassCapsuleButtonStyle())
                    }
                case .off:
                    HStack {
                        Spacer()
                        Button("Connect") { server.startNetwork() }.buttonStyle(BarCapsuleButtonStyle())
                    }
                case .starting:
                    EmptyView()
                }
                if let problem = server.networkProblem ?? inviteProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var anywhereStatus: some View {
        if PrivateNetwork.helper != nil {
            if !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
                StatusChip(text: Text("Not set up"), colour: .secondary)
            } else {
                switch server.network.state {
                case .running: StatusChip(text: Text("Ready"), colour: .green)
                case .starting: StatusChip(text: Text("Connecting"), colour: .accentColor, busy: true)
                case .failed: StatusChip(text: Text("Problem"), colour: .orange)
                case .off: StatusChip(text: Text("Off"), colour: .secondary)
                }
            }
        }
    }

    // MARK: Footage

    private var archiveCard: some View {
        Card {
            CardHeader(symbol: "sparkle.magnifyingglass", title: Text("Footage to search"),
                       subtitle: Text("Paired Macs search it by what’s in the picture and fetch just the shots they need.")) {
                if archive.working != nil {
                    StatusChip(text: Text("Looking"), colour: .accentColor, busy: true)
                } else if !archive.folders.isEmpty {
                    StatusChip(text: Text("\(archive.indexes.count) of \(archive.fileCount) searchable"), colour: .green)
                }
            }
            if !archive.folders.isEmpty {
                VStack(spacing: 6) {
                    ForEach(archive.folders, id: \.self) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.lastPathComponent).lineLimit(1)
                                Text(folder.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            RowButton(symbol: "minus", label: "Stop searching this folder") { archive.remove(folder) }
                        }
                    }
                }
            }
            if let working = archive.working {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: archive.progress)
                    Text("Looking at “\(working)” (\(archive.queued) more)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Button {
                    addArchiveFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                Spacer()
                if !archive.folders.isEmpty, archive.working == nil {
                    Button("Look Again") { archive.scan() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Look for new footage now (it also happens by itself every few hours)")
                }
            }
        }
    }

    // MARK: Paired Macs

    private var devicesCard: some View {
        Card {
            CardHeader(symbol: "laptopcomputer.and.iphone", title: Text("Paired Macs")) {
                if !server.devices.isEmpty {
                    StatusChip(text: Text("\(server.devices.count)"), colour: .accentColor)
                }
            }
            if server.devices.isEmpty {
                Text("None yet. Invite a Mac, or pair one on the same network with a code.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(server.devices) { device in
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Group {
                            if let seen = server.lastSeen[device.id] {
                                Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                            } else {
                                Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RowButton(symbol: "xmark", label: "Remove: it can’t connect any more until it’s paired again", tint: .red) {
                        server.remove(device)
                    }
                }
            }
            if let pairing = server.pairing {
                codePanel(pairing)
            } else {
                HStack {
                    if let name = server.justPaired {
                        Label("\(name) is paired.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                    Spacer()
                    Button("Pair a Mac on This Network…") { server.startPairing() }
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .disabled(!server.isRunning)
                        .help("For a Mac on the same network; Macs elsewhere get an invitation")
                }
            }
        }
    }

    private func codePanel(_ pairing: (code: String, expires: Date)) -> some View {
        VStack(spacing: 8) {
            Text("On the other Mac, open Tools → Edit Anywhere and type:").font(.callout).foregroundStyle(.secondary)
            Text(OfficeLink.formatted(pairing.code))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            if let address = OfficeRenderServer.addresses().first {
                Text("Address \(address)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Text("Works once, until \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { server.cancelPairing() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: Design.Radius.box, style: .continuous))
    }

    // MARK: Actions

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
        inviteProblem = nil
        Task {
            do {
                invitation = InvitationLink(url: try await server.invite())
            } catch {
                inviteProblem = error.localizedDescription
            }
            inviting = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Render Here")
        panel.message = String(localized: "Renders for paired Macs go into this folder (on your shared storage, for example).")
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
                        subtitle: Text("Send this link to the Mac you want to connect. When it’s clicked there, Pluck joins this Mac’s private network and pairs with it."),
                        subtitleIsName: false)
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(link.absoluteString)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .barControl()
            Label("Works once, for 24 hours, for the first Mac that uses it. Send it only to people you trust.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Design.Spacing.controls) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(BarCapsuleButtonStyle())
                ShareLink(item: link, subject: Text("Edit Anywhere invitation"),
                          message: Text("Click this link on your Mac to connect Pluck to the host Mac:")) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
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
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    HStack(spacing: Design.Spacing.controls) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: Design.Size.icon - 2, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search", text: $query, prompt: Text("Describe a shot: “crowd with confetti”, “drone over the stage”"))
                            .textFieldStyle(.plain)
                            .font(Design.Typography.control)
                            .onSubmit { search() }
                    }
                    .barControl()
                    filter(movement?.label ?? String(localized: "Any Movement"), symbol: "video", active: movement != nil) {
                        Button("Any Movement") { movement = nil }
                        Divider()
                        ForEach(VisualIndex.Movement.allCases, id: \.self) { m in Button(m.label) { movement = m } }
                    }
                    filter(framing?.label ?? String(localized: "Any Framing"), symbol: "viewfinder", active: framing != nil) {
                        Button("Any Framing") { framing = nil }
                        Divider()
                        ForEach(VisualIndex.Framing.allCases, id: \.self) { f in Button(f.label) { framing = f } }
                    }
                    Button(action: search) {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(BarButtonStyle(prominent: true))
                    .disabled(searching)
                    .accessibilityLabel("Search")
                    .help("Search")
                }
            }
            HStack(spacing: 8) {
                if searching {
                    ProgressView().controlSize(.small)
                    Text("Searching the footage…")
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let status {
                    Text(status.folders == 0 ? String(localized: "The host Mac has no footage folders to search yet. Add them there, under Edit Anywhere.")
                         : status.working ? String(localized: "\(status.indexed) of \(status.files) files searchable; the host Mac is still looking at the rest.")
                         : String(localized: "\(status.indexed) files searchable."))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if searched && hits.isEmpty && !searching {
                ContentUnavailableView("Nothing found", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Try other words."))
                    .frame(minHeight: 180)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(hits) { hit in card(hit) }
                }
            }
        }
        .task { status = try? await client.archiveStatus() }
    }

    /// A filter menu with the search field's height and look (as in Find Shots).
    private func filter<Items: View>(_ title: String, symbol: String, active: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(Design.Typography.control)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .barControl()
        .help(title)
    }

    private func card(_ hit: OfficeRenderClient.ArchiveHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = hit.thumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                Text(Duration.seconds(hit.end - hit.start).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: Design.Radius.badge))
                    .padding(6)
            }
            Text(hit.description).font(.callout).lineLimit(2).help(hit.description)
            HStack(spacing: 6) {
                Text(hit.place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(hit.place)
                Spacer(minLength: 4)
                if let url = fetched[hit.id] {
                    RowButton(symbol: "magnifyingglass", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else if let progress = fetching[hit.id] {
                    ProgressView(value: progress).frame(width: 50)
                } else {
                    RowButton(symbol: "arrow.down", label: "Get a light 1080p copy of this shot, with a second either side") { fetch(hit) }
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(0.6)
        }
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
