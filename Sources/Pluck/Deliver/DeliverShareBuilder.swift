import SwiftUI

/// The Share Builder, in Deliver's main panel: a bar (back, title, state, desktop/phone, the link's actions, Revert and
/// Update Link), the client's page as it will look on the left, the settings on the right under short headings.
struct DeliverShareBuilderView: View {
    @Bindable var session: ShareBuilderSession
    @State private var store = DeliverStore.shared
    @State private var builder = ShareBuilder.shared
    @State private var qr = false
    @State private var branding = false
    @State private var names = ""
    @State private var dropping = false
    @State private var originals: DeliverUploadDestination.Offer?
    @State private var hasDefault = DeliverLinkOptions.hasDefault

    private var draft: Deliver.ShareLink { session.draft }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(Design.Studio.line).frame(height: 1)
            HStack(spacing: 0) {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Design.Studio.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                        content
                        access
                        downloads
                        comments
                        look
                        updates
                        defaults
                    }
                    .padding(Design.Studio.panelInset)
                }
                .frame(width: 344)
            }
        }
        .alert("Discard unsaved changes?", isPresented: Binding(get: { builder.asking != nil }, set: { if !$0 { builder.asking = nil } })) {
            Button("Discard", role: .destructive) { let asked = builder.asking; builder.asking = nil; asked?.discard() }
            Button("Keep Editing", role: .cancel) { let asked = builder.asking; builder.asking = nil; asked?.keep() }
        } message: { Text("Clients only see changes after Update Link.") }
        .sheet(isPresented: $branding) { DeliverProjectBrandingSheet(project: draft.project) }
        .originalsOffer($originals)
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 8) {
            Button { builder.leave() } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(StudioFlatButtonStyle()).help("Close")
            TextField("Title", text: $session.draft.title).textFieldStyle(.plain).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                .frame(minWidth: 120, maxWidth: 320)
            state
            Spacer(minLength: 8)
            StudioSegmented(options: [(false, "Desktop"), (true, "Phone")], selection: $session.phone, symbols: ["desktopcomputer", "iphone"])
            if let link = session.stored {
                if let url = DeliverServer.shared.shareURL(link) {
                    Button("Copy Link") { DeliverLinkShare.copy(url) }.buttonStyle(StudioFlatButtonStyle())
                    Button { qr.toggle() } label: { Image(systemName: "qrcode") }.buttonStyle(StudioFlatButtonStyle()).help("QR code")
                        .popover(isPresented: $qr) {
                            VStack(spacing: 10) {
                                if let image = DeliverLinkShare.qr(url) {
                                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180).padding(10).background(.white, in: .rect(cornerRadius: 8))
                                }
                                DeliverMessageButtons(link: link, url: url)
                            }
                            .padding(14)
                        }
                }
                menu(link)
            }
            if !session.isNew && session.dirty { Button("Revert") { session.revert() }.buttonStyle(StudioFlatButtonStyle()) }
            Button(session.isNew ? "Create Link" : "Update Link") { update() }
                .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(!session.dirty).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    /// New, Unsaved changes, or how the live link stands.
    @ViewBuilder private var state: some View {
        if session.isNew {
            StudioChip(text: Text("New link"))
        } else if session.dirty {
            StudioChip(text: Text("Unsaved changes"), colour: Design.Studio.warn, tinted: true).help("Clients see this when you update.")
        } else if let link = session.stored {
            if link.revoked != nil { StudioChip(text: Text("Off")) }
            else if !link.isLive { StudioChip(text: Text("Expired")) }
            else if link.isPaused { StudioChip(text: Text("Paused"), colour: Design.Studio.warn, tinted: true) }
            else if DeliverServer.shared.shareURL(link) == nil { StudioChip(text: Text("Getting the link ready…")) }
            else { StudioChip(text: Text("Live"), symbol: "circle.fill", colour: Design.Studio.good, tinted: true) }
        }
    }

    private func menu(_ link: Deliver.ShareLink) -> some View {
        Menu {
            Button(link.isPaused ? "Resume" : "Pause") { store.updateLink(link.id) { $0.paused = $0.isPaused ? nil : true } }
            Button("Duplicate as New Link") { if let copy = try? store.duplicate(link.id) { builder.open(copy.id) } }
            if let url = DeliverServer.shared.shareURL(link) { Button("Email…") { DeliverLinkShare.email(link, url: url) } }
            Button("Send Update…") { DeliverLinkRow.sendUpdate(link) }
            Divider()
            Button("Turn Off", role: .destructive) { store.revoke(link.id) }
        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Design.Studio.textQuiet) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func update() {
        let wasNew = session.isNew
        guard session.update(), let link = session.stored else { return }
        if wasNew {
            if let url = DeliverServer.shared.shareURL(link) { DeliverLinkShare.copy(url) }
            originals = DeliverUploadDestination.offer(link.scope, host: nil)
        }
    }

    // MARK: Preview

    private var preview: some View {
        let made = session.preview
        return VStack(spacing: 0) {
            if SharePreviewPage.data == nil {
                Text("The preview isn’t in this copy of Pluck.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SharePreviewWeb(manifest: made.manifest, pictures: made.pictures) { session.reorder($0) }
                    .frame(maxWidth: session.phone ? 390 : .infinity)
                    .clipShape(.rect(cornerRadius: session.phone ? 18 : 0, style: .continuous))
                    .overlay { if session.phone { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Design.Studio.line, lineWidth: 1) } }
                    .padding(session.phone ? 16 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 10))
                Text(session.dirty ? "Clients see this when you update." : "What clients see.")
                if let problem = session.problem { Text(verbatim: problem).foregroundStyle(Design.Studio.bad) }
            }
            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            .frame(height: 26)
        }
        .background(Design.Studio.backdrop)
    }

    // MARK: Settings

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).padding(.bottom, 4)
            content()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
    }

    private func flag(_ path: WritableKeyPath<Deliver.ShareLink, Bool?>) -> Binding<Bool> {
        Binding(get: { session.draft[keyPath: path] == true }, set: { session.draft[keyPath: path] = $0 ? true : nil })
    }

    private var scopeTitle: String {
        switch draft.scope {
        case .project: String(localized: "Whole project")
        case .folder: store.name(draft.scope)
        case .asset, .assets: String(localized: "Chosen assets")
        }
    }

    private var content: some View {
        let project = draft.project
        let folders = store.content(project).folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let assets = session.assets
        let others = store.content(project).assets.filter { asset in !assets.contains { $0.id == asset.id } }
        return section("Content") {
            StudioField(label: "Shares") {
                Menu {
                    Button("Whole Project") { session.draft.scope = .project(project) }
                    ForEach(folders) { folder in Button(folder.name) { session.draft.scope = .folder(folder.id, project: project) } }
                } label: { StudioMenuLabel(title: scopeTitle) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(assets) { asset in
                        HStack(spacing: 8) {
                            DeliverPoster(asset: asset).frame(width: 40, height: 23).clipShape(.rect(cornerRadius: 3, style: .continuous))
                            Text(verbatim: asset.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { session.remove(asset.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).disabled(assets.count == 1).help("Remove from this link")
                        }
                        .frame(height: 28)
                    }
                }
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { asset in Button(asset.name) { session.add(asset.id) } }
                    } label: { StudioMenuLabel(title: String(localized: "Add…")) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                Spacer()
                if draft.order != nil { Button("By Name") { session.draft.order = nil }.settingButton() }
            }
            hint("Drop folders here from the sidebar. Drag cards in the preview to order them.")
            StudioSwitchRow(title: "Show only the latest versions", isOn: $session.draft.latestOnly)
        }
        .padding(6)
        .background(dropping ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .dropDestination(for: String.self) { ids, _ in session.drop(ids) } isTargeted: { dropping = $0 }
    }

    private var access: some View {
        section("Access") {
            StudioField(label: "Mode") {
                StudioSegmented(options: [(Deliver.ShareLink.Mode.review, "Review"), (.presentation, "Presentation")], selection: $session.draft.mode)
            }
            StudioField(label: "Password") {
                let has = session.stored?.passwordHash != nil && !session.clearPassword
                SecureField(has ? "Set" : "None", text: $session.password).settingField(width: 140)
                if has { Button("Remove") { session.clearPassword = true; session.password = "" }.settingButton() }
            }
            StudioField(label: "Expires") {
                if let expires = draft.expires {
                    DatePicker("", selection: Binding(get: { expires }, set: { session.draft.expires = $0 }), in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().fixedSize()
                    Button("Never") { session.draft.expires = nil }.settingButton()
                } else {
                    Text("Never").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Button("Set…") { session.draft.expires = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(15 * 86400)).addingTimeInterval(17 * 3600) }.settingButton()
                }
            }
            StudioSwitchRow(title: "Ask for a name first", isOn: flag(\.requireName))
            if draft.requireName == true { StudioSwitchRow(title: "And an email", isOn: flag(\.askEmail)).padding(.leading, 20) }
            StudioSwitchRow(title: "Team link (sees internal comments)", isOn: Binding(get: { draft.isTeam }, set: { session.draft.audience = $0 ? "team" : nil }))
            people
        }
    }

    /// Per-person links: one each (its own key: turn one off without the others), with this link's settings.
    @ViewBuilder private var people: some View {
        let personal = store.links.filter { $0.recipient != nil && $0.scope == draft.scope && $0.isLive && $0.id != session.linkID }
        VStack(alignment: .leading, spacing: 4) {
            Text("People").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).padding(.top, 6)
            ForEach(personal) { link in
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Design.Studio.textQuiet)
                    Text(verbatim: link.recipient ?? link.title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Spacer()
                    if let url = DeliverServer.shared.shareURL(link) { Button("Copy") { DeliverLinkShare.copy(url) }.settingButton() }
                    Button("Turn Off") { store.revoke(link.id) }.settingButton()
                }
                .frame(height: 28)
            }
            if let id = session.linkID, !session.dirty {
                HStack(spacing: 6) {
                    TextField("Names, separated by commas", text: $names).settingField(width: 210).onSubmit { invite(id) }
                    Button("Invite") { invite(id) }.settingButton().disabled(names.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                hint("Update the link first, then invite people.")
            }
        }
    }

    private func invite(_ id: UUID) {
        _ = store.invite(names.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init), like: id)
        names = ""
    }

    private var downloads: some View {
        section("Downloads") {
            StudioSwitchRow(title: "Originals", isOn: $session.draft.allowDownload).disabled(draft.watermark?.burned == true)
            StudioSwitchRow(title: "Review copies", isOn: flag(\.allowProxy))
            StudioSwitchRow(title: "Clients can upload files", isOn: Binding(get: { draft.uploads != nil }, set: { session.draft.uploads = $0 ? .init() : nil }))
        }
    }

    private var comments: some View {
        section("Comments and Approval") {
            if draft.mode == .presentation {
                hint("Presentation links have no comments or approvals.")
            } else {
                StudioField(label: "Reviewers set") {
                    Picker(selection: Binding(get: { draft.featuredField ?? "status" }, set: { value in
                        session.draft.featuredField = value == "status" ? nil : value
                        session.draft.fields = value == "rating" ? ["status", "rating"] : nil
                    })) {
                        Text("Status").tag("status")
                        Text("Rating").tag("rating")
                        Text("Nothing").tag("none")
                    } label: { EmptyView() }.fixedSize()
                }
                if !(store.library.statuses ?? []).isEmpty { StudioSwitchRow(title: "Show custom statuses", isOn: flag(\.customStatuses)) }
                ForEach(store.fieldDefs) { def in
                    StudioSwitchRow(title: "Show \(def.name)", isOn: Binding(get: { draft.shownFields.contains(def.wireName) }, set: { on in
                        var shown = draft.shownFields.filter { $0 != def.wireName }
                        if on { shown.append(def.wireName) }
                        session.draft.fields = shown == ["status"] ? nil : shown
                    }))
                }
                StudioField(label: "Feedback by") {
                    if let deadline = draft.deadline, deadline != .distantFuture {
                        DatePicker("", selection: Binding(get: { deadline }, set: { session.draft.deadline = $0 }), in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().fixedSize()
                        Button("None") { session.draft.deadline = nil }.settingButton()
                    } else {
                        Button("Set…") { session.draft.deadline = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(7 * 86400)).addingTimeInterval(17 * 3600) }.settingButton()
                    }
                }
                hint(draft.isTeam ? "Internal comments show: it’s a team link." : "Internal comments stay hidden.")
            }
        }
    }

    private var look: some View {
        section("Look") {
            StudioField(label: "Layout") {
                StudioSegmented(options: [("grid", "Grid"), ("list", "List"), ("reel", "Reel")],
                                selection: Binding(get: { draft.layout ?? "grid" }, set: { session.draft.layout = $0 == "grid" ? nil : $0 }))
            }
            StudioField(label: "Note") {
                TextField("Shown at the top", text: Binding(get: { draft.description ?? "" }, set: { session.draft.description = $0.isEmpty ? nil : $0 })).settingField(width: 200)
            }
            StudioField(label: "Branding") {
                Text(store.projectBranding(draft.project) == nil ? "From Settings" : "This project’s").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Button("Edit…") { branding = true }.settingButton()
            }
            StudioSwitchRow(title: "Watermark", isOn: Binding(get: { draft.watermark != nil }, set: { session.draft.watermark = $0 ? .init() : nil }))
            if let mark = draft.watermark {
                VStack(alignment: .leading, spacing: 2) {
                    StudioField(label: "Text") {
                        TextField("{name} · {email} · {date}", text: Binding(get: { mark.text }, set: { session.draft.watermark?.text = String($0.prefix(120)) })).settingField(width: 180)
                    }
                    StudioField(label: "Position") {
                        Picker(selection: Binding(get: { mark.position }, set: { session.draft.watermark?.position = $0 })) {
                            Text("Centre").tag("center")
                            Text("Top Left").tag("topLeft")
                            Text("Top Right").tag("topRight")
                            Text("Bottom Left").tag("bottomLeft")
                            Text("Bottom Right").tag("bottomRight")
                        } label: { EmptyView() }.fixedSize()
                    }
                    StudioField(label: "Opacity") {
                        Slider(value: Binding(get: { mark.opacity }, set: { session.draft.watermark?.opacity = $0 }), in: 0.1...0.8).frame(width: 140)
                    }
                    StudioSwitchRow(title: "Burn into this link’s copies", isOn: Binding(get: { mark.burned }, set: { value in
                        session.draft.watermark?.burned = value
                        if value { session.draft.allowDownload = false }   // (originals carry no watermark)
                    }))
                    if mark.burned, let problem = DeliverCopies.shared.markProblem {
                        Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private var updates: some View {
        section("Email Updates") {
            StudioSwitchRow(title: "Tell me when it’s opened", isOn: flag(\.notifyOpened))
            if DeliverMail.shared.available {
                StudioSwitchRow(title: "Email updates", isOn: Binding(get: { draft.notify?.email == true }, set: { on in
                    session.draft.notify = on ? .init(email: true, recipientEmail: draft.notify?.recipientEmail) : nil
                }))
                if draft.notify?.email == true, draft.recipient != nil {
                    StudioField(label: "Email") {
                        TextField("name@example.com", text: Binding(get: { draft.notify?.recipientEmail ?? "" }, set: { session.draft.notify?.recipientEmail = $0.isEmpty ? nil : String($0.prefix(120)) }))
                            .settingField(width: 200)
                    }
                }
            } else {
                hint("Email updates need a NAS that sends mail.")
            }
        }
    }

    /// Save as Default: how new links start (not their title, password, expiry or what they share).
    private var defaults: some View {
        HStack(spacing: 6) {
            Button("Save as Default") { DeliverLinkOptions.saveDefault(draft); hasDefault = true }.settingButton().help("New links start with these settings.")
            if hasDefault {
                Button("Reset to Pluck’s Defaults") { DeliverLinkOptions.resetDefault(); hasDefault = false }.settingButton()
            }
        }
    }
}
