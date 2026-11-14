import AppKit
import SwiftUI

/// The Edit Anywhere tool: render and search footage on another Mac (the host) from this one,
/// or share this Mac as the host others connect to. Board ToolAnywhere: a 280 pt panel with the
/// two sides and the host, and the chosen pane on the right.
struct OfficeRenderView: View {
    enum Side: String { case home, office }
    @AppStorage("officeRenderSide") private var side = Side.home

    var body: some View {
        Group {
            switch side {
            case .home: HomeRenderView(side: $side)
            case .office: OfficeSideView(side: $side)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .frame(minWidth: 760)
    }
}

// MARK: - Shared pieces

/// The left panel: the title, the two sides, then what the side puts in it, and a faint footnote.
private struct AnywhereSidebar<Content: View>: View {
    @Binding var side: OfficeRenderView.Side
    var footnote: LocalizedStringKey?
    var footnoteDetail: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Anywhere").font(Design.Studio.pageTitle).padding(.horizontal, 8)
            StudioSegmented(options: [(.home, "Use another Mac"), (.office, "Share this Mac")], selection: $side, fill: true)
                .padding(.horizontal, 8)
                .help("Use another Mac from this one, or share this Mac with others")
            content
            Spacer(minLength: 0)
            if let footnote {
                StudioFootnote(text: footnote, symbol: "checkmark.shield")
                    .help(footnoteDetail ?? Text(footnote))
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .studioPanel()
    }
}

/// A row in the left panel's list: raised grey when it's the one shown.
private struct NavRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let selected: Bool
    var badge: Text?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                Spacer(minLength: 0)
                if let badge { badge.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The right panel, scrolling, with the board's 24/28 pt insets.
private struct AnywherePane<Content: View>: View {
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            } else {
                VStack(spacing: 16) { content }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioPanel()
    }
}

/// A pane's or section's title, with a quiet line under it.
private struct PaneHeader<Trailing: View>: View {
    let title: Text
    var subtitle: Text?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                title.font(Design.Studio.sectionTitle)
                if let subtitle {
                    subtitle.font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: Text, subtitle: Text? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A menu's label in a box: the choice in full text, a small quiet chevron, no button behind it.
private struct PlainMenuLabel: View {
    let title: String
    var quiet = false

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
        }
        .font(Design.Studio.body)
        .foregroundStyle(quiet ? Design.Studio.textQuiet : Design.Studio.text)
        .frame(height: 28)
        .contentShape(.rect)
    }
}

/// A small icon button in a row (cancel, remove, show in Finder).
private struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint = Design.Studio.textQuiet
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A pink text link ("It’s spelled right", "Clear finished").
private struct PinkLink: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).font(Design.Studio.hint).foregroundStyle(Design.Brand.pink) }
            .buttonStyle(.plain)
    }
}

/// What went wrong, in the bad colour.
private struct ProblemLine: View {
    let text: String
    var colour = Design.Studio.bad

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Design.Studio.body)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

extension View {
    /// A text field's dark box on a panel (raised when it sits in a box).
    fileprivate func anywhereInput(inBox: Bool = false, height: CGFloat = 32) -> some View {
        padding(.horizontal, 10)
            .frame(height: height)
            .background(inBox ? Design.Studio.raised : Design.Studio.backdrop,
                        in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    /// A menu with no system button look.
    fileprivate func plainMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - At home

private struct HomeRenderView: View {
    @Binding var side: OfficeRenderView.Side
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

    enum Pane: String { case render, archive, proxies }

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            AnywhereSidebar(side: $side, footnote: client.office != nil ? "Private and encrypted" : nil,
                            footnoteDetail: Text("Everything between the two Macs is encrypted and signed, and the host Mac is never open to the internet.")) {
                if let office = client.office {
                    hostBox(office)
                    VStack(spacing: 2) {
                        NavRow(symbol: "play.rectangle", title: "Render", selected: pane == .render) { pane = .render }
                        NavRow(symbol: "sparkle.magnifyingglass", title: "Search the archive", selected: pane == .archive) { pane = .archive }
                        NavRow(symbol: "arrow.up.arrow.down", title: "Files", selected: pane == .proxies) { pane = .proxies }
                    }
                } else {
                    Text("Join a Mac to render, search and fetch files on it from here.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
            }
            if let office = client.office {
                AnywherePane {
                    switch pane {
                    case .archive: ArchiveSearchPane(host: office.name)
                    case .proxies:
                        ProxiesPane()
                        SendPane().padding(.top, 12)
                    case .render: renderPane(office)
                    }
                    activity
                }
            } else {
                AnywherePane(scrolls: false) { welcome }
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
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                StudioTile(symbol: "globe.europe.africa", colour: Design.Studio.textQuiet)
                    .accessibilityHidden(true)
                    .padding(.bottom, 6)
                Text("Edit from anywhere").font(Design.Studio.sectionTitle)
                Text("Render on another Mac and search its footage, from home or on the road.")
                    .font(Design.Studio.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Design.Studio.textQuiet)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 14))
                        .foregroundStyle(Design.Studio.textQuiet)
                        .accessibilityHidden(true)
                    TextField("Paste the invitation link you received", text: $inviteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit(joinTyped)
                    Button("Join", action: joinTyped)
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                        .disabled(PrivateNetwork.Invitation(link: inviteText) == nil || working)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 48)
                .studioBox(outline: Design.Studio.line)
                activity
            }
            .frame(maxWidth: 560)

            PinkLink(title: pairingWithCode ? "Hide pairing with a code" : "On the same network? Pair with a code instead") {
                withAnimation(.snappy(duration: 0.25)) { pairingWithCode.toggle() }
            }

            if pairingWithCode {
                codePairing
                    .frame(maxWidth: 560)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
            StudioFootnote(text: "Private and encrypted. Invitations and codes work once.", symbol: "checkmark.shield")
                .help("Everything between the two Macs is encrypted and signed, and the host Mac is never open to the internet.")
        }
        .frame(maxWidth: .infinity)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.found) { _, found in
            if picked == nil, address.isEmpty, let first = found.first { picked = first }
        }
    }

    private var codePairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(title: Text("Pair with a code"), subtitle: Text("On the host Mac: Share this Mac → Pair a Mac."))
            if !finder.found.isEmpty {
                StudioField(label: "Host Mac") {
                    Menu {
                        Picker("Host Mac", selection: $picked) {
                            ForEach(finder.found) { Text($0.name).tag(Optional($0)) }
                            Text("Other (type its address)").tag(OfficeFinder.Found?.none)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        PlainMenuLabel(title: picked?.name ?? String(localized: "Other (type its address)"))
                    }
                    .plainMenu()
                }
            }
            if picked == nil {
                TextField("Host Mac address", text: $address, prompt: Text("Its address on the local network, e.g. 10.0.0.13"))
                    .textFieldStyle(.plain)
                    .font(Design.Studio.body)
                    .anywhereInput(inBox: true)
            }
            HStack(spacing: 10) {
                TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX"))
                    .textFieldStyle(.plain)
                    .font(Design.Studio.body.monospaced())
                    .anywhereInput(inBox: true)
                Button("Pair") {
                    let target: OfficeRenderClient.Target = picked.map { .found($0.endpoint) } ?? .address(address)
                    Task { await run { try await client.pair(target, code: code); code = "" } }
                }
                .buttonStyle(StudioFlatButtonStyle(height: 32))
                .disabled((picked == nil && address.trimmingCharacters(in: .whitespaces).isEmpty) || OfficeLink.normalised(code) == nil || working)
            }
        }
        .padding(16)
        .studioBox()
    }

    /// Joining or pairing in progress, or what went wrong.
    @ViewBuilder
    private var activity: some View {
        if joining {
            HStack(spacing: 8) {
                PlumSpinner()
                Text("Connecting… The first time takes up to a minute.").foregroundStyle(Design.Studio.textQuiet)
            }
            .font(Design.Studio.body)
        } else if let problem {
            ProblemLine(text: problem)
        }
    }

    // MARK: Connected

    /// The host Mac: a tile in the good colour, its name, how it's connected, and ⋯ with Unpair.
    private func hostBox(_ office: OfficeRenderClient.Office) -> some View {
        HStack(spacing: 10) {
            StudioTile(symbol: "desktopcomputer", colour: Design.Studio.good, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(office.name).font(Design.Studio.body).lineLimit(1)
                Group {
                    if office.network != nil {
                        Text("Connected from anywhere")
                    } else {
                        Text("Connected on the local network (\(office.address))")
                    }
                }
                .font(Design.Studio.hint)
                .foregroundStyle(Design.Studio.good)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Unpair This Mac", role: .destructive) { client.forget(); projects = []; project = nil }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .plainMenu()
            .help("Forget the host Mac on this Mac. Remove this Mac on the host Mac too.")
        }
        .padding(12)
        .studioBox()
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func renderPane(_ office: OfficeRenderClient.Office) -> some View {
        HStack {
            Text("Render on \(office.name)").font(Design.Studio.sectionTitle)
            Spacer()
            if working { PlumSpinner() }
            IconButton(symbol: "arrow.clockwise", label: projects.isEmpty ? "Load the projects" : "Reload the projects") {
                Task {
                    await run { projects = try await client.projects() }
                    await run { try await client.refresh() }
                }
            }
            .disabled(working)
        }

        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Text("Project").foregroundStyle(Design.Studio.textQuiet)
                Menu {
                    Picker("Project", selection: $project) {
                        Text(projects.isEmpty ? String(localized: "Load the projects first") : String(localized: "Choose…"))
                            .tag(OfficeRenderClient.Project?.none)
                        ForEach(projects) { project in
                            Text((project.folder + [project.name]).joined(separator: " › ")).tag(Optional(project))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    PlainMenuLabel(title: project.map { ($0.folder + [$0.name]).joined(separator: " › ") }
                                   ?? (projects.isEmpty ? String(localized: "Load the projects first") : String(localized: "Choose…")),
                                   quiet: project == nil)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .layoutPriority(1)
            }
            HStack(spacing: 8) {
                Text("Timeline").foregroundStyle(Design.Studio.textQuiet)
                Menu {
                    Picker("Timeline", selection: $timeline) {
                        ForEach(timelines, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    PlainMenuLabel(title: timeline.isEmpty ? "—" : timeline, quiet: timeline.isEmpty)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .disabled(timelines.isEmpty)
            }
            HStack(spacing: 8) {
                Text("Preset").foregroundStyle(Design.Studio.textQuiet)
                Menu {
                    Picker("Render preset", selection: $preset) {
                        ForEach(presets, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    PlainMenuLabel(title: preset.isEmpty ? "—" : preset, quiet: preset.isEmpty)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .disabled(presets.isEmpty)
            }
            Spacer(minLength: 0)
            Button {
                guard let project else { return }
                Task { await run { try await client.render(project, timeline: timeline, preset: preset) } }
            } label: {
                Label("Render", systemImage: "play.fill")
            }
            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            .disabled(project == nil || timeline.isEmpty || preset.isEmpty || working)
            .help("Opening a project switches DaVinci Resolve on the host Mac to it")
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studioBox()
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

        Text("Opening a project switches DaVinci Resolve on \(office.name) to it.")
            .font(Design.Studio.hint)
            .foregroundStyle(Design.Studio.textFaint)

        HStack(spacing: 8) {
            Text("Renders").font(Design.Studio.sectionTitle)
            Text(verbatim: "\(client.jobs.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        }
        .padding(.top, 8)
        if client.jobs.isEmpty {
            Text("Nothing rendered on \(office.name) yet.")
                .font(Design.Studio.body)
                .foregroundStyle(Design.Studio.textQuiet)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ForEach(client.jobs) { job in row(job) }
        }
    }

    private func row(_ job: OfficeRenderClient.Job) -> some View {
        let (symbol, colour) = Self.look(job.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StudioTile(symbol: symbol, colour: colour).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.timeline).font(.system(size: 13)).lineLimit(1)
                    Text(verbatim: "\(job.project) · \(job.preset) · \(job.device)")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                if job.state == "rendering" {
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 13).monospacedDigit())
                    IconButton(symbol: "xmark", label: "Cancel the render") {
                        Task { await run { try await client.cancel(job) } }
                    }
                } else if let size = job.previewSize {
                    if let fraction = downloading[job.id] {
                        StudioProgress(share: fraction).frame(width: 70)
                    } else {
                        Button { fetch(job) } label: {
                            Label("Get preview · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))", systemImage: "arrow.down")
                        }
                        .buttonStyle(StudioFlatButtonStyle())
                        .help("Get the preview (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
                    }
                }
            }
            switch job.state {
            case "rendering":
                StudioProgress(share: job.progress)
                if let remaining = job.remaining, remaining > 0 {
                    Text("About \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                        .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                }
            case "done":
                Text(job.makingPreview ? String(localized: "Rendered · making the preview…")
                     : job.file.map { String(localized: "Rendered · \($0)") } ?? String(localized: "Rendered"))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.good).lineLimit(1).truncationMode(.middle)
            case "cancelled":
                Text(job.problem ?? String(localized: "Cancelled"))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
            default:
                Text(job.problem ?? String(localized: "Failed"))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .studioBox()
    }

    private static func look(_ state: String) -> (String, Color) {
        switch state {
        case "rendering": ("film", Design.Studio.text)
        case "done": ("checkmark", Design.Studio.good)
        case "cancelled": ("xmark", Design.Studio.textQuiet)
        default: ("exclamationmark.triangle", Design.Studio.bad)
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
    @Binding var side: OfficeRenderView.Side
    @State private var server = OfficeRenderServer.shared
    @AppStorage(OfficeRenderServer.enabledKey) private var enabled = false
    @AppStorage(OfficeRenderServer.folderKey) private var folder = ""
    @AppStorage("editAnywhereSharePane") private var section = Section.renders
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var confirmDisconnect = false
    @State private var inviting = false
    @State private var invitation: InvitationLink?
    @State private var inviteProblem: String?
    @State private var archive = OfficeArchive.shared
    @State private var proxies = OfficeProxies.shared
    @State private var proxyProblem: String?
    @State private var inbox = OfficeInbox.shared
    @State private var inboxProblem: String?

    enum Section: String { case renders, anywhere, footage, inbox, devices }

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            AnywhereSidebar(side: $side, footnote: "Only Macs you pair get in",
                            footnoteDetail: Text("Only Macs paired with a code or invitation from this Mac get in, and only from the local network or the private network; it never answers the open internet. Every message is encrypted and signed. Paired Macs can only list projects, timelines and presets, render into the render folder, cancel, fetch previews, search the footage folders, fetch proxies or copies of them, and send files into their own folder in the inbox.")) {
                shareBox
                if enabled {
                    let rendering = server.jobs.filter { $0.state == .rendering }.count
                    VStack(spacing: 2) {
                        NavRow(symbol: "film", title: "Renders", selected: section == .renders,
                               badge: rendering > 0 ? Text(verbatim: "\(rendering)") : nil) { section = .renders }
                        NavRow(symbol: "globe.europe.africa", title: "From anywhere", selected: section == .anywhere) { section = .anywhere }
                        NavRow(symbol: "sparkle.magnifyingglass", title: "Footage", selected: section == .footage) { section = .footage }
                        NavRow(symbol: "tray.and.arrow.down", title: "Files from paired Macs", selected: section == .inbox) { section = .inbox }
                        NavRow(symbol: "laptopcomputer.and.iphone", title: "Paired Macs", selected: section == .devices,
                               badge: server.devices.isEmpty ? nil : Text(verbatim: "\(server.devices.count)")) { section = .devices }
                    }
                }
            }
            if enabled {
                AnywherePane {
                    switch section {
                    case .renders: rendersCard
                    case .anywhere: anywhereCard
                    case .footage: archiveCard
                    case .inbox: inboxCard
                    case .devices: devicesCard
                    }
                }
            } else {
                AnywherePane(scrolls: false) {
                    Spacer(minLength: 0)
                    StudioTile(symbol: "desktopcomputer", colour: Design.Studio.textQuiet)
                    Text("Share this Mac").font(Design.Studio.sectionTitle)
                    Text("Paired Macs render and search footage on this Mac. Keep Pluck and DaVinci Resolve open.")
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
            }
        }
        .sheet(item: $invitation) { link in InvitationSheet(link: link.url) }
    }

    /// The switch that shares this Mac, at the top of the left panel.
    private var shareBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StudioTile(symbol: "desktopcomputer", colour: enabled ? Design.Studio.good : Design.Studio.textQuiet, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share this Mac").font(Design.Studio.body)
                    Text(enabled ? "On" : "Off").font(Design.Studio.hint)
                        .foregroundStyle(enabled ? Design.Studio.good : Design.Studio.textQuiet)
                }
                Spacer(minLength: 0)
                Toggle("Share this Mac", isOn: Binding(get: { enabled }, set: { server.setEnabled($0) }))
                    .toggleStyle(StudioSwitchStyle())
            }
            .help("Paired Macs render and search footage on this Mac. Keep Pluck and DaVinci Resolve open.")
            if let problem = server.problem {
                Text(problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .studioBox()
        .padding(.horizontal, 4)
    }

    // MARK: Renders

    @ViewBuilder
    private var rendersCard: some View {
        let rendering = server.jobs.filter { $0.state == .rendering }.count
        PaneHeader(title: Text("Renders"), subtitle: Text("Where renders for paired Macs go.")) {
            if rendering > 0 {
                StudioChip(text: Text("^[\(rendering) render](inflect: true) running"), symbol: "circle.dotted")
            }
        }
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(folder.isEmpty ? Design.Studio.warn : Design.Studio.textQuiet)
                .accessibilityHidden(true)
            Text(folder.isEmpty ? String(localized: "No render folder chosen yet") : folder)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(folder.isEmpty ? Design.Studio.textQuiet : Design.Studio.text)
                .help(folder)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") { chooseFolder() }
                .buttonStyle(StudioFlatButtonStyle())
        }
        .font(Design.Studio.body)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .studioBox()
        if server.jobs.contains(where: { $0.state != .rendering }) {
            HStack {
                Text("^[\(server.jobs.count) render](inflect: true) in the list").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                PinkLink(title: "Clear finished") { server.clearFinished() }
            }
        }
    }

    // MARK: From anywhere

    @ViewBuilder
    private var anywhereCard: some View {
        PaneHeader(title: Text("From anywhere"),
                   subtitle: Text("Other Macs connect from anywhere over a private network built into Pluck.")) {
            HStack(spacing: 6) {
                anywhereStatus
                if PrivateNetwork.helper != nil, server.network.hasJoined || PrivateNetwork.Account.token != nil || tokenSaved {
                    Menu {
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.Studio.textQuiet)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .plainMenu()
                    .help("Take this Mac off the private network")
                }
            }
        }
        .confirmationDialog("Disconnect this Mac from the private network?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                server.disconnectNetwork()
                tokenSaved = false
                inviteProblem = nil
            }
        } message: {
            Text("Macs on this network keep working. Macs elsewhere can’t reach this one until you connect again with a Tailscale access token and invite them again. You can remove its old entry in Tailscale’s admin page.")
        }
        if PrivateNetwork.helper == nil {
            Text("This build of Pluck doesn’t have the private network part.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        } else if !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).accessibilityHidden(true)
                    SecureField("Tailscale access token", text: $token, prompt: Text("Tailscale access token (tskey-api-…)"))
                        .textFieldStyle(.plain)
                        .font(Design.Studio.body)
                }
                .anywhereInput()
                Button("Connect") {
                    server.connectAccount(token: token)
                    token = ""
                    tokenSaved = true
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(!token.trimmingCharacters(in: .whitespaces).hasPrefix("tskey-api-"))
            }
            PinkLink(title: "Where do I get a token?") {
                NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/settings/keys")!)
            }
            .help("In your Tailscale account: Settings → Keys → Generate access token. Nobody else needs an account or the Tailscale app.")
        } else {
            switch server.network.state {
            case .running(let name, let address):
                HStack(spacing: 10) {
                    Text("Reachable as \(name.isEmpty ? address : name)")
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if inviting { PlumSpinner() }
                    Button {
                        makeInvitation()
                    } label: {
                        Label("Invite a Mac", systemImage: "envelope")
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(inviting)
                    .help("A one-time link for the Mac you want to connect, valid for a day")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 48)
                .studioBox()
            case .failed(let message):
                HStack {
                    ProblemLine(text: message, colour: Design.Studio.warn)
                    Spacer()
                    Button("Try again") { server.startNetwork() }.buttonStyle(StudioFlatButtonStyle())
                }
            case .off:
                HStack {
                    Spacer()
                    Button("Connect") { server.startNetwork() }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                }
            case .starting:
                EmptyView()
            }
            if let problem = server.networkProblem ?? inviteProblem {
                ProblemLine(text: problem, colour: Design.Studio.warn)
            }
        }
    }

    @ViewBuilder
    private var anywhereStatus: some View {
        if PrivateNetwork.helper != nil {
            if !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
                StudioChip(text: Text("Not set up"))
            } else {
                switch server.network.state {
                case .running: StudioChip(text: Text("Ready"), colour: Design.Studio.good, tinted: true)
                case .starting: StudioChip(text: Text("Connecting"), symbol: "circle.dotted")
                case .failed: StudioChip(text: Text("Problem"), colour: Design.Studio.warn, tinted: true)
                case .off: StudioChip(text: Text("Off"))
                }
            }
        }
    }

    // MARK: Inbox

    @ViewBuilder
    private var inboxCard: some View {
        PaneHeader(title: Text("Files from paired Macs"),
                   subtitle: Text("What they send arrives here, in a folder per Mac.")) {
            if let receiving = inbox.receiving {
                StudioChip(text: Text("Receiving \(receiving)"), symbol: "circle.dotted")
            }
        }
        StudioField(label: "Saved in") {
            Text(inbox.folder.lastPathComponent)
                .font(Design.Studio.body)
                .foregroundStyle(Design.Studio.textQuiet)
                .lineLimit(1)
                .help(inbox.folder.path)
            Menu {
                Button("Choose a Folder…", action: chooseInbox)
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([inbox.folder])
                }
            } label: {
                PlainMenuLabel(title: String(localized: "Change"))
            }
            .plainMenu()
        }
        if inbox.receiving != nil { StudioProgress(share: inbox.progress) }
        ForEach(Array(inbox.recent.prefix(3).enumerated()), id: \.offset) { _, file in
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle").foregroundStyle(Design.Studio.good)
                Text("\(file.name) from \(file.from), \(file.at.formatted(.relative(presentation: .named)))")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(Design.Studio.body)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .studioBox()
        }
        if let inboxProblem { ProblemLine(text: inboxProblem) }
    }

    private func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where files from paired Macs arrive. Each Mac gets a folder in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try inbox.choose(url)
            inboxProblem = nil
        } catch {
            inboxProblem = error.localizedDescription
        }
    }

    // MARK: Footage

    @ViewBuilder
    private var archiveCard: some View {
        PaneHeader(title: Text("Footage"),
                   subtitle: Text("Paired Macs search it by what’s in the picture, fetch the shots they need, or fetch proxies of whole folders.")) {
            if archive.working != nil {
                StudioChip(text: Text("Looking"), symbol: "circle.dotted")
            } else if !archive.folders.isEmpty {
                StudioChip(text: Text("\(archive.indexes.count) of \(archive.fileCount) searchable"), colour: Design.Studio.good, tinted: true)
            }
        }
        ForEach(archive.folders, id: \.self) { folder in
            HStack(spacing: 12) {
                StudioTile(symbol: "folder", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.lastPathComponent).font(Design.Studio.body).lineLimit(1)
                    Text(folder.deletingLastPathComponent().path).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                IconButton(symbol: "minus", label: "Stop searching this folder") { archive.remove(folder) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .studioBox()
        }
        if let working = archive.working {
            VStack(alignment: .leading, spacing: 6) {
                StudioProgress(share: archive.progress)
                Text("Looking at “\(working)” (\(archive.queued) more)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        if !archive.folders.isEmpty {
            StudioField(label: "Proxies in") {
                Text(proxies.chosenFolder?.lastPathComponent ?? String(localized: "Pluck’s own folder"))
                    .font(Design.Studio.body)
                    .foregroundStyle(Design.Studio.textQuiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(proxies.chosenFolder?.path ?? String(localized: "Kept in Pluck’s own folder and removed after three weeks without use"))
                Menu {
                    Button("Choose a Folder…", action: chooseProxyFolder)
                    if proxies.chosenFolder != nil {
                        Button("Use Pluck’s Own Folder") { try? proxies.choose(nil) }
                    }
                    if let folder = proxies.chosenFolder {
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                } label: {
                    PlainMenuLabel(title: String(localized: "Change"))
                }
                .plainMenu()
            }
            .help("Where proxies that paired Macs ask for are made on this Mac, for example next to the project on your storage")
            if let proxyProblem { ProblemLine(text: proxyProblem) }
        }
        if let making = proxies.working {
            VStack(alignment: .leading, spacing: 6) {
                StudioProgress(share: proxies.progress)
                Text("Making a proxy of “\(making)” (\(proxies.queued) more)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        StudioDashedButton(title: "Add a folder…") { addArchiveFolder() }
        if !archive.folders.isEmpty, archive.working == nil {
            PinkLink(title: "Look again") { archive.scan() }
                .help("Look for new footage now (it also happens by itself every few hours)")
        }
    }

    // MARK: Paired Macs

    @ViewBuilder
    private var devicesCard: some View {
        PaneHeader(title: Text("Paired Macs"))
        if server.devices.isEmpty {
            Text("None yet. Invite a Mac, or pair one on the same network with a code.")
                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        }
        ForEach(server.devices) { device in
            HStack(spacing: 12) {
                StudioTile(symbol: "laptopcomputer", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(Design.Studio.body)
                    Group {
                        if let seen = server.lastSeen[device.id] {
                            Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                        } else {
                            Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "Remove: it can’t connect any more until it’s paired again", tint: Design.Studio.bad) {
                    server.remove(device)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .studioBox()
        }
        if let pairing = server.pairing {
            codePanel(pairing)
        } else {
            HStack {
                if let name = server.justPaired {
                    Label("\(name) is paired.", systemImage: "checkmark.circle").foregroundStyle(Design.Studio.good).font(Design.Studio.body)
                }
                Spacer()
                Button("Pair a Mac on this network…") { server.startPairing() }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(!server.isRunning)
                    .help("For a Mac on the same network; Macs elsewhere get an invitation")
            }
        }
    }

    private func codePanel(_ pairing: (code: String, expires: Date)) -> some View {
        VStack(spacing: 8) {
            Text("On the other Mac, open Tools → Edit Anywhere and type:").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            Text(OfficeLink.formatted(pairing.code))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            if let address = OfficeRenderServer.addresses().first {
                Text("Address \(address)").font(Design.Studio.body.monospaced()).foregroundStyle(Design.Studio.textQuiet).textSelection(.enabled)
            }
            HStack {
                Text("Works once, until \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                PinkLink(title: "Cancel") { server.cancelPairing() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .studioBox(outline: Design.rgb(0x8E4C64))
    }

    // MARK: Actions

    private func chooseProxyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where proxies are made on this Mac. Pluck makes a folder per footage folder in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try proxies.choose(url)
            proxyProblem = nil
        } catch {
            proxyProblem = error.localizedDescription
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
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Invite a Mac"),
                       subtitle: Text("Send this link to the Mac you want to connect. When it’s clicked there, Pluck joins this Mac’s private network and pairs with it."))
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).accessibilityHidden(true)
                Text(link.absoluteString)
                    .font(Design.Studio.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .anywhereInput()
            Label("Works once, for 24 hours, for the first Mac that uses it. Send it only to people you trust.",
                  systemImage: "lock.shield")
                .font(Design.Studio.hint)
                .foregroundStyle(Design.Studio.textQuiet)
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                ShareLink(item: link, subject: Text("Edit Anywhere invitation"),
                          message: Text("Click this link on your Mac to connect Pluck to the host Mac:")) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(StudioFlatButtonStyle(height: 32))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(StudioFlatButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
    }
}

/// Searching the office footage from here: what's in the picture, the shot size, the camera
/// move; each shot can be fetched as a light copy with a second of handles.
private struct ArchiveSearchPane: View {
    let host: String
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Search \(host)’s footage").font(Design.Studio.sectionTitle)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.Studio.textQuiet)
                        .accessibilityHidden(true)
                    TextField("Search", text: $query, prompt: Text("Describe a shot: “crowd with confetti”, “drone over the stage”"))
                        .textFieldStyle(.plain)
                        .font(Design.Studio.body)
                        .onSubmit { search() }
                }
                .anywhereInput()
                filter(movement?.label ?? String(localized: "Any movement")) {
                    Button("Any Movement") { movement = nil }
                    Divider()
                    ForEach(VisualIndex.Movement.allCases, id: \.self) { m in Button(m.label) { movement = m } }
                }
                filter(framing?.label ?? String(localized: "Any framing")) {
                    Button("Any Framing") { framing = nil }
                    Divider()
                    ForEach(VisualIndex.Framing.allCases, id: \.self) { f in Button(f.label) { framing = f } }
                }
                Button("Search", action: search)
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(searching)
            }
            HStack(spacing: 8) {
                if searching {
                    PlumSpinner()
                    Text("Searching the footage…")
                } else if let problem {
                    ProblemLine(text: problem)
                } else if let status {
                    Text(status.folders == 0 ? String(localized: "The host Mac has no footage folders to search yet. Add them there, under Edit Anywhere.")
                         : status.working ? String(localized: "\(status.indexed) of \(status.files) files searchable; the host Mac is still looking at the rest.")
                         : String(localized: "\(status.indexed) files searchable."))
                }
            }
            .font(Design.Studio.hint)
            .foregroundStyle(Design.Studio.textQuiet)

            if searched && hits.isEmpty && !searching {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 22)).foregroundStyle(Design.Studio.textQuiet)
                    Text("Nothing found").font(Design.Studio.sectionTitle)
                    Text("Try other words.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(hits) { hit in card(hit) }
                }
            }
        }
        .task { status = try? await client.archiveStatus() }
    }

    /// A filter menu: the choice and a chevron on raised grey.
    private func filter<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            StudioMenuLabel(title: title)
        }
        .plainMenu()
        .help(title)
    }

    private func card(_ hit: OfficeRenderClient.ArchiveHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = hit.thumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Rectangle().fill(Design.Studio.raised)
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                Text(Duration.seconds(hit.end - hit.start).formatted(.time(pattern: .minuteSecond)))
                    .font(Design.Studio.hint.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                    .padding(6)
            }
            Text(hit.description).font(Design.Studio.body).lineLimit(2).help(hit.description)
            HStack(spacing: 6) {
                Text(hit.place).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle).help(hit.place)
                Spacer(minLength: 4)
                if let url = fetched[hit.id] {
                    IconButton(symbol: "magnifyingglass", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else if let progress = fetching[hit.id] {
                    StudioProgress(share: progress).frame(width: 50)
                } else {
                    IconButton(symbol: "arrow.down", label: "Get a light 1080p copy of this shot, with a second either side") { fetch(hit) }
                }
            }
        }
        .padding(10)
        .studioBox()
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

// MARK: - Proxies

/// Proxies of the host Mac's footage folders, made there and fetched here in the background, to
/// edit with here and relink to the originals on the host Mac.
private struct ProxiesPane: View {
    @State private var sync = ProxySync.shared
    @AppStorage("editAnywhereProxyFormat") private var format = OfficeProxies.Format.light
    @AppStorage("editAnywhereProxyFolder") private var parent = ProxySync.defaultDestination.path
    @State private var loading = false
    @State private var starting: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(title: Text("From the host Mac"),
                       subtitle: Text("Proxies of a footage folder to edit with, or the originals. Each file comes as soon as it’s ready.")) {
                if loading { PlumSpinner() }
            }
            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    Text("Format").foregroundStyle(Design.Studio.textQuiet)
                    Menu {
                        Picker("Format", selection: $format) {
                            ForEach(OfficeProxies.Format.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        PlainMenuLabel(title: format.label)
                    }
                    .plainMenu()
                    .help(format.detail)
                }
                HStack(spacing: 8) {
                    Text("Save in").foregroundStyle(Design.Studio.textQuiet)
                    Button(action: choose) {
                        PlainMenuLabel(title: URL(fileURLWithPath: parent).lastPathComponent)
                    }
                    .buttonStyle(.plain)
                    .help(parent)
                }
                Spacer(minLength: 0)
            }
            .font(Design.Studio.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .studioBox()
            if let problem { ProblemLine(text: problem) }

            if sync.folders.isEmpty, !loading {
                HStack(spacing: 12) {
                    StudioTile(symbol: "folder", colour: Design.Studio.textQuiet)
                    PaneHeader(title: Text("No footage shared yet"),
                               subtitle: Text("On the host Mac, add a folder under Footage in Edit Anywhere → Share this Mac."))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .studioBox()
            }
            ForEach(sync.folders) { folder in
                folderRow(folder)
            }
            Text("In DaVinci Resolve, select the clips in the media pool, choose Link Proxy Media and pick the folder here: Resolve matches the proxies by name. Back on the host Mac, the project uses the originals.")
                .font(Design.Studio.hint)
                .foregroundStyle(Design.Studio.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await load() }
    }

    private func folderRow(_ folder: ProxySync.Folder) -> some View {
        let job = sync.jobs.first { $0.folder == folder.id && $0.format == format }
        let state = job.flatMap { sync.progress[$0.id] }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StudioTile(symbol: "folder", colour: Design.Studio.textQuiet).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name).font(.system(size: 13)).lineLimit(1)
                    Text(subtitle(folder, job: job, state: state)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let job {
                    IconButton(symbol: "folder", label: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.destination)])
                    }
                    IconButton(symbol: "xmark", label: "Stop Fetching") { sync.remove(job) }
                } else if starting == folder.id {
                    PlumSpinner()
                } else {
                    Button(format == .original ? "Fetch" : "Make proxies") { start(folder) }
                        .buttonStyle(StudioFlatButtonStyle())
                        .disabled(folder.files == 0)
                }
            }
            if let state, state.total > 0, state.here < state.total {
                StudioProgress(share: (Double(state.here) + (state.fetching != nil ? state.fraction : 0)) / Double(state.total))
            }
            if let problem = state?.problem {
                Text(problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .studioBox()
    }

    private func subtitle(_ folder: ProxySync.Folder, job: ProxySync.Job?, state: ProxySync.Progress?) -> String {
        guard job != nil, let state, state.total > 0 else {
            return String(AttributedString(localized: "^[\(folder.files) video](inflect: true)").characters)
        }
        if state.here >= state.total { return String(localized: "All \(state.total) here") }
        var parts = [String(localized: "\(state.here) of \(state.total) here")]
        if state.madeOnHost < state.total { parts.append(String(localized: "\(state.madeOnHost) made on the host Mac")) }
        if let fetching = state.fetching { parts.append(String(localized: "fetching \(fetching)")) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await sync.loadFolders()
            problem = nil
            sync.resume()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func start(_ folder: ProxySync.Folder) {
        starting = folder.id
        Task {
            do {
                try await sync.start(folder, format: format, parent: URL(fileURLWithPath: parent))
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            starting = nil
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
}

/// Folders and files sent to the host Mac: into this Mac's folder in its inbox.
private struct SendPane: View {
    @State private var sync = SendSync.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(title: Text("To the host Mac"),
                       subtitle: Text("Folders here stay in step: new and changed files go up by themselves, into this Mac’s folder in the host’s inbox.")) {
                if let sending = sync.sending {
                    StudioChip(text: Text("Sending \(sending)"), symbol: "circle.dotted")
                } else if let lastSent = sync.lastSent {
                    StudioChip(text: Text("Sent \(lastSent.formatted(.relative(presentation: .named)))"))
                }
            }
            if sync.sending != nil {
                StudioProgress(share: sync.fraction)
                if sync.waiting > 0 {
                    Text("^[\(sync.waiting) more file](inflect: true) to send").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            ForEach(sync.folders) { folder in
                HStack(spacing: 12) {
                    StudioTile(symbol: "folder", colour: Design.Studio.textQuiet).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.url.lastPathComponent).font(.system(size: 13)).lineLimit(1)
                        Text("^[\(folder.sent.count) file](inflect: true) on the host Mac").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    Spacer(minLength: 8)
                    IconButton(symbol: "folder", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                    IconButton(symbol: "minus", label: "Stop Sending This Folder") { sync.remove(folder) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .studioBox()
            }
            if !sync.files.isEmpty {
                Text("^[\(sync.files.count) file](inflect: true) waiting to be sent").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            if let problem = sync.problem { ProblemLine(text: problem) }
            HStack(spacing: 8) {
                Button("Add folder…", systemImage: "plus") { choose(folders: true) }
                    .buttonStyle(StudioFlatButtonStyle())
                Button("Send files…", systemImage: "paperplane") { choose(folders: false) }
                    .buttonStyle(StudioFlatButtonStyle())
                Spacer()
            }
        }
        .padding(8)
        .overlay {
            RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
                .strokeBorder(Design.Brand.gradient, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .opacity(targeted ? 1 : 0)
        }
        .padding(-8)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers { if let url = await provider.load(URL.self), url.isFileURL { urls.append(url) } }
                sync.send(urls)
            }
            return true
        }
        .task { sync.resume() }
    }

    private func choose(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        panel.prompt = folders ? String(localized: "Keep in Step") : String(localized: "Send")
        guard panel.runModal() == .OK else { return }
        if folders {
            for url in panel.urls { sync.add(folder: url) }
        } else {
            sync.send(panel.urls)
        }
    }
}
