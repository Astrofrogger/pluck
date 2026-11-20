import AppKit
import SwiftUI

/// The host's shares in Edit Anywhere → Share this Mac → Folders: each folder with what it's on and its
/// free space (or offline), and a Remove that asks first. Proxies and watches are under Proxies.
struct RemoteSharesList: View {
    @State private var archive = OfficeArchive.shared
    @State private var shares = RemoteShares.shared
    @State private var removing: URL?
    @State private var asking: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(archive.folders, id: \.self) { folder in
                row(folder)
                RemoteFolderPeople(folder: folder).padding(.leading, 14)
            }
        }
        .task(id: archive.folders) {
            while !Task.isCancelled {
                await shares.sync()
                for folder in archive.folders { _ = await shares.state(folder) }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(item: Binding(get: { asking.map(AskTarget.init) }, set: { asking = $0?.folder })) { target in
            RemoteAskFilesSheet(folderName: target.folder.lastPathComponent) { name, password, days, bytes, types in
                try await RemoteAskFiles.shared.make(folder: target.folder, share: OfficeProxies.id(target.folder), path: "", title: name,
                                                     password: password, days: days, maxBytes: bytes, types: types, device: nil).url
            }
        }
        .alert(Text("Remove “\(removing?.lastPathComponent ?? "")”?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let removing { archive.remove(removing) }
                removing = nil
            }
        } message: {
            Text("Paired Macs can’t browse it any more. Your files stay where they are. Its proxies stay until you delete them under Proxies.")
        }
    }

    private func row(_ folder: URL) -> some View {
        let state = shares.states[folder.path], share = shares.share(folder)
        let online = state?.online ?? true
        return HStack(spacing: 12) {
            StudioTile(symbol: online ? (state?.network == true ? "externaldrive.connected.to.line.below" : "internaldrive")
                       : "externaldrive.badge.xmark",
                       colour: online ? Design.Studio.textQuiet : Design.Studio.warn, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent).font(Design.Studio.body).lineLimit(1)
                Group {
                    if let state, !state.online {
                        Text("Offline").foregroundStyle(Design.Studio.warn)
                    } else if let state, state.total > 0 {
                        Text(verbatim: [state.kind, String(localized: "\(ByteCountFormatter.string(fromByteCount: state.free, countStyle: .file)) free")]
                            .compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text(verbatim: folder.deletingLastPathComponent().path)
                    }
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            }
            .help(share?.volume.map { "\($0) – \(folder.path)" } ?? folder.path)
            Spacer(minLength: 0)
            let nas = RemoteAskFiles.nasPlace(folder) != nil
            Button("Ask for Files…") { asking = folder }
                .buttonStyle(StudioFlatButtonStyle())
                .disabled(!nas)
                .help(nas ? String(localized: "A link anyone can upload to: the files land in this folder on the NAS") : RemoteAskFiles.needsServer)
            Button("Remove") { removing = folder }
                .buttonStyle(StudioFlatButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }
}

/// What a paired Mac may do on this Mac (Macs → its role): Viewer, Downloader, Editor or Admin (OfficeAccess), or
/// Custom with today's switches; who it belongs to on the Deliver team; Full Trust.
struct RemoteRightsMenu: View {
    let device: OfficeRenderServer.Device
    @State private var access = OfficeAccess.shared
    @State private var people = DeliverPeople.shared

    private static let rights: [(WritableKeyPath<OfficeRenderServer.Device.Rights, Bool>, LocalizedStringKey)] = [
        (\.browse, "Browse Footage"), (\.proxies, "Fetch Proxies"), (\.originals, "Fetch Originals"), (\.render, "Render and Send Files"),
    ]

    /// The Deliver team (Admins and Editors), not its clients.
    private var team: [Deliver.Person] { (people.people.people ?? []).filter { $0.role == "editor" || $0.role == "owner" } }
    private var personGrant: OfficeAccess.Grant? {
        device.person.flatMap { person in access.grants.first { $0.subject == OfficeAccess.person(person) && $0.folder == nil } }
    }
    private var role: OfficeAccess.Role? { OfficeAccess.role(for: device, grants: access.grants) }

    var body: some View {
        Menu {
            ForEach(OfficeAccess.Role.assignable) { role in
                Toggle(isOn: Binding(get: { self.role == role }, set: { if $0 { choose(role) } })) {
                    Text(role.title)
                    Text(role.help)
                }
            }
            Menu("Custom") {
                ForEach(Self.rights.indices, id: \.self) { index in
                    let (key, title) = Self.rights[index]
                    Toggle(title, isOn: Binding(get: { device.allowed[keyPath: key] }, set: { value in
                        var rights = device.allowed
                        rights[keyPath: key] = value
                        OfficeRenderServer.shared.setRights(rights, for: device.id)
                    }))
                }
            }
            .disabled(device.person != nil && personGrant?.live != nil)
            Divider()
            Menu("Belongs To") {
                Toggle("No One", isOn: Binding(get: { device.person == nil }, set: { if $0 { OfficeRenderServer.shared.setPerson(nil, for: device.id) } }))
                ForEach(team) { person in
                    Toggle(person.name ?? person.email ?? person.id, isOn: Binding(get: { device.person == person.id }, set: { if $0 { belong(to: person) } }))
                }
            }
            Toggle("Full Trust", isOn: Binding(get: { device.allowed.fullTrust },
                                               set: { OfficeRenderServer.shared.setFullTrust($0, for: device.id) }))
            .help("Renders anything this Mac sends, without checking which files it uses. Only for your own Macs.")
        } label: {
            HStack(spacing: 5) {
                if device.allowed.fullTrust { Image(systemName: "checkmark.shield").font(.system(size: 11)) }
                Text(verbatim: role?.title ?? String(localized: "Custom"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("What this Mac may do here")
        .help(personGrant?.live != nil ? String(localized: "The role of the person it belongs to: it counts for all their Macs")
                                       : String(localized: "What this Mac may do here"))
        .task { if people.people.people == nil { await people.load() } }
    }

    /// A Mac of a person: the person's role changes (all their Macs). Else the Mac's own.
    private func choose(_ role: OfficeAccess.Role) {
        if let person = device.person, personGrant?.live != nil {
            access.set(subject: OfficeAccess.person(person), folder: nil, role: role, name: personGrant?.name)
        } else {
            OfficeRenderServer.shared.setRole(role, for: device.id)
        }
    }

    /// Tied to a person: their Edit Anywhere role starts from their Deliver role once (Admin → Admin, else Editor), then is its own.
    private func belong(to person: Deliver.Person) {
        OfficeRenderServer.shared.setPerson(person.id, for: device.id)
        let subject = OfficeAccess.person(person.id)
        if !access.grants.contains(where: { $0.subject == subject && $0.folder == nil }) {
            access.set(subject: subject, folder: nil, role: person.role == "owner" ? .admin : .editor, name: person.name ?? person.email)
        }
    }
}

private struct AskTarget: Identifiable {
    let folder: URL
    var id: String { folder.path }
}

/// Folders → a folder's People: who has another role in it (or a folder inside it) than their own, nearest wins.
struct RemoteFolderPeople: View {
    let folder: URL
    @State private var access = OfficeAccess.shared
    @State private var server = OfficeRenderServer.shared
    @State private var people = DeliverPeople.shared
    @State private var open = false
    /// Where an added role counts: "" the whole folder, else a folder inside it.
    @State private var inside = ""

    private var share: String { OfficeProxies.id(folder) }
    private var base: String { OfficeAccess.folderKey(root: folder, share: share, relative: "") }
    private var listed: [OfficeAccess.Grant] {
        access.grants.filter { grant in
            guard let key = grant.folder, grant.live != nil else { return false }
            return key == base || key.hasPrefix(base + "/")
        }
        .sorted { ($0.folder ?? "", name($0.subject)) < ($1.folder ?? "", name($1.subject)) }
    }
    private var team: [Deliver.Person] { (people.people.people ?? []).filter { $0.role == "editor" || $0.role == "owner" } }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(listed) { grant in line(grant) }
                HStack(spacing: 12) {
                    Menu("Add a Person or Mac") {
                        if !server.pairedMacs.isEmpty {
                            Section("Macs") {
                                ForEach(server.pairedMacs) { device in roles(device.name, subject: device.id.uuidString) }
                            }
                        }
                        if !team.isEmpty {
                            Section("People") {
                                ForEach(team) { person in
                                    roles(person.name ?? person.email ?? person.id, subject: OfficeAccess.person(person.id))
                                }
                            }
                        }
                    }
                    .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
                    Text(inside.isEmpty ? String(localized: "In the whole folder") : String(localized: "In \(inside)"))
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseInside).buttonStyle(.link).font(Design.Studio.hint)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(listed.isEmpty ? String(localized: "People") : String(localized: "People · \(listed.count)"))
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
        .task { if people.people.people == nil { await people.load() } }
    }

    private func roles(_ title: String, subject: String) -> some View {
        Menu(title) {
            ForEach(OfficeAccess.Role.allCases) { role in
                Button(role.title) {
                    access.set(subject: subject, folder: key(inside), role: role,
                               name: subject.hasPrefix("person:") ? title : nil)
                }
            }
        }
    }

    private func line(_ grant: OfficeAccess.Grant) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: name(grant.subject)).font(Design.Studio.body).lineLimit(1)
            if let key = grant.folder, key != base {
                Text(verbatim: String(key.dropFirst(base.count + 1))).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu(grant.live?.title ?? "") {
                ForEach(OfficeAccess.Role.allCases) { role in
                    Button(role.title) { access.set(subject: grant.subject, folder: grant.folder, role: role, name: grant.name) }
                }
            }
            .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
            Button {
                access.set(subject: grant.subject, folder: grant.folder, role: nil, name: grant.name)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).frame(width: 22, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
            .help("Their own role counts here again")
        }
    }

    private func key(_ relative: String) -> String { OfficeAccess.folderKey(root: folder, share: share, relative: relative) }

    /// A paired Mac's name, a person's (or the name kept for one gone from the team).
    private func name(_ subject: String) -> String {
        if let device = server.pairedMacs.first(where: { $0.id.uuidString == subject }) { return device.name }
        let id = String(subject.dropFirst("person:".count))
        if let person = team.first(where: { $0.id == id }) { return person.name ?? person.email ?? id }
        return access.grants.first { $0.subject == subject && $0.name != nil }?.name ?? String(localized: "Someone no longer here")
    }

    private func chooseInside() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "A folder inside “\(folder.lastPathComponent)”.")
        guard panel.runModal() == .OK, let url = panel.url,
              let resolved = try? RemoteEditHost.resolve(String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)), in: folder)
        else { inside = ""; return }
        inside = RemoteEditHost.relative(resolved, in: folder)
    }
}

/// Browse › a folder › People… (an Admin on a home Mac): each paired Mac's role, its role in this folder, and an invitation.
struct RemoteAccessSheet: View {
    let share: String
    let path: String
    let folderName: String
    @Environment(\.dismiss) private var dismiss
    @State private var macs: [[String: Any]] = []
    @State private var here: [String: String] = [:]
    @State private var problem: String?
    @State private var invitation: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People").font(Design.Typography.sheetTitle)
            Text("Who may do what, everywhere and in “\(folderName)”.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            if loading { PlumSpinner() }
            ForEach(macs.indices, id: \.self) { index in
                let mac = macs[index], id = mac["id"] as? String ?? ""
                HStack(spacing: 8) {
                    Text(verbatim: mac["name"] as? String ?? "").font(Design.Studio.body).lineLimit(1)
                    Spacer(minLength: 0)
                    Menu((mac["role"] as? String).flatMap(OfficeAccess.Role.init)?.title ?? String(localized: "Custom")) {
                        ForEach(OfficeAccess.Role.assignable) { role in Button(role.title) { set(id, role: role, here: false) } }
                    }
                    .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
                    .help("Its role everywhere")
                    Menu(here[id].flatMap(OfficeAccess.Role.init).map { String(localized: "Here: \($0.title)") } ?? String(localized: "Here: as everywhere")) {
                        Button("As Everywhere") { set(id, role: nil, here: true) }
                        Divider()
                        ForEach(OfficeAccess.Role.allCases) { role in Button(role.title) { set(id, role: role, here: true) } }
                    }
                    .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
                    .help("Its role in this folder and below")
                }
            }
            if let invitation {
                HStack {
                    Text(verbatim: invitation).font(Design.Studio.hint).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invitation, forType: .string) }
                        .buttonStyle(StudioFlatButtonStyle())
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Design.Studio.warn).font(Design.Studio.body) }
            HStack {
                Button("Invite a Mac") { invite() }.buttonStyle(StudioFlatButtonStyle()).disabled(loading || problem == OfficeAccess.adminRefusal)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let answer = try await OfficeRenderClient.shared.ask("accessList", ["share": share, "path": path])
            macs = answer["macs"] as? [[String: Any]] ?? []
            here = answer["here"] as? [String: String] ?? [:]
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func set(_ mac: String, role: OfficeAccess.Role?, here inFolder: Bool) {
        Task {
            var arguments: [String: Any] = ["mac": mac]
            if let role { arguments["role"] = role.rawValue }
            if inFolder { arguments["share"] = share; arguments["path"] = path }
            do { _ = try await OfficeRenderClient.shared.ask("accessSet", arguments); await load() } catch { problem = error.localizedDescription }
        }
    }

    private func invite() {
        Task {
            do { invitation = try await OfficeRenderClient.shared.ask("accessInvite")["url"] as? String } catch { problem = error.localizedDescription }
        }
    }
}
