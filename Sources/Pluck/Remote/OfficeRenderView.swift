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
struct PaneHeader<Trailing: View>: View {
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
struct PinkLink: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).font(Design.Studio.hint).foregroundStyle(Design.Brand.pink) }
            .buttonStyle(.plain)
    }
}

/// What went wrong, in the bad colour.
/// How an iroh link goes: "Direct · 12 ms", or slow through a relay, with how to make it faster.
private struct LinkLine: View {
    let link: Tunnel.Link
    let hint: Text

    var body: some View {
        Group {
            if link.direct {
                if let rtt = link.rtt { Text("Direct · \(Int(rtt.rounded())) ms") } else { Text("Direct") }
            } else {
                Label("Slow: no direct connection", systemImage: "tortoise")
                    .help(hint)
            }
        }
        .font(Design.Studio.hint)
        .foregroundStyle(link.direct ? Design.Studio.good : Design.Studio.warn)
        .lineLimit(1)
    }
}

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
    func anywhereInput(inBox: Bool = false, height: CGFloat = 32) -> some View {
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
    @State private var joining = false
    @State private var pairingWithCode = false
    /// The invitation the alert shows, taken from the client so a newer link can't swap in under the click.
    @State private var shownInvitation: PrivateNetwork.Invitation?
    @AppStorage("editAnywherePane") private var pane = Pane.proxies

    /// (`proxies` is Browse; the raw values are what's stored.)
    enum Pane: String { case render, proxies, resolve, review }

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            AnywhereSidebar(side: $side, footnote: client.office != nil ? "Private and encrypted" : nil,
                            footnoteDetail: Text("Everything between the two Macs is encrypted and signed, and the host Mac is never open to the internet.")) {
                if let office = client.office {
                    if client.members.count > 1 { groupBox } else { hostBox(office) }
                    VStack(spacing: 2) {
                        NavRow(symbol: "folder", title: "Browse", selected: pane == .proxies) { pane = .proxies }
                        NavRow(symbol: "play.rectangle", title: "Render", selected: pane == .render) { pane = .render }
                        NavRow(symbol: "film.stack", title: "DaVinci Resolve", selected: pane == .resolve) { pane = .resolve }
                        NavRow(symbol: "text.bubble", title: "Review", selected: pane == .review) { pane = .review }
                    }
                }
            }
            if let office = client.office {
                AnywherePane {
                    switch pane {
                    case .proxies:
                        // (Made again for another host: its favourites are that host's.)
                        RemoteFilesPane { ProxiesPane() }.id(office.device)
                        SendPane().padding(.top, 24)
                    case .render: renderPane(office)
                    case .resolve: RemoteResolvePane(host: office.name)
                    case .review: RemoteReviewPane()
                    }
                    activity
                }
            } else {
                AnywherePane(scrolls: false) { welcome }
            }
        }
        .onAppear { client.load() }
        .alert(Text("Join “\(shownInvitation?.name ?? "")”?"),
               isPresented: Binding(get: { shownInvitation != nil }, set: { if !$0 { shownInvitation = nil } }), presenting: shownInvitation) { invitation in
            Button("Join") { join(invitation) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if let current = client.office {
                Text("This Mac joins that Mac’s private network and pairs with it, so you can render there from anywhere. Only accept invitations from people you trust.")
                    + Text(verbatim: "\n\n") + Text("This replaces “\(current.name)”, the host you’re paired with now.")
            } else {
                Text("This Mac joins that Mac’s private network and pairs with it, so you can render there from anywhere. Only accept invitations from people you trust.")
            }
        }
        .onChange(of: client.pendingInvitation?.link, initial: true) { takeInvitation() }
        .onChange(of: shownInvitation == nil) { takeInvitation() }
        .task(id: client.office?.device) {
            // Several office Macs: learnt from the paired one, then each looked at again now and then.
            while client.office != nil, !Task.isCancelled {
                await client.refreshGroup()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: client.office?.device) {
            guard client.office != nil else { return }
            await run { try await client.refresh() }
            if client.jobs.contains(where: { $0.state == "rendering" || $0.makingPreview }) { client.follow() }
        }
    }

    /// An invitation link on the clipboard goes the usual way (the alert asks before joining).
    private func pasteInvitation() {
        guard let text = NSPasteboard.general.string(forType: .string), let invitation = PrivateNetwork.Invitation(link: text) else {
            problem = String(localized: "There’s no invitation link on the clipboard. Copy the whole link, then try again.")
            return
        }
        problem = nil
        client.pendingInvitation = invitation
    }

    // MARK: Not connected yet

    /// One empty state: how to get an invitation, and Paste. (Pairing with a code stays as a quiet link.)
    private var welcome: some View {
        VStack(spacing: 14) {
            StudioEmptyState(symbol: "link", title: "Connect to your office Mac",
                             line: "On the office Mac: Edit Anywhere › Macs › Invite a Mac. Open the link here, or paste it.",
                             prominent: true, button: "Paste invitation") { pasteInvitation() }
                .frame(maxHeight: pairingWithCode ? 260 : .infinity)
            activity
            PinkLink(title: pairingWithCode ? "Hide pairing with a code" : "On the same network? Pair with a code instead") {
                withAnimation(.snappy(duration: 0.25)) { pairingWithCode.toggle() }
            }
            if pairingWithCode {
                codePairing
                    .frame(maxWidth: 560)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Spacer(minLength: 0)
            }
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

    /// An office of several Macs: "Office · 3 Macs", then each with how it's doing (the one in use marked).
    private var groupBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StudioTile(symbol: "building.2", colour: Design.Studio.good, size: 32)
                Text("Office · \(client.members.count) Macs").font(Design.Studio.body).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Forget the Office", role: .destructive) { client.forget(); projects = []; project = nil }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.Studio.textQuiet)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .plainMenu()
                .help("Forget the office on this Mac. Remove this Mac on an office Mac too.")
            }
            ForEach(client.members) { member in
                let state = client.memberStates[member.id]
                HStack(spacing: 6) {
                    Circle().fill(state?.online == false ? Design.Studio.textQuiet : state?.busy == true ? Design.Studio.warn : Design.Studio.good)
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(member.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Group {
                        if state?.online == false { Text("Offline") } else if state?.busy == true { Text("Rendering") }
                        else if (client.active ?? client.primary) == member.id { Text("In use") } else { Text("Online") }
                    }
                    .foregroundStyle(Design.Studio.textQuiet)
                }
                .font(Design.Studio.hint)
            }
        }
        .padding(12)
        .studioBox()
        .padding(.horizontal, 4)
    }

    /// The host Mac: a tile in the good colour, its name, how it's connected, and ⋯ with Unpair.
    private func hostBox(_ office: OfficeRenderClient.Office) -> some View {
        HStack(spacing: 10) {
            StudioTile(symbol: "desktopcomputer", colour: Design.Studio.good, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(office.name).font(Design.Studio.body).lineLimit(1)
                if let link = office.iroh.flatMap({ client.irohTunnel.links[$0] }) {
                    Text(link.direct ? "● Online · direct connection" : "● Online · relay")
                        .font(Design.Studio.hint)
                        .foregroundStyle(link.direct ? Design.Studio.good : Design.Studio.warn)
                        .lineLimit(1)
                        .help(link.direct ? Text(link.rtt.map { "\(Int($0.rounded())) ms" } ?? "") : Text("Ask the host Mac to use its own relay to make it faster."))
                } else {
                    Group {
                        if office.fromAnywhere {
                            Text("● Online · from anywhere")
                        } else {
                            Text("● Online · local network").help(Text(verbatim: office.address))
                        }
                    }
                    .font(Design.Studio.hint)
                    .foregroundStyle(Design.Studio.good)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Forget This Mac", role: .destructive) { client.forget(); projects = []; project = nil }
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

    /// Shows the next invitation that arrived, once the one on screen is answered.
    private func takeInvitation() {
        guard shownInvitation == nil, let next = client.pendingInvitation else { return }
        shownInvitation = next
        client.pendingInvitation = nil
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
            await run { try await client.join(invitation) }
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
    @State private var archive = OfficeArchive.shared
    @State private var proxyJobs = RemoteProxyJobs.shared
    @AppStorage(OfficeRenderServer.enabledKey) private var enabled = false
    @AppStorage("editAnywhereSharePane") private var section = Section.macs

    enum Section: String { case macs, folders, proxies, renders }

    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            AnywhereSidebar(side: $side, footnote: "Only Macs you pair get in",
                            footnoteDetail: Text("Only Macs paired with a code or invitation from this Mac get in, and only from the local network or the private network; it never answers the open internet. Every message is encrypted and signed. Paired Macs can only browse the shared folders, fetch proxies or copies of them, list projects, timelines and presets, render into the render folder, cancel, fetch previews, and send files into their own folder in the inbox.")) {
                shareBox
                if enabled {
                    let rendering = server.jobs.filter { $0.state == .rendering }.count
                    let making = proxyJobs.requests.filter { $0.state == .making || $0.state == .queued }.count
                    VStack(spacing: 2) {
                        NavRow(symbol: "laptopcomputer", title: "Macs", selected: section == .macs,
                               badge: server.pairedMacs.isEmpty ? nil : Text(verbatim: "\(server.pairedMacs.count)")) { section = .macs }
                        NavRow(symbol: "folder", title: "Folders", selected: section == .folders,
                               badge: archive.folders.isEmpty ? nil : Text(verbatim: "\(archive.folders.count)")) { section = .folders }
                        NavRow(symbol: "photo.on.rectangle", title: "Proxies", selected: section == .proxies,
                               badge: making > 0 ? Text(verbatim: "\(making)") : nil) { section = .proxies }
                        NavRow(symbol: "film", title: "Renders", selected: section == .renders,
                               badge: rendering > 0 ? Text(verbatim: "\(rendering)") : nil) { section = .renders }
                    }
                }
            }
            if enabled {
                AnywherePane {
                    switch section {
                    case .macs: HostMacsPane()
                    case .folders: HostFoldersPane()
                    case .proxies: HostProxiesPane()
                    case .renders: HostRendersPane()
                    }
                }
            } else {
                AnywherePane(scrolls: false) {
                    Spacer(minLength: 0)
                    StudioTile(symbol: "desktopcomputer", colour: Design.Studio.textQuiet)
                    Text("Share this Mac").font(Design.Studio.sectionTitle)
                    Text("Paired Macs edit with this Mac’s footage and render on it. Keep Pluck and DaVinci Resolve open.")
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
            }
        }
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
            .help("Paired Macs edit with this Mac’s footage and render on it. Keep Pluck and DaVinci Resolve open.")
            if let problem = server.problem {
                Text(problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .studioBox()
        .padding(.horizontal, 4)
    }
}

/// A quiet line under a list ("Connection: …  Change…"), with a hairline above the first one.
private struct FootLine<Trailing: View>: View {
    let text: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            text.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A pink "Change…" that opens a menu.
private struct PinkMenu<Items: View>: View {
    var title: LocalizedStringKey = "Change…"
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: { Text(title).font(Design.Studio.hint).foregroundStyle(Design.Brand.pink) }
            .plainMenu()
    }
}

/// A small grey heading over a group of rows ("Making now · 3 left").
private struct GroupTitle: View {
    let text: Text

    var body: some View {
        text.font(Design.Studio.hint.weight(.medium)).foregroundStyle(Design.Studio.textQuiet).padding(.top, 4)
    }
}

// MARK: Macs

private struct HostMacsPane: View {
    @State private var server = OfficeRenderServer.shared
    @AppStorage(PrivateNetwork.transportKey) private var transport = PrivateNetwork.transport.rawValue
    @State private var inviting = false
    @State private var invitation: InvitationLink?
    @State private var inviteProblem: String?
    @State private var connection = false
    @State private var group = OfficeGroup.shared
    @State private var joiningGroup = false

    private var iroh: Bool { transport == PrivateNetwork.Transport.iroh.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Macs"), subtitle: Text("Macs you invite can edit here from anywhere.")) {
                HStack(spacing: 8) {
                    if inviting { PlumSpinner() }
                    Button(action: makeInvitation) { Label("Invite a Mac", systemImage: "envelope") }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                        .disabled(inviting)
                        .help(iroh ? String(localized: "A one-time link for the Mac you want to connect, valid for 15 minutes")
                                   : String(localized: "A one-time link for the Mac you want to connect, valid for an hour"))
                }
            }
            if let inviteProblem {
                HStack {
                    ProblemLine(text: inviteProblem, colour: Design.Studio.warn)
                    Spacer()
                    Button("Try again", action: makeInvitation).buttonStyle(StudioFlatButtonStyle()).disabled(inviting)
                }
            }
            if server.pairedMacs.isEmpty {
                Text("No Macs yet. Invite one.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            ForEach(server.pairedMacs) { device in row(device) }
            if let pairing = server.pairing {
                codePanel(pairing)
            } else {
                HStack {
                    PinkLink(title: "Pair a Mac on this network with a code") { server.startPairing() }
                        .disabled(!server.isRunning)
                        .help("For a Mac on the same network; Macs elsewhere get an invitation")
                    Spacer()
                    if let name = server.justPaired {
                        Label("\(name) is paired.", systemImage: "checkmark.circle").foregroundStyle(Design.Studio.good).font(Design.Studio.hint)
                    }
                }
            }
            officeMacs
            Divider().overlay(Design.Studio.line)
            FootLine(text: Text("Connection: \(iroh ? String(localized: "Pluck (no account)") : "Tailscale")")) {
                PinkLink(title: "Change…") { connection = true }
            }
        }
        .sheet(item: $invitation) { link in InvitationSheet(link: link.url) }
        .sheet(isPresented: $joiningGroup) { JoinOfficeSheet() }
        .sheet(isPresented: $connection) { ConnectionSheet() }
    }

    /// The office Macs that share and serve Edit Anywhere together (OfficeGroup), and how to add one.
    @ViewBuilder
    private var officeMacs: some View {
        Divider().overlay(Design.Studio.line)
        GroupTitle(text: group.isGrouped ? Text("Office Macs · \(group.members.count)") : Text("Office Macs"))
        if group.isGrouped {
            ForEach(group.members) { member in memberRow(member) }
        } else {
            Text("Another Mac at the office can share and serve Edit Anywhere with this one.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
        HStack(spacing: 16) {
            PinkLink(title: "Add another office Mac") { server.startPairing() }
                .disabled(!server.isRunning)
                .help("Shows a code to type on the other office Mac")
            PinkLink(title: "Join another office Mac") { joiningGroup = true }
                .disabled(!server.isRunning)
                .help("Type the code another office Mac shows")
        }
    }

    private func memberRow(_ member: OfficeGroup.Member) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "desktopcomputer", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name).font(Design.Studio.body)
                Group {
                    if member.id == group.me {
                        Text("This Mac")
                    } else if let seen = group.seen[member.id], Date.now.timeIntervalSince(seen) < 90 {
                        Text("● Online")
                    } else if let seen = group.seen[member.id] {
                        Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Not reached yet")
                    }
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer()
            Menu {
                if member.id == group.me {
                    Button("Leave the Group", role: .destructive) { Task { await group.leave() } }
                } else {
                    Button("Remove", role: .destructive) { Task { await group.remove(member) } }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 28, height: 28).contentShape(.rect)
            }
            .plainMenu()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }

    private func row(_ device: OfficeRenderServer.Device) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "laptopcomputer", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(Design.Studio.body)
                status(device).font(Design.Studio.hint).lineLimit(1)
            }
            Spacer()
            RemoteRightsMenu(device: device)
            Menu {
                Button("Remove", role: .destructive) { server.remove(device) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 28, height: 28).contentShape(.rect)
            }
            .plainMenu()
            .accessibilityLabel("More")
            .help("Remove: it can’t connect any more until it’s paired again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }

    /// "● Online · direct connection", "● Online · relay", or when it was last here.
    @ViewBuilder
    private func status(_ device: OfficeRenderServer.Device) -> some View {
        let link = device.iroh.flatMap { server.network.links[$0] } ?? server.sampleLinks[device.id]
        let seen = server.lastSeen[device.id]
        if link != nil || seen.map({ Date.now.timeIntervalSince($0) < 120 }) == true {
            HStack(spacing: 5) {
                Circle().fill(Design.Studio.good).frame(width: 6, height: 6).accessibilityHidden(true)
                if let link {
                    Text(link.direct ? "Online · direct connection" : "Online · relay")
                        .help(link.direct ? Text(verbatim: "") : Text("Set up your own relay under Connection to make it faster."))
                } else {
                    Text("Online")
                }
            }
            .foregroundStyle(Design.Studio.textQuiet)
        } else if let seen {
            Text("Last seen \(seen.formatted(.relative(presentation: .named)))").foregroundStyle(Design.Studio.textQuiet)
        } else {
            Text("Paired \(device.added.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(Design.Studio.textQuiet)
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

    /// Starts the private network first when it isn't running, then makes the invitation.
    private func makeInvitation() {
        inviting = true
        inviteProblem = nil
        Task {
            defer { inviting = false }
            do {
                if !isRunning {
                    if !iroh, !server.network.hasJoined, PrivateNetwork.Account.token == nil {
                        connection = true
                        throw OfficeLink.Failure.office(String(localized: "Add a Tailscale access token under Connection first."))
                    }
                    if case .starting = server.network.state {} else { server.startNetwork() }
                    for _ in 0..<300 where !isRunning {
                        if case .failed(let message) = server.network.state { throw OfficeLink.Failure.office(message) }
                        if let problem = server.networkProblem { throw OfficeLink.Failure.office(problem) }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard isRunning else { throw OfficeLink.Failure.office(String(localized: "The private network didn’t start. Try again.")) }
                }
                invitation = InvitationLink(url: try await server.invite())
            } catch {
                inviteProblem = error.localizedDescription
            }
        }
    }

    private var isRunning: Bool {
        if case .running = server.network.state { true } else { false }
    }
}

/// Joins another office Mac's group: it's found on this network (or typed), with the code it shows.
private struct JoinOfficeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var finder = OfficeFinder()
    @State private var picked: OfficeFinder.Found?
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: Text("Join another office Mac"),
                       subtitle: Text("On that Mac: Edit Anywhere › Macs › Add another office Mac. Both then serve paired Macs."))
            if !finder.found.isEmpty {
                StudioField(label: "Office Mac") {
                    Menu {
                        Picker("Office Mac", selection: $picked) {
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
                TextField("Office Mac address", text: $address, prompt: Text("Its address on the local network, e.g. 10.0.0.13"))
                    .textFieldStyle(.plain).font(Design.Studio.body).anywhereInput(inBox: true)
            }
            TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX"))
                .textFieldStyle(.plain).font(Design.Studio.body.monospaced()).anywhereInput(inBox: true)
            if let problem { ProblemLine(text: problem) }
            HStack {
                if working { PlumSpinner() }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle(height: 32))
                Button("Join") { join() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled((picked == nil && address.trimmingCharacters(in: .whitespaces).isEmpty) || OfficeLink.normalised(code) == nil || working)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.found) { _, found in
            if picked == nil, address.isEmpty, let first = found.first { picked = first }
        }
    }

    private func join() {
        working = true
        problem = nil
        let target: OfficeRenderClient.Target = picked.map { .found($0.endpoint) } ?? .address(address)
        Task {
            defer { working = false }
            do {
                try await OfficeGroup.shared.join(target, code: code)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// How Macs elsewhere reach this one: the built-in way (iroh, an own relay optional) or Tailscale.
/// Switching asks first: Macs invited the other way need a new invitation.
private struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = OfficeRenderServer.shared
    @AppStorage(PrivateNetwork.transportKey) private var transport = PrivateNetwork.transport.rawValue
    @AppStorage(PrivateNetwork.relayKey) private var storedRelay = ""
    @State private var relayText = UserDefaults.standard.string(forKey: PrivateNetwork.relayKey) ?? ""
    @State private var ownRelayOn = !(UserDefaults.standard.string(forKey: PrivateNetwork.relayKey) ?? "").isEmpty
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var confirmDisconnect = false
    @State private var switching: PrivateNetwork.Transport?
    @State private var relaySetup = false

    private var iroh: Bool { transport == PrivateNetwork.Transport.iroh.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Connection"),
                       subtitle: Text("Other Macs connect from anywhere over a private network built into Pluck.")) {
                HStack(spacing: 6) {
                    status
                    if !iroh, PrivateNetwork.helper != nil, server.network.hasJoined || PrivateNetwork.Account.token != nil || tokenSaved {
                        Menu {
                            Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                                .frame(width: 28, height: 28).contentShape(.rect)
                        }
                        .plainMenu()
                        .help("Take this Mac off the private network")
                    }
                }
            }
            StudioField(label: "Connect with") {
                Menu {
                    Picker("Connect with", selection: Binding(get: { transport }, set: ask)) {
                        Text("Pluck (no account)").tag(PrivateNetwork.Transport.iroh.rawValue)
                        Text(verbatim: "Tailscale").tag(PrivateNetwork.Transport.tailscale.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    PlainMenuLabel(title: iroh ? String(localized: "Pluck (no account)") : "Tailscale")
                }
                .plainMenu()
            }
            if iroh { irohSetup } else { tailscaleSetup }
            RemoteNetworkHostView()
            HStack {
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
        .confirmationDialog("Disconnect this Mac from the private network?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                server.disconnectNetwork()
                tokenSaved = false
            }
        } message: {
            Text("Macs on this network keep working. Macs elsewhere can’t reach this one until you connect again with a Tailscale access token and invite them again. You can remove its old entry in Tailscale’s admin page.")
        }
        .alert(switching == .tailscale ? Text("Switch to Tailscale?") : Text("Switch to Pluck?"),
               isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("Cancel", role: .cancel) { switching = nil }
            Button("Switch") {
                if let switching { use(switching) }
                switching = nil
            }
        } message: {
            let count = reachedFromAnywhere
            if count == 1 {
                Text("Your paired Mac needs a new invitation afterwards. Macs on this network keep working.")
            } else {
                Text("Your \(count) paired Macs need a new invitation afterwards. Macs on this network keep working.")
            }
        }
    }

    /// The paired Macs that came in the current way from anywhere (they lose the way in after a switch).
    private var reachedFromAnywhere: Int {
        server.pairedMacs.filter { iroh ? $0.iroh != nil : $0.tailnet != nil }.count
    }

    private func ask(_ raw: String) {
        guard raw != transport, let way = PrivateNetwork.Transport(rawValue: raw) else { return }
        if reachedFromAnywhere > 0 { switching = way } else { use(way) }
    }

    private func use(_ way: PrivateNetwork.Transport) {
        server.setTransport(way)
        transport = way.rawValue
    }

    @ViewBuilder
    private var status: some View {
        if PrivateNetwork.helper(server.network.transport) != nil {
            if !iroh && !server.network.hasJoined && PrivateNetwork.Account.token == nil && !tokenSaved {
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

    /// The network's state in words, and what to do about it.
    @ViewBuilder
    private var networkState: some View {
        switch server.network.state {
        case .running(let name, let address):
            Label(iroh ? String(localized: "Ready, no account needed") : String(localized: "Reachable as \(name.isEmpty ? address : name)"),
                  systemImage: "checkmark.circle")
                .font(Design.Studio.body).foregroundStyle(Design.Studio.good)
        case .failed(let message):
            HStack {
                ProblemLine(text: message, colour: Design.Studio.warn)
                Spacer()
                Button("Try again") { server.startNetwork() }.buttonStyle(StudioFlatButtonStyle())
            }
        case .off:
            HStack {
                Text("Not connected").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                Button("Connect") { server.startNetwork() }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            }
        case .starting:
            HStack(spacing: 8) {
                PlumSpinner()
                Text("Connecting…").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        if let problem = server.networkProblem ?? server.network.warning {
            ProblemLine(text: problem, colour: Design.Studio.warn)
        }
    }

    @ViewBuilder
    private var irohSetup: some View {
        if PrivateNetwork.helper(.iroh) == nil {
            Text("This build of Pluck doesn’t have the private network part.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        } else {
            networkState
            StudioSwitchRow(title: "Use my own relay", isOn: Binding(get: { ownRelayOn }, set: { on in
                ownRelayOn = on
                if !on, !storedRelay.isEmpty { storedRelay = ""; relayText = ""; server.restartNetwork() }
            }))
            .help("Without a direct connection, everything goes through a relay. iroh’s free public relays are slow; your own is faster.")
            if ownRelayOn {
                HStack(spacing: 10) {
                    TextField("Relay address", text: $relayText, prompt: Text(verbatim: "https://relay.example.com"))
                        .textFieldStyle(.plain)
                        .font(Design.Studio.body)
                        .onSubmit(saveRelay)
                        .anywhereInput()
                    Button("Use", action: saveRelay)
                        .buttonStyle(StudioFlatButtonStyle(height: 32))
                        .disabled(PrivateNetwork.relayAddress(relayText) == nil || relayText == storedRelay)
                }
                PinkLink(title: "Set up a relay on a TrueNAS or Proxmox server…") { relaySetup = true }
                    .sheet(isPresented: $relaySetup) {
                        RelaySetupSheet { address in relayText = address; saveRelay() }
                    }
            }
        }
    }

    private func saveRelay() {
        guard let address = PrivateNetwork.relayAddress(relayText), address != storedRelay else { return }
        storedRelay = address
        server.restartNetwork()
    }

    /// The tailnet access rules invited Macs need (they join tagged and reach only this Mac's port).
    private var tailscaleRules: some View {
        PinkLink(title: "Copy Tailscale access rules") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(PrivateNetwork.Account.aclSnippet, forType: .string)
        }
        .help("Paste into Access controls in your Tailscale admin page, before you invite anyone. Invited Macs then reach only this Mac’s Edit Anywhere port. If a rule still lets \"*\" reach \"*:*\", change its src to autogroup:member.")
    }

    @ViewBuilder
    private var tailscaleSetup: some View {
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
            tailscaleRules
        } else {
            networkState
            tailscaleRules
        }
    }
}

// MARK: Folders

private struct HostFoldersPane: View {
    @State private var archive = OfficeArchive.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Folders"), subtitle: Text("Paired Macs see only these folders.")) {
                Button(action: add) { Label("Add a folder", systemImage: "plus") }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            }
            if let problem { ProblemLine(text: problem) }
            if archive.folders.isEmpty {
                Text("No folders yet. Add one.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            RemoteSharesList()
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Folders paired Macs can browse. Nothing in them is changed.")
        guard panel.runModal() == .OK else { return }
        problem = panel.urls.map({ archive.add($0) }).contains(false)
            ? String(localized: "A folder that holds the inbox can’t be shared. Choose one apart from it.") : nil
    }
}

// MARK: Proxies

private struct HostProxiesPane: View {
    @State private var proxies = OfficeProxies.shared
    @State private var jobs = RemoteProxyJobs.shared
    @State private var shares = RemoteShares.shared
    @State private var archive = OfficeArchive.shared
    @State private var server = OfficeRenderServer.shared
    @AppStorage(OfficeProxies.keepDaysKey) private var keepDays = 21
    @State private var made: [OfficeProxies.Made] = []
    @State private var deleting: OfficeProxies.Made?
    @State private var problem: String?
    @State private var group = OfficeGroup.shared
    /// Whether the proxy folder is on a NAS (all the office Macs of a group can reach it); nil until looked.
    @State private var onNAS: Bool?

    private static let keepChoices: [(Int, LocalizedStringKey)] = [(7, "1 week"), (21, "3 weeks"), (90, "3 months"), (0, "Never")]

    var body: some View {
        let total = made.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Proxies"),
                       subtitle: total == 0 ? Text("Light copies paired Macs edit with.")
                                            : Text("Light copies paired Macs edit with. \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) in total.")) {
                Menu {
                    Section("Make Proxies") {
                        ForEach(OfficeProxies.Format.made) { format in Button(format.label + "…") { pick(format, keep: false) } }
                    }
                    Section("Keep Up to Date") {
                        ForEach(OfficeProxies.Format.made) { format in Button(format.label + "…") { pick(format, keep: true) } }
                    }
                } label: {
                    Label("Make proxies of a folder", systemImage: "plus")
                        .font(Design.Studio.body).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Design.Brand.deep, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                }
                .plainMenu()
                .disabled(archive.folders.isEmpty)
                .help(archive.folders.isEmpty ? "Add a folder under Folders first" : "Proxies of a shared folder, or of a folder inside one")
            }
            if let problem { ProblemLine(text: problem) }
            if made.isEmpty, proxies.working == nil, !jobs.requests.contains(where: { $0.state == .making || $0.state == .queued }),
               !archive.folders.contains(where: { !(shares.share($0)?.watch ?? []).isEmpty }) {
                Text("No proxies yet.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            makingNow
            keptUpToDate
            madeList
            Divider().overlay(Design.Studio.line)
            FootLine(text: Text("Made in \(proxies.chosenFolder?.lastPathComponent ?? String(localized: "Pluck’s own folder"))")) {
                PinkMenu {
                    Button("Choose a Folder…", action: chooseFolder)
                    if proxies.chosenFolder != nil { Button("Use Pluck’s Own Folder") { try? proxies.choose(nil) } }
                    Divider()
                    Button("Show in Finder") {
                        let folder = proxies.chosenFolder ?? OfficeProxies.root
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
            .help(proxies.chosenFolder?.path ?? String(localized: "Where proxies that paired Macs ask for are made on this Mac"))
            if group.isGrouped {
                if let problem = group.problem {
                    ProblemLine(text: problem, colour: Design.Studio.warn)
                } else if onNAS == false {
                    ProblemLine(text: String(localized: "Choose a folder on the NAS, so every office Mac makes and serves the same proxies."), colour: Design.Studio.warn)
                }
            }
            FootLine(text: Text("Delete unused after")) {
                Menu {
                    Picker("Delete unused after", selection: $keepDays) {
                        ForEach(Self.keepChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    PlainMenuLabel(title: keepLabel)
                }
                .plainMenu()
                .help("Only proxies in Pluck’s own folder; a folder you chose is yours to keep")
            }
        }
        .task {
            // (Every 30 s, each look given up on after 20 s: a chosen folder on a NAS that hangs keeps the last list.)
            while !Task.isCancelled {
                if let found = await proxies.made() { made = found }
                if group.isGrouped {
                    let folder = proxies.chosenFolder
                    if let looked = await RemoteShares.withTimeout("proxies.onNAS", nil, { folder.map { OfficeGroup.place($0) != nil } ?? false }) {
                        onNAS = looked
                    }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(Text(deleteTitle), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            if let deleting, !proxies.watches(of: deleting).isEmpty {
                Button("Delete and Stop Keeping Up to Date", role: .destructive) { delete(deleting, stopWatching: true) }
            }
            Button("Delete", role: .destructive) { if let deleting { delete(deleting, stopWatching: false) } }
        } message: {
            if let deleting, !proxies.watches(of: deleting).isEmpty {
                Text("This folder is kept up to date, so new files there get proxies again.")
            }
        }
    }

    private var keepLabel: String {
        switch keepDays {
        case 0: String(localized: "Never")
        case 7: String(localized: "1 week")
        case 90: String(localized: "3 months")
        default: String(localized: "3 weeks")
        }
    }

    /// Its proxies to the Trash; `stopWatching`: the watched folders that make them stop too.
    private func delete(_ item: OfficeProxies.Made, stopWatching: Bool) {
        if stopWatching {
            for (folder, watch) in proxies.watches(of: item) { shares.removeWatch(watch, in: folder) }
        }
        made.removeAll { $0 == item }
        deleting = nil
        Task { await proxies.delete(item) }
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: deleting.bytes, countStyle: .file)
        return String(localized: "Move \(deleting.clips) proxies (\(size)) to the Trash? Paired Macs can ask for them again.")
    }

    // MARK: Making now

    @ViewBuilder
    private var makingNow: some View {
        let active = jobs.requests.filter { $0.state == .making || $0.state == .queued }
        let waiting = active.filter { $0.state == .queued }
        let left = active.reduce(0) { $0 + ($1.total == 0 ? 1 : max($1.total - $1.done - $1.failed.count, 0)) }
            + (proxies.working != nil ? proxies.queued + 1 : 0)
        if !active.isEmpty || proxies.working != nil {
            GroupTitle(text: Text("Making now · \(left) left"))
            ForEach(active.filter { $0.state == .making }) { request in running(request) }
            if let file = proxies.working {
                // Whole folders asked for by older Macs (OfficeProxies).
                runningRow(file: file, detail: String(localized: "A whole folder"), share: proxies.progress) { proxies.stopMaking() }
            }
            if !waiting.isEmpty {
                HStack {
                    Text("^[\(waiting.count) more](inflect: true) waiting").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    PinkLink(title: "Stop all") { for request in waiting { jobs.remove(request.id) } }
                }
            }
        }
    }

    private func running(_ request: RemoteProxyJobs.Request) -> some View {
        let file = jobs.current == request.id ? jobs.working : nil
        let place = ([shareName(request.share)] + request.paths.filter { !$0.isEmpty }).joined(separator: "/")
        let share = request.total > 0 ? (Double(request.done) + (jobs.current == request.id ? jobs.progress : 0)) / Double(request.total) : 0
        return runningRow(file: file ?? String(localized: "Looking for videos…"),
                          detail: [place, request.format.label, asker(request)].joined(separator: " · "), share: share) {
            jobs.remove(request.id)
        }
    }

    private func runningRow(file: String, detail: String, share: Double, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "film", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file).font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    StudioProgress(share: share)
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            Button("Stop", action: stop).buttonStyle(StudioFlatButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }

    private func shareName(_ id: String) -> String {
        archive.folders.first { OfficeProxies.isShare($0, id: id) }?.lastPathComponent ?? String(localized: "A removed folder")
    }

    private func asker(_ request: RemoteProxyJobs.Request) -> String {
        if request.byHost == true { return String(localized: "This Mac") }
        if let peer = request.peer { return String(localized: "Shared by \(peer)") }
        guard let device = request.device else { return String(localized: "Kept up to date") }
        return server.devices.first { $0.id == device }?.name ?? String(localized: "A paired Mac")
    }

    // MARK: Kept up to date

    @ViewBuilder
    private var keptUpToDate: some View {
        let watches = archive.folders.flatMap { folder in
            (shares.share(folder)?.watch ?? []).map { (id: folder.path + "#" + $0.path + "#" + $0.format.rawValue, folder: folder, watch: $0) }
        }
        if !watches.isEmpty {
            GroupTitle(text: Text("Kept up to date"))
            ForEach(watches, id: \.id) { item in
                HStack(spacing: 12) {
                    StudioTile(symbol: "arrow.triangle.2.circlepath", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: ([item.folder.lastPathComponent] + (item.watch.path.isEmpty ? [] : [item.watch.path])).joined(separator: "/"))
                            .font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: item.watch.format.label).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    Spacer(minLength: 0)
                    Button("Stop") { shares.removeWatch(item.watch, in: item.folder) }
                        .buttonStyle(StudioFlatButtonStyle())
                        .help("Stop keeping it proxied")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .studioBox()
                .help("New files here get proxies by themselves")
            }
        }
    }

    // MARK: Made

    @ViewBuilder
    private var madeList: some View {
        if !made.isEmpty {
            GroupTitle(text: Text("Made · per folder"))
            ForEach(made) { item in
                HStack(spacing: 12) {
                    StudioTile(symbol: "folder", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: item.name).font(Design.Studio.body).lineLimit(1)
                            StudioChip(text: Text(verbatim: item.format == .prores ? "ProRes" : item.format == .stream ? "H.265 720p" : "H.265"))
                        }
                        Text(madeDetail(item)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        .buttonStyle(StudioFlatButtonStyle())
                    IconButton(symbol: "trash", label: "Delete these proxies", tint: Design.Studio.bad) { deleting = item }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .studioBox()
            }
        }
    }

    private func madeDetail(_ item: OfficeProxies.Made) -> String {
        var parts = [String(AttributedString(localized: "^[\(item.clips) clip](inflect: true)").characters),
                     ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)]
        if let used = item.lastUsed { parts.append(String(localized: "last used \(used.formatted(.relative(presentation: .named)))")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// A shared folder, or a folder inside one, for proxies now (`keep`: and of new files later).
    private func pick(_ format: OfficeProxies.Format, keep: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = archive.folders.first
        panel.prompt = keep ? String(localized: "Keep Proxied") : String(localized: "Make Proxies")
        panel.message = keep ? String(localized: "New files in this folder get proxies by themselves.")
                             : String(localized: "Proxies are made of the videos in this folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = RemoteEditHost.realPath(url.path) ?? url.path
        guard let folder = archive.folders.first(where: { folder in
            let base = RemoteEditHost.realPath(folder.path) ?? folder.path
            return chosen == base || chosen.hasPrefix(base + "/")
        }) else {
            problem = String(localized: "Choose a folder inside one of the shared folders.")
            return
        }
        problem = nil
        let base = RemoteEditHost.realPath(folder.path) ?? folder.path
        let relative = chosen == base ? "" : String(chosen.dropFirst(base.count + 1))
        if keep {
            shares.addWatch(relative, format: format, in: folder)
        } else {
            jobs.add(.init(share: OfficeProxies.id(folder), paths: [relative], format: format, device: nil, byHost: true))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where proxies are made on this Mac. Pluck makes a folder per footage folder in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try proxies.choose(url)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: Renders

private struct HostRendersPane: View {
    @State private var server = OfficeRenderServer.shared
    @State private var inbox = OfficeInbox.shared
    @AppStorage(OfficeRenderServer.folderKey) private var folder = ""
    @State private var inboxProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Renders"), subtitle: Text("Paired Macs send their edit here; this Mac renders it with the originals.")) {
                if server.jobs.contains(where: { $0.state != .rendering }) {
                    PinkLink(title: "Clear finished") { server.clearFinished() }
                }
            }
            if server.jobs.isEmpty, RemoteRenderQueue.shared.items.isEmpty {
                Text("No renders yet.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            ForEach(server.jobs.reversed()) { job in row(job) }
            RemoteResolveHostSection()
            if inbox.receiving != nil || !inbox.recent.isEmpty {
                Text("Files from paired Macs").font(Design.Studio.sectionTitle).padding(.top, 8)
                if let receiving = inbox.receiving {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Receiving \(receiving)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                        StudioProgress(share: inbox.progress)
                    }
                }
                ForEach(Array(inbox.recent.prefix(5).enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 12) {
                        StudioTile(symbol: "doc", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.name).font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
                            Text("From \(file.from), \(file.at.formatted(.relative(presentation: .named)))")
                                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            .buttonStyle(StudioFlatButtonStyle())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .studioBox()
                }
            }
            if let inboxProblem { ProblemLine(text: inboxProblem) }
            Divider().overlay(Design.Studio.line)
            FootLine(text: folder.isEmpty ? Text("No render folder chosen yet").foregroundStyle(Design.Studio.warn)
                                          : Text("Renders go to \(URL(fileURLWithPath: folder).lastPathComponent)")) {
                PinkLink(title: "Change…", action: chooseFolder)
            }
            .help(folder)
            FootLine(text: Text("Files from paired Macs arrive in \(inbox.folder.lastPathComponent)")) {
                PinkMenu {
                    Button("Choose a Folder…", action: chooseInbox)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([inbox.folder])
                    }
                }
            }
            .help(inbox.folder.path)
        }
    }

    private func row(_ job: OfficeRenderServer.Job) -> some View {
        let (symbol, colour): (String, Color) = switch job.state {
        case .rendering: ("film", Design.Studio.textQuiet)
        case .done: ("checkmark", Design.Studio.good)
        case .failed: ("exclamationmark.triangle", Design.Studio.bad)
        case .cancelled: ("xmark", Design.Studio.textQuiet)
        }
        return HStack(spacing: 12) {
            StudioTile(symbol: symbol, colour: colour, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.timeline).font(Design.Studio.body).lineLimit(1)
                Text(verbatim: "\(job.project) · \(job.preset) · \(job.device)")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                if job.state == .rendering {
                    HStack(spacing: 8) {
                        StudioProgress(share: job.progress)
                        Text(job.progress, format: .percent.precision(.fractionLength(0)))
                            .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                    }
                } else if let problem = job.problem {
                    Text(problem).font(Design.Studio.hint).foregroundStyle(job.state == .failed ? Design.Studio.bad : Design.Studio.textQuiet).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if job.state == .rendering {
                Button("Stop") { Task { await server.cancel(job.id) } }.buttonStyle(StudioFlatButtonStyle())
            } else if job.state == .done, let file = job.file {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                    .buttonStyle(StudioFlatButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
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
            Group {
                if case .iroh = PrivateNetwork.Invitation(link: link.absoluteString)?.way {
                    Label("Works once, for 15 minutes, for the first Mac that uses it. Send it only to people you trust.", systemImage: "lock.shield")
                } else {
                    Label("Works once, for an hour, for the first Mac that uses it. Send it only to people you trust.", systemImage: "lock.shield")
                }
            }
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
                            ForEach(OfficeProxies.Format.allCases.filter { $0 != .stream }) { Text($0.label).tag($0) }
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
            if sync.needsConfirm {
                // The host changed since these were set up: nothing goes until a yes.
                HStack(spacing: 8) {
                    Text("Keep sending these folders to “\(OfficeRenderClient.shared.office?.name ?? "")”?")
                        .font(Design.Studio.body).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Stop") { sync.stop() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Keep") { sync.keep() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .studioBox()
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
