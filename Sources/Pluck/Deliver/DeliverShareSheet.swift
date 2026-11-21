import CoreImage.CIFilterBuiltins
import SwiftUI

/// §13.24 H1: a level-3 link whose room no server of the owner's holds yet ("Getting the link ready…": this Mac's
/// helper keeps registering it), or one someone else registered first (a problem, with "Make a New Link").
struct DeliverLinkPending: View {
    let link: Deliver.ShareLink

    var body: some View {
        HStack(spacing: 8) {
            if DeliverServer.shared.isTaken(link) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.bad)
                Text("Someone else is holding this link's room. Make a new link.").font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                Spacer()
                Button("Make a New Link") { DeliverLink.shared.renew(link.id) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            } else {
                ProgressView().controlSize(.small)
                Text("Getting the link ready…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
            }
        }
        .frame(minHeight: 28)
    }
}

/// A made link: the address with Copy, Email… (a draft in Mail) and its QR code.
struct DeliverLinkShare: View {
    let link: Deliver.ShareLink
    let url: String
    @State private var qr = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: url).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius))
                Button("Copy") { Self.copy(url) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                Button("Email…") { Self.email(link, url: url) }.buttonStyle(StudioFlatButtonStyle())
                Button { qr.toggle() } label: { Image(systemName: "qrcode") }.buttonStyle(StudioFlatButtonStyle()).help("QR code")
            }
            DeliverMessageButtons(link: link, url: url)
            if qr, let image = Self.qr(url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                    .padding(10).background(.white, in: .rect(cornerRadius: 8))
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The link as a QR code (CoreImage), black on white.
    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// mailto: with the title and the link; the password (if any) is left for another message.
    static func mailto(subject: String, body: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = ""
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return parts.url
    }

    static func email(_ link: Deliver.ShareLink, url: String) {
        var body = String(localized: "Here’s the link to review “\(link.title)”:") + "\n\n" + url + "\n"
        if link.passwordHash != nil { body += "\n" + String(localized: "It has a password; I’ll send it separately.") + "\n" }
        if let expires = link.expires { body += "\n" + String(localized: "It works until \(expires.formatted(date: .abbreviated, time: .shortened)).") + "\n" }
        if let mail = mailto(subject: link.title, body: body) { NSWorkspace.shared.open(mail) }
    }
}

/// A link's settings: Save as Default (this Mac's starting point for new links), and a draft's settings onto a link
/// (the Share Builder edits them).
enum DeliverLinkOptions {
    // MARK: - Default settings for new links (this Mac)

    static let defaultKey = "deliverLinkDefault"
    static var hasDefault: Bool { UserDefaults.standard.data(forKey: defaultKey) != nil }

    /// What Save as Default keeps: how a link behaves. Not its title, note, password, expiry, deadline, what it shares or who (team).
    static func preset(from source: Deliver.ShareLink, to link: inout Deliver.ShareLink) {
        link.mode = source.mode
        link.allowDownload = source.allowDownload
        link.latestOnly = source.latestOnly
        link.layout = source.layout
        link.requireName = source.requireName
        link.askEmail = source.askEmail
        link.allowProxy = source.allowProxy
        link.watermark = source.watermark
        link.fields = source.fields
        link.featuredField = source.featuredField
        link.uploads = source.uploads.map { var uploads = $0; uploads.folder = nil; return uploads }   // (a folder is one project's)
        link.notifyOpened = source.notifyOpened
    }

    static func saveDefault(_ draft: Deliver.ShareLink) {
        var kept = Deliver.ShareLink(title: "", scope: draft.scope, roomID: "")
        preset(from: draft, to: &kept)
        UserDefaults.standard.set(try? Deliver.encoder.encode(kept), forKey: defaultKey)
    }

    static func resetDefault() { UserDefaults.standard.removeObject(forKey: defaultKey) }

    /// A new link's draft: Pluck's defaults, or the ones saved here.
    static func draft(_ scope: Deliver.Scope) -> Deliver.ShareLink {
        var draft = Deliver.ShareLink(title: "", scope: scope, roomID: "")
        if let data = UserDefaults.standard.data(forKey: defaultKey), let saved = try? Deliver.decoder.decode(Deliver.ShareLink.self, from: data) {
            preset(from: saved, to: &draft)
        }
        return draft
    }

    /// The settings that aren't the basics, from a draft onto a made link.
    static func apply(_ draft: Deliver.ShareLink, to link: inout Deliver.ShareLink) {
        link.description = draft.description?.isEmpty == false ? Deliver.clean(draft.description!, limit: DeliverStore.textLimit) : nil
        link.layout = draft.layout
        link.requireName = draft.requireName
        link.askEmail = draft.askEmail
        link.allowProxy = draft.allowProxy
        link.audience = draft.audience
        link.watermark = draft.watermark
        link.fields = draft.fields
        link.featuredField = draft.featuredField
        link.uploads = draft.uploads
        link.notifyOpened = draft.notifyOpened
        link.notify = draft.notify
        link.deadline = draft.deadline
        link.customStatuses = draft.customStatuses
    }

    /// An edit saved; a changed watermark makes that link's burned-in copies again.
    @MainActor static func save(_ changed: Deliver.ShareLink, store: DeliverStore = .shared) {
        let before = store.link(changed.id)
        store.updateLink(changed.id) { $0 = changed }
        // (Assets added to a link with a burned-in watermark need their marked copies too.)
        if before?.watermark != changed.watermark || (before?.scope != changed.scope && changed.watermark?.burned == true) { DeliverCopies.shared.remark(changed) }
    }
}

/// Publish to an always-on host the owner controls, so clients can watch while this Mac is off. With a NAS paired it is
/// NAS first: its main and backup with where this scope stands there, then an always-on Mac as the fallback; "This Mac
/// only" only when there's neither (clients are never served from this Mac while something else can).
struct DeliverPublishSheet: View {
    let scope: Deliver.Scope
    @Environment(\.dismiss) private var dismiss
    @State private var publish = ReviewPublish.shared
    @State private var chosen: UUID?
    @State private var guide = false
    @State private var originals: DeliverUploadDestination.Offer?
    @State private var picking: DeliverUploadDestination.Offer?
    // (Observed so the states below follow uploads, the queue and sync.)
    @State private var uploads = DeliverUploads.shared
    @State private var queue = DeliverShareQueue.shared
    @State private var sync = DeliverSync.shared

    /// Every NAS, the main(s) before the backup.
    private var nases: [Deliver.Host] { publish.hosts.filter { $0.kind == .nas }.sorted { ($0.role == "backup" ? 1 : 0) < ($1.role == "backup" ? 1 : 0) } }

    var body: some View {
        let nases = self.nases
        let choices = publish.choices.filter { $0.kind == .mac || $0.role != "backup" }
        let macs = choices.filter { $0.kind == .mac }
        let main = DeliverUploadDestination.mainNAS(project: scope.project)
        VStack(alignment: .leading, spacing: 14) {
            Text("Publish").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            if nases.isEmpty {
                VStack(spacing: 6) {
                    // Same rule as the helper (DeliverLink.neverServe): this Mac is offered only when it may serve.
                    if choices.isEmpty && !DeliverLink.shared.neverServe { hostRow(nil, name: String(localized: "This Mac only"), symbol: "desktopcomputer", online: true) }
                    ForEach(choices) { host in hostRow(host.id, name: host.name, symbol: "macmini", online: publish.online[host.id]) }
                }
                HStack {
                    Text("Pair an always-on Mac in Edit Anywhere, or set up a NAS.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    Button("Set Up a NAS Host…") { guide = true }.buttonStyle(StudioFlatButtonStyle())
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(nases) { nasRow($0, selectable: choices.contains($0)) }
                    // The fallback after the NAS: an always-on Mac, never this one.
                    ForEach(macs) { host in
                        hostRow(host.id, name: host.name, symbol: "macmini", online: publish.online[host.id], note: String(localized: "If the NAS is down"))
                    }
                }
            }
            if let chosen, let host = choices.first(where: { $0.id == chosen }), host.kind == .nas {
                let plan = publish.plan(scope, host: host)
                if !plan.referenced.isEmpty { Label("\(plan.referenced.count) on the NAS already: it makes their review copies itself", systemImage: "checkmark.circle").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                if !plan.sent.isEmpty { Label("\(plan.sent.count) sent from this Mac", systemImage: "arrow.up.circle").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            }
            // Where it's published now.
            ForEach(publish.publications.filter { $0.scope == scope }) { item in
                HStack(spacing: 8) {
                    let host = publish.host(item.host)
                    Circle().fill(publish.online[item.host] == false ? Design.Studio.textFaint : Design.Studio.good).frame(width: 7, height: 7)
                    if let making = publish.hostState[item.id]?.making {
                        Text("Making review copies on the NAS… \(Int(making * 100))%").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    } else {
                        Text("Live on \(host?.name ?? "")").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    }
                    Spacer()
                    Button("Remove from Host") { Task { await publish.remove(item.id) } }.buttonStyle(StudioFlatButtonStyle())
                }
                .padding(10).studioBox()
            }
            DeliverWaitingRows(project: scope.project)
            if let problem = publish.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                if publish.working != nil { PlumSpinner() }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                if let main, !nases.isEmpty, !DeliverUploadDestination.onlyHere(scope).isEmpty {
                    Button("Upload Originals…") { picking = DeliverUploadDestination.offer(scope, host: main, asking: false) }
                        .buttonStyle(StudioFlatButtonStyle(prominent: choices.isEmpty))
                }
                if !choices.isEmpty || nases.isEmpty {
                    Button("Publish") {
                        guard let host = choices.first(where: { $0.id == chosen }) else { return dismiss() }
                        Task {
                            await publish.publish(scope, to: host)
                            if host.kind == .nas { originals = DeliverUploadDestination.offer(scope, host: host) }
                        }
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .disabled(chosen == nil || publish.working != nil)
                }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .sheet(isPresented: $guide) { ReviewNASGuideSheet() }
        .originalsOffer($originals)
        .originalsPicker($picking)
        .onAppear { if chosen == nil { chosen = choices.first?.id } }
        // The data NAS gets this scope through sync: a round now, so what's shown is where it stands.
        .task { if !nases.isEmpty, sync.dataHost != nil { await sync.round() } }
    }

    /// A NAS: main or backup, and this scope's state there. The data host isn't chosen (it syncs); another NAS is, to publish.
    private func nasRow(_ host: Deliver.Host, selectable: Bool) -> some View {
        let backup = host.role == "backup"
        let published = publish.publications.contains { $0.host == host.id && ($0.scope == scope || $0.scope == .project(scope.project)) }
        let row = HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below").frame(width: 18)
            Text(verbatim: host.name).font(Design.Studio.body).lineLimit(1)
            StudioChip(text: backup ? Text("Backup") : Text("Main"), colour: Design.Studio.textQuiet)
            Spacer(minLength: 8)
            if publish.online[host.id] == false { Text("Offline").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            if backup {
                Text("Copy of the main").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            } else if ReviewPublish.isDataHost(host.id) || published {
                DeliverNASStateLabel(state: DeliverUploadDestination.state(scope, host: host))
            } else {
                Text("Not published").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if selectable {
                Image(systemName: chosen == host.id ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen == host.id ? Design.Brand.pink : Design.Studio.textQuiet)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(.horizontal, 12).frame(height: 36)
        .studioBox()
        .contentShape(.rect)
        return Button { if selectable { chosen = host.id } } label: { row }.buttonStyle(.plain)
    }

    private func hostRow(_ id: UUID?, name: String, symbol: String, online: Bool?, note: String? = nil) -> some View {
        Button { chosen = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(verbatim: name).font(Design.Studio.body)
                Spacer()
                if let note { Text(verbatim: note).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                if online == false { Text("Offline").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
                Image(systemName: chosen == id ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen == id ? Design.Brand.pink : Design.Studio.textQuiet)
            }
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 12).frame(height: 36)
            .studioBox()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Settings › Review: the name on the owner's comments, the review copies' space, hosting for paired Macs, NAS hosts.
struct DeliverSettings: View {
    static let authorKey = "reviewAuthorName", askedKey = "reviewAuthorAsked"
    /// The owner's name on comments made here: what they chose (asked once, DeliverNamePrompt), else "Editor".
    @MainActor static var author: String {
        let name = UserDefaults.standard.string(forKey: authorKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? String(localized: "Editor") : name
    }

    @AppStorage(DeliverSettings.authorKey) private var name = ""
    @State private var library = false
    @AppStorage(ReviewHosting.settingKey) private var hosting = false
    @AppStorage(DeliverUploadDestination.newFootageKey) private var footageOnNAS = true
    @AppStorage(DeliverStore.activityDaysKey) private var activityDays = 90
    @AppStorage(DeliverShareArchive.forgetKey) private var forgetMonths = 12
    @State private var space: Int64?
    @State private var publish = ReviewPublish.shared
    @State private var adding = false
    @State private var guide = false
    @State private var nasName = ""
    @State private var nasAddress = ""
    @State private var nasKey = ""
    @State private var mountLocal = ""
    @State private var mountRemote = ""
    @State private var detail: Deliver.Host?
    @State private var truenas = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            DeliverDataHostCard()
            SettingsCard("Comments") {
                SettingRow("Name in comments") {
                    TextField("Editor", text: $name).settingField(width: 200)
                }
                SettingRow("Keep activity", help: String(localized: "Who opened, watched and commented, with name and email. You keep this; tell your clients.")) {
                    SettingMenu(title: activityDays == 0 ? String(localized: "Forever") : String(localized: "\(activityDays) days"), selection: $activityDays) {
                        ForEach(DeliverStore.activityChoices, id: \.self) { Text($0 == 0 ? String(localized: "Forever") : String(localized: "\($0) days")).tag($0) }
                    }
                    .onChange(of: activityDays) { DeliverStore.shared.trimAllActivity() }
                }
                SettingRow("Clear client data", help: String(localized: "Clients’ emails and the activity of an archived link are deleted then. Approvals keep the name and date.")) {
                    SettingMenu(title: forgetMonths == 0 ? String(localized: "Never") : String(localized: "\(forgetMonths) months after archiving"), selection: $forgetMonths) {
                        ForEach(DeliverShareArchive.forgetChoices, id: \.self) { Text($0 == 0 ? String(localized: "Never") : String(localized: "\($0) months after archiving")).tag($0) }
                    }
                    .onChange(of: forgetMonths) { DeliverShareArchive.forget() }
                }
            }
            SettingsCard("Statuses and Fields") {
                SettingRow("Custom statuses and fields") { Button("Edit…") { library = true }.settingButton() }
            }
            SettingsCard("Branding") {
                DeliverBrandingEditor(branding: Binding(get: { DeliverStore.shared.branding }, set: { DeliverStore.shared.branding = $0 }))
            }
            SettingsCard("Review Copies") {
                SettingRow(text: Text("Space used"), detail: space.map { Text(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) }) {
                    Button("Delete Review Copies") {
                        DeliverStore.shared.deleteCopies()
                        DeliverCopies.shared.resume()
                        measure()
                    }.settingButton()
                }
            }
            SettingsCard("Hosting") {
                SettingSwitch("Host published reviews for paired Macs", isOn: $hosting)
                    .onChange(of: hosting) { ReviewHosting.shared.update() }
                if publish.hosts.contains(where: { $0.kind == .nas }) {
                    SettingSwitch("Put new footage on the NAS", help: String(localized: "Originals added to Deliver are uploaded to the NAS, into the folder you pick."), isOn: $footageOnNAS)
                }
                ForEach(publish.hosts.filter { $0.kind == .nas }) { host in
                    SettingRow(text: Text(verbatim: host.name), detail: Text(verbatim: (host.address ?? "") + ((host.mounts ?? []).first.map { " · \($0.local) ↔ \($0.remote)" } ?? ""))) {
                        Button("Details…") { detail = host }.settingButton()
                        Button("Remove") { publish.removeHost(host.id) }.settingButton()
                    }
                }
                if adding {
                    VStack(spacing: 2) {
                        StudioField(label: "Name") { TextField("NAS", text: $nasName).settingField(width: 220) }
                        StudioField(label: "Address") {
                            TextField("nas.local:8790", text: $nasAddress).settingField(width: 220)
                                .onChange(of: nasAddress) {
                                    if let guess = ReviewPublish.guessMounts(server: nasAddress).first { mountLocal = guess.local; mountRemote = guess.remote }
                                }
                        }
                        StudioField(label: "Pairing") { SecureField("pluck-host:…", text: $nasKey).settingField(width: 220) }
                        // Where the NAS's media is mounted here, and that folder on the NAS: originals inside it are published by reference.
                        StudioField(label: "Mounted at") { TextField("/Volumes/Footage", text: $mountLocal).settingField(width: 220) }
                        StudioField(label: "On the NAS") { TextField("nas1", text: $mountRemote).settingField(width: 220) }
                        HStack {
                            Spacer()
                            Button("Cancel") { adding = false }.settingButton()
                            Button("Add") {
                                guard let host = publish.addNAS(name: nasName, address: nasAddress, pairing: nasKey) else { return }
                                let typed = mountLocal.isEmpty || mountRemote.isEmpty ? [] : [Deliver.Host.Mount(local: mountLocal, remote: mountRemote)]
                                publish.setMounts(typed.isEmpty ? ReviewPublish.guessMounts(server: nasAddress) : typed, host: host.id)
                                adding = false
                            }.settingButton().disabled(nasAddress.isEmpty || ReviewHostClient.pairing(nasKey)?.pin == nil) // the line with its fingerprint
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                } else {
                    SettingRow("NAS") {
                        Button("TrueNAS (Automatic)…") { truenas = true }.settingButton()
                        Button("Set Up…") { guide = true }.settingButton()
                        Button("Add NAS…") { adding = true; nasName = ""; nasAddress = ""; nasKey = "" }.settingButton()
                    }
                }
            }
            if let office = DeliverMail.shared.office, DeliverMail.shared.available {
                VStack(alignment: .leading, spacing: 6) {
                    DeliverMailSection(host: office)
                    Text("Sent by \(office.name). Email works best from a NAS.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            DeliverRelaySettingsCard()
            SettingsCard("Message") { DeliverMessageEditor() }
        }
        .task {
            measure()
            if DeliverMail.shared.office != nil { await DeliverMail.shared.refresh() }
        }
        .sheet(isPresented: $guide) { ReviewNASGuideSheet() }
        .sheet(isPresented: $truenas) { ReviewTrueNASSetupSheet() }
        .sheet(item: $detail) { DeliverHostSheet(host: $0) }
        .sheet(isPresented: $library) { DeliverLibraryEditor() }
    }

    private func measure() {
        let folder = DeliverStore.shared.copiesFolder
        Task { space = await Task.detached { DeliverStore.size(of: folder) }.value }
    }
}
