import Network
import SwiftUI
import UserNotifications

/// Settings › Review: where the review data lives (§13.1), and per NAS host its version and updates (§13.15),
/// its paired devices and backup (§13.2, §13.3), its quiet time and its host key.
struct DeliverDataHostCard: View {
    @State private var sync = DeliverSync.shared
    @State private var publish = ReviewPublish.shared
    @State private var moving: Deliver.Host?

    var body: some View {
        SettingsCard("Review Data") {
            SettingRow(text: Text("Review data lives on"), detail: sync.footer.map { Text(verbatim: $0) }) {
                Picker(selection: Binding(get: { sync.state.host }, set: { id in
                    if let id, let host = publish.host(id) { moving = host } else if id == nil { sync.stop() }
                })) {
                    Text("This Mac").tag(UUID?.none)
                    ForEach(publish.hosts.filter { $0.kind == .nas && $0.role != "backup" }) { Text(verbatim: $0.name).tag(UUID?.some($0.id)) }
                } label: { EmptyView() }.fixedSize()
            }
            if let banner = sync.dataHost.flatMap(DeliverHostUpdate.banner) {
                Text(verbatim: banner).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).padding(.horizontal, 14).padding(.bottom, 6)
            }
        }
        .confirmationDialog(Text("Keep review data on \(moving?.name ?? "")?"), isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            Button("Move") { if let host = moving { Task { try? await sync.migrate(to: host) } } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Projects stay on this Mac too and work offline.")
        }
    }
}

/// One NAS host: how it's reached, its version, updates, devices, backup and key.
struct DeliverHostSheet: View {
    let host: Deliver.Host
    @Environment(\.dismiss) private var dismiss
    @State private var updates = DeliverHostUpdate.shared
    @State private var devices: [[String: Any]] = []
    @State private var backups: [[String: Any]] = []
    @State private var mainReachable = true
    @State private var uplink: Int?          // this host's measured upload, Mbit/s (nil: not measured)
    @State private var preferFastest = true // the owner's "Prefer fastest even if lighter" (kept on the host)
    @State private var downloadCap: Int?    // Mbit/s for whole-file downloads, 0 = off; nil: a host before 4.0.7
    @State private var backup = false
    @State private var problem: String?
    @State private var quiet = "04:00"
    @State private var action: DeliverHostAction?
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: host.name).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                if let status = ReviewHostTunnel.status(host) { StudioChip(text: Text(verbatim: status)) }
            }
            if let banner = DeliverHostUpdate.banner(host) { Text(verbatim: banner).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
            VStack(alignment: .leading, spacing: 2) {
                if host.selfUpdate == 1 { updatesItself } else { updatedByHand }
            }
            .studioBox()
            Text("Devices").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            VStack(spacing: 0) {
                ForEach(Array(devices.enumerated()), id: \.offset) { _, device in deviceRow(device) }
                if devices.isEmpty { Text("None yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
            }
            .studioBox()
            if host.mail == 1, host.role != "backup" { DeliverMailSection(host: host) }
            if let served = servedBy {
                Text(verbatim: served).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if backups.contains(where: { ($0["replica"] as? [String: Any])?["quality"] as? String != "same" }) {
                SettingSwitch("Prefer fastest even if lighter", isOn: Binding(get: { preferFastest }, set: { on in
                    preferFastest = on
                    Task {
                        // What the host kept; an error or "unknown op" (an older host) turns the switch back.
                        if let kept = (try? await ReviewHostClient.ask(host, ["op": "prefer-fastest", "on": on]))?["preferFastest"] as? Bool {
                            preferFastest = kept
                            problem = nil
                        } else {
                            preferFastest = !on
                            problem = String(localized: "\(host.name) couldn’t change this. Update it, then try again.")
                        }
                    }
                })).studioBox()
            }
            if let cap = downloadCap, host.role != "backup" { downloadLimit(cap) }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                Button("Backup Host…") { backup = true }.buttonStyle(StudioFlatButtonStyle())
                Button("Replace Host Key") { Task { await rotate() } }.buttonStyle(StudioFlatButtonStyle()).disabled(ReviewHostClient.key(host) == nil || !DeliverPeople.isAdmin(host))
                Menu { DeliverHostActions(host: host) { action = $0 } } label: { StudioMenuLabel(title: String(localized: "Server")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
        .background(Design.Studio.panel)
        .task { quiet = DeliverHostUpdate.quietTime(host.id); await load() }
        .sheet(isPresented: $backup) { DeliverBackupSheet(main: host) }
        .deliverHostAction($action) { _ in dismiss() }
    }

    /// The download speed cap (4.0.7): whole-file downloads (masters, proxies) share it; playback never waits for it.
    private func downloadLimit(_ cap: Int) -> some View {
        SettingRow(text: Text("Download speed limit"), detail: Text("Only whole-file downloads. Playback isn’t slowed.")) {
            Picker(selection: Binding(get: { cap }, set: { mbps in
                downloadCap = mbps
                Task {
                    if let kept = (try? await ReviewHostClient.ask(host, ["op": "download-cap", "mbps": mbps]))?["downloadMbps"] as? Int {
                        downloadCap = kept
                        problem = nil
                    } else {
                        downloadCap = cap
                        problem = String(localized: "\(host.name) couldn’t change this. Update it, then try again.")
                    }
                }
            })) {
                Text("Off").tag(0)
                ForEach([50, 100, 250, 500], id: \.self) { Text("\($0) Mbit/s").tag($0) }
                if ![0, 50, 100, 250, 500].contains(cap) { Text("\(cap) Mbit/s").tag(cap) }
            } label: { EmptyView() }.fixedSize().disabled(!DeliverPeople.isAdmin(host))
        }
        .studioBox()
    }

    private var versionText: Text { Text(verbatim: "\(host.version ?? "–") · protocol \(host.protocol.map(String.init) ?? "–")") }
    private var newer: Bool { updates.release.map { DeliverHostUpdate.isUpgrade(from: host.version, to: $0.version) } ?? false }

    /// A host from 4.0.7: it follows this Pluck's version by itself, at a quiet moment.
    @ViewBuilder private var updatesItself: some View {
        let answer = updates.selfStatus[host.id], admin = DeliverPeople.isAdmin(host)
        SettingRow(text: Text("Version"), detail: versionText) {
            Button("Update Now") { Task { await updates.updateItself(host) } }.settingButton()
                .disabled(!admin || !newer || updates.asking.contains(host.id))
        }
        SettingSwitch("Updates by itself", isOn: Binding(get: { answer?["auto"] as? Bool ?? true }, set: { on in Task { await updates.tell(host, ["auto": on]) } }))
            .disabled(!admin)
        if updates.asking.contains(host.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating at the next quiet moment").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 14)
        } else if let state = DeliverHostUpdate.selfState(answer) {
            let checked = DeliverHostUpdate.checked(answer).map { String(localized: "Checked \($0.formatted(.relative(presentation: .named)))") }
            Text(verbatim: ([DeliverHostUpdate.text(state)] + [checked].compactMap { $0 }).joined(separator: " · "))
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 14)
            if case .failed(let error?) = state { Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14) }
            if case .rolledBack(let error?) = state { Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14) }
        }
        if let last = updates.results[host.id], last.result != "ok", let error = last.error {
            Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14)
        }
    }

    /// A host before 4.0.7: one last update by hand (or through a TrueNAS API key already here); then it updates itself.
    @ViewBuilder private var updatedByHand: some View {
        let truenas = TrueNASSetup.isTrueNAS(host), hasKey = TrueNASKeychain.load(TrueNASSetup.nasAddress(host)) != nil
        SettingRow(text: Text("Version"), detail: versionText) {
            Button("Update Now") { Task { await updateNow() } }.settingButton()
                .disabled(!DeliverPeople.isAdmin(host) || updates.release == nil || updates.updating != nil || updates.asking.contains(host.id) || !newer)
        }
        if updates.asking.contains(host.id) || updates.updating == host.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating… this can take a few minutes.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 14)
        } else if newer && (updates.noUpdater.contains(host.id) || (truenas && !hasKey)), let release = updates.release {
            VStack(alignment: .leading, spacing: 6) {
                if truenas {
                    Text("This NAS needs one last update by hand. In TrueNAS: Apps › \(host.role == "backup" ? "pluck-backup" : "pluck-review") › Edit, replace the image with this one, then Save. After that it updates by itself.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(verbatim: release.image).font(Design.Studio.hint.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(release.image, forType: .string) }.settingButton().fixedSize()
                    }
                    Text("Or paste a TrueNAS API key once:").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    HStack(spacing: 6) {
                        SecureField("TrueNAS API key", text: $apiKey).settingField(width: 260)
                        Button("Update") {
                            let key = apiKey
                            apiKey = ""
                            Task { await updates.update(host, to: release, apiKey: key) }
                        }.settingButton().disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Text("This server needs one last update by hand: run its setup command again on the Proxmox host. After that it updates by itself.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        }
        if let last = updates.results[host.id] {
            Text("Last update: \(last.result) · \(last.at.formatted(date: .abbreviated, time: .shortened))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 14)
            if let error = last.error { Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14) }
        }
        if hasKey {
            SettingRow("Update hosts at") {
                TextField("04:00", text: $quiet).settingField(width: 70)
                    .onSubmit { if quiet.wholeMatch(of: #/[0-2]\d:[0-5]\d/#) != nil { UserDefaults.standard.set(quiet, forKey: DeliverHostUpdate.timeKey + host.id.uuidString) } }
            }
        }
    }

    private func deviceRow(_ device: [String: Any]) -> some View {
        let role = device["role"] as? String ?? "mac"
        let seen = (device["lastSeen"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let id = device["id"] as? String ?? ""
        let serving = role == "backup" && (!mainReachable || backups.contains { $0["id"] as? String == id && $0["serving"] as? Bool == true })
        return HStack(spacing: 8) {
            Image(systemName: role == "backup" ? "externaldrive.badge.timemachine" : "laptopcomputer").foregroundStyle(Design.Studio.textQuiet)
            Text(verbatim: device["name"] as? String ?? "").font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
            if role == "backup", let node = device["node"] as? String { Text(verbatim: DeliverBackup.checkCode(node)).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.textQuiet) }
            if serving { StudioChip(text: Text("Serving now"), colour: Design.Studio.good, tinted: true).fixedSize() }
            else if role == "backup" { Text(verbatim: DeliverBackups.text(DeliverBackups.status(device))).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            Spacer()
            if role == "backup", let up = Self.uplink(backups.first { $0["id"] as? String == id }) {
                Text("\(up) Mbit/s up").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize()
            }
            if let seen { Text(seen, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize() }
            if id != host.device && DeliverPeople.isAdmin(host) { Button("Remove") { Task { await remove(id) } }.settingButton().fixedSize() }
        }
        .padding(.horizontal, 12).frame(height: 36)
    }

    private static func uplink(_ backup: [String: Any]?) -> Int? { (backup?["replica"] as? [String: Any])?["uplinkMbps"] as? Int }

    /// Which server clients get, by the Room's rule (rules.ts `pick`): a backup uploading over 1.2 × this host's speed
    /// whose copies are this host's own quality (or any, with Prefer fastest); else this host. nil until something's measured.
    private var servedBy: String? {
        let fast = backups.filter { backup in
            guard let up = Self.uplink(backup), let main = uplink, Double(up) > Double(main) * 1.2 else { return false }
            return (backup["replica"] as? [String: Any])?["quality"] as? String == "same" || preferFastest
        }.max { (Self.uplink($0) ?? 0) < (Self.uplink($1) ?? 0) }
        if let fast, let up = Self.uplink(fast) {
            return String(localized: "Clients are served from \(fast["name"] as? String ?? "") (\(up) Mbit/s up)")
        }
        guard let uplink else { return nil }
        return String(localized: "Clients are served from \(host.name) (\(uplink) Mbit/s up)")
    }

    private func load() async {
        do {
            devices = try await ReviewHostClient.ask(host, ["op": "devices"])["devices"] as? [[String: Any]] ?? []
            let status = try? await ReviewHostClient.ask(host, ["op": "status"])
            backups = status?["backups"] as? [[String: Any]] ?? []
            uplink = status?["uplinkMbps"] as? Int
            preferFastest = status?["preferFastest"] as? Bool ?? true
            downloadCap = status?["downloadMbps"] as? Int
            if host.selfUpdate == 1 { await updates.tell(host) }
            mainReachable = true
        } catch {
            mainReachable = false
        }
    }

    private func remove(_ id: String) async {
        _ = try? await ReviewHostClient.ask(host, ["op": "device-remove", "id": id])
        await load()
    }

    /// A new legacy host key; the old one stops working at once.
    private func rotate() async {
        guard let address = host.address, let answer = try? await ReviewHostClient.ask(host, ["op": "rotate-key"]), let key = answer["key"] as? String else {
            problem = String(localized: "\(host.name) didn’t answer.")
            return
        }
        DeliverKeychain.save(Data(key.utf8), as: address, service: DeliverKeychain.hostService)
    }

    /// A host before 4.0.7. TrueNAS: through its API when a key is here, else the one step by hand; Proxmox: the host
    /// asks its root updater (`update`).
    private func updateNow() async {
        guard let release = updates.release else { return }
        if TrueNASKeychain.load(TrueNASSetup.nasAddress(host)) != nil {
            await updates.update(host, to: release, forced: false)
        } else if TrueNASSetup.isTrueNAS(host) {
            updates.noUpdater.insert(host.id)
        } else {
            await updates.ask(host, to: release)
        }
    }
}

// MARK: - A main server's backups

/// A main server's backups as its `devices` lists them, with what each last reported (`replica`): a backup
/// paired straight with the main (the Proxmox script's `--pair`) has no host record on this Mac.
@MainActor
enum DeliverBackups {
    enum Status { case copying, ready, offline }

    struct Backup: Identifiable {
        var id: String
        var name: String
        var main: Deliver.Host
        var uplink: Int?
        var status: Status
        var lastSeen: Date?
        var replica: [String: Any]
    }

    /// Offline when not seen for 10 min (a backup reports every minute, every 5 at worst); copying while copies
    /// are queued or being made; else ready.
    static func status(_ device: [String: Any], now: Date = .now) -> Status {
        guard let seen = (device["lastSeen"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }), now.timeIntervalSince(seen) < 600 else { return .offline }
        let versions = (device["replica"] as? [String: Any])?["versions"] as? [String: Int] ?? [:]
        return (versions["making"] ?? 0) + (versions["queued"] ?? 0) > 0 ? .copying : .ready
    }

    static func text(_ status: Status) -> String {
        switch status {
        case .copying: String(localized: "Copying")
        case .ready: String(localized: "Ready")
        case .offline: String(localized: "Offline")
        }
    }

    /// The backups in a main's `devices`, leaving out any this Mac also has a host record for (the same iroh node).
    static func backups(_ devices: [[String: Any]], of main: Deliver.Host, hosts: [Deliver.Host], now: Date = .now) -> [Backup] {
        let known = Set(hosts.compactMap(\.node))
        return devices.filter { $0["role"] as? String == "backup" && !known.contains($0["node"] as? String ?? "") }.compactMap { device in
            guard let id = device["id"] as? String else { return nil }
            let replica = device["replica"] as? [String: Any] ?? [:]
            return Backup(id: id, name: device["name"] as? String ?? "", main: main, uplink: replica["uplinkMbps"] as? Int, status: status(device, now: now),
                          lastSeen: (device["lastSeen"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, replica: replica)
        }
    }

    /// Each main server's backups (one `devices` call each; a server that doesn't answer lists none).
    static func load(publish: ReviewPublish = .shared) async -> [Backup] {
        var all: [Backup] = []
        for main in publish.hosts where main.kind == .nas && main.role != "backup" {
            let devices = (try? await ReviewHostClient.ask(main, ["op": "devices"]))?["devices"] as? [[String: Any]] ?? []
            all += backups(devices, of: main, hosts: publish.hosts)
        }
        return all
    }

    static func remove(_ backup: Backup) async {
        _ = try? await ReviewHostClient.ask(backup.main, ["op": "device-remove", "id": backup.id])
    }
}

/// A backup's details: what its main last heard from it.
struct DeliverBackupDetailsSheet: View {
    let backup: DeliverBackups.Backup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let replica = backup.replica, versions = replica["versions"] as? [String: Int] ?? [:]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: backup.name).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                StudioChip(text: Text(verbatim: DeliverBackups.text(backup.status)), colour: backup.status == .offline ? Design.Studio.warn : Design.Studio.textQuiet, tinted: backup.status == .offline)
            }
            VStack(alignment: .leading, spacing: 2) {
                SettingRow("Backup of") { value(backup.main.name) }
                if let up = backup.uplink { SettingRow("Upload") { value(String(localized: "\(up) Mbit/s up")) } }
                if let quality = replica["quality"] as? String { SettingRow("Copies") { value(DeliverBackup.title(quality)) } }
                if let usage = replica["usage"] as? Int64, let max = replica["max"] as? Int64, max > 0 {
                    SettingRow("Space") { value(String(localized: "\(FinderSidebar.size(usage)) of \(FinderSidebar.size(max))")) }
                }
                if !versions.isEmpty {
                    SettingRow("Versions") { value(String(localized: "\(versions["ready"] ?? 0) ready · \((versions["making"] ?? 0) + (versions["queued"] ?? 0)) to copy")) }
                }
                if let failed = (replica["failed"] as? [Any])?.count, failed > 0 { SettingRow("Failed") { value("\(failed)") } }
                if let seen = backup.lastSeen { SettingRow("Last seen") { Text(seen, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) } }
            }
            .studioBox()
            if backup.replica.isEmpty { Text("It hasn’t reported yet.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 420)
        .background(Design.Studio.panel)
    }

    private func value(_ text: String) -> some View { Text(verbatim: text).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
}

// MARK: - Managing a server (Browse's sidebar menu, the Details sheet)

/// What's done to a review server from its menu.
enum DeliverHostAction: Identifiable {
    case folders(Deliver.Host), pair(Deliver.Host), remove(Deliver.Host), invite(Deliver.Host)
    var id: String {
        switch self {
        case .invite(let host): "invite" + host.id.uuidString
        case .folders(let host): "folders" + host.id.uuidString
        case .pair(let host): "pair" + host.id.uuidString
        case .remove(let host): "remove" + host.id.uuidString
        }
    }
}

/// The menu's items: Invite a Teammate… (main servers), Change Folders… (TrueNAS only), Pair Again…, Remove….
struct DeliverHostActions: View {
    let host: Deliver.Host
    let choose: (DeliverHostAction) -> Void

    var body: some View {
        if host.role != "backup" && DeliverPeople.isAdmin(host) {
            Button("Invite a Teammate…") { choose(.invite(host)) }
            Divider()
        }
        if TrueNASSetup.isTrueNAS(host) { Button("Change Folders…") { choose(.folders(host)) } }
        Button("Pair Again…") { choose(.pair(host)) }
        Divider()
        Button("Remove…", role: .destructive) { choose(.remove(host)) }
    }
}

extension View {
    /// Shows the sheet or confirmation an action asks for; `removed` runs once a server is gone.
    func deliverHostAction(_ action: Binding<DeliverHostAction?>, removed: @escaping (UUID) -> Void = { _ in }) -> some View {
        let removing: Deliver.Host? = if case .remove(let host) = action.wrappedValue { host } else { nil }
        return sheet(item: Binding(get: { removing == nil ? action.wrappedValue : nil }, set: { action.wrappedValue = $0 })) { chosen in
            switch chosen {
            case .folders(let host): ReviewTrueNASSetupSheet(editing: host)
            case .pair(let host): DeliverPairAgainSheet(host: host)
            case .invite(let host): DeliverInviteSheet(host: host)
            case .remove: EmptyView()
            }
        }
        .confirmationDialog(Text("Remove \(removing?.name ?? "")?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { action.wrappedValue = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                ReviewPublish.shared.removeHost(removing.id)
                action.wrappedValue = nil
                removed(removing.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pluck forgets this server and its key, and takes what’s published there down. The app on the NAS keeps running.")
        }
    }
}

/// Pair Again: a new pairing line (`pluck-host:<key>@<fingerprint>`) for a server already here, or (TrueNAS with
/// its API key kept) the key read from the installed app. Checked against the server before it says it worked.
struct DeliverPairAgainSheet: View {
    let host: Deliver.Host
    @Environment(\.dismiss) private var dismiss
    @State private var line = ""
    @State private var working = false
    @State private var problem: String?
    @State private var paired = false

    private var canRead: Bool { TrueNASKeychain.load(TrueNASSetup.nasAddress(host)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair Again with \(host.name)").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            Text("Paste the pairing line the server printed in its log. It starts with pluck-host: and holds the server’s key and certificate.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            StudioField(label: "Pairing line") { SecureField("pluck-host:…", text: $line).settingField(width: 300) }
            if canRead {
                StudioField(label: "TrueNAS") {
                    Button("Read the Key from TrueNAS") { Task { await readKey() } }.buttonStyle(StudioFlatButtonStyle()).disabled(working)
                }
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true) }
            if paired { Text("Paired again: \(host.name) accepts this Mac’s key.").font(Design.Studio.hint).foregroundStyle(Design.Studio.good) }
            HStack {
                if working { PlumSpinner() }
                Spacer()
                Button(paired ? "Done" : "Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Pair") { Task { await apply(line) } }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .disabled(working || ReviewHostClient.pairing(line) == nil)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .background(Design.Studio.panel)
    }

    private func readKey() async {
        working = true
        defer { working = false }
        do { await apply(try await TrueNASSetup.readKey(host)) } catch { problem = error.localizedDescription }
    }

    /// Saved, then checked with one connection.
    private func apply(_ pairing: String) async {
        working = true
        defer { working = false }
        problem = await Self.pairAgain(host.id, pairing: pairing)
        paired = problem == nil
    }

    /// nil when the server accepted the new key; else what's wrong, in words.
    static func pairAgain(_ id: UUID, pairing: String, publish: ReviewPublish = .shared) async -> String? {
        guard publish.repair(id, pairing: pairing), let host = publish.host(id) else { return String(localized: "That pairing line isn’t complete.") }
        do {
            try await ReviewHostClient.session(host) { _ in }
            return nil
        } catch is ReviewHostClient.Unconfirmed {
            return String(localized: "Pluck has no confirmed certificate for this server yet: paste its full pairing line, with the fingerprint.")
        } catch {
            return ReviewHostClient.problem(error)
        }
    }
}

/// Invite a Teammate: a one-time link for one teammate's Mac (the helper's `invite`, role "mac", with the role it gets
/// there: Editor unless chosen otherwise), and the Macs already paired with this server (`devices`), each removable
/// (`device-remove`). A server before roles makes every Mac an admin, so it asks no role.
struct DeliverInviteSheet: View {
    let host: Deliver.Host
    @Environment(\.dismiss) private var dismiss
    @State private var invite: (link: String, expires: Date, anywhere: Bool, code: String?)?
    @State private var teammates: [[String: Any]] = []
    @State private var copied = false
    @State private var working = false
    @State private var problem: String?
    @State private var removing: [String: Any]?
    @State private var access = "editor"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StudioTile(symbol: "externaldrive.fill", colour: Design.Studio.textQuiet, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Invite a Teammate").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                    Text(verbatim: host.name).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            Label("Send it to one teammate. It works once; their Pluck joins this server with its own key.", systemImage: "lock.shield")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            if DeliverPeople.roles(host) {
                DeliverRolePicker(options: ["editor", "admin"], selection: $access).studioBox()
                    // The invite made for the other role stops working (one copied as Admin can't pair once it's Editor).
                    .onChange(of: access) { Task { await make(replacing: true) } }
            }
            if let invite {
                HStack(spacing: 8) {
                    Text(verbatim: invite.link).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                        // (Not selectable: selected, the whole link spilled over the buttons. Copy link copies it.)
                        .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading).clipped()
                        .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius))
                    Button { DeliverLinkShare.copy(invite.link); copied = true } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                    if let url = URL(string: invite.link) {
                        ShareLink(item: url, subject: Text("Pluck review server invitation"),
                                  message: Text("Click this link on your Mac to join \(host.name) in Pluck:")) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }.buttonStyle(StudioFlatButtonStyle())
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if invite.expires <= context.date {
                        Text("This invitation has expired. Make another.").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                    } else {
                        Text("Valid until \(invite.expires.formatted(date: .omitted, time: .shortened)) (\(invite.expires, format: .relative(presentation: .named)))")
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
                if !invite.anywhere {
                    Text("Works on the office network only: this server isn’t set up to be reached from anywhere.").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                }
            } else if working {
                PlumSpinner()
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Make Another") { Task { await make() } }.buttonStyle(StudioFlatButtonStyle()).disabled(working)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            // Who is in already, in its own box under the sheet (as the boards' member footer).
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Teammates").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    Text(verbatim: "\(teammates.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    if DeliverPeople.main() != nil {
                        Button(DeliverPeople.title) { StudioNavigator.shared.deliver = .people; dismiss() }.buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
                ForEach(Array(teammates.enumerated()), id: \.offset) { _, device in row(device) }
                if teammates.isEmpty { Text("No teammates yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 12).padding(.bottom, 10) }
            }
            .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
            .padding(.top, 8)
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .background(Design.Studio.panel)
        .task { await make(); await load() }
        .confirmationDialog(Text("Remove \(removing?["name"] as? String ?? "")?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let id = removing?["id"] as? String else { return }
                removing = nil
                Task { await remove(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That Mac can’t reach this server any more. To join again, it needs a new invitation.")
        }
    }

    private func row(_ device: [String: Any]) -> some View {
        let date = { (key: String) in (device[key] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
        let id = device["id"] as? String ?? ""
        return HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").foregroundStyle(Design.Studio.textQuiet)
            Text(verbatim: device["name"] as? String ?? "").font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
            if id == host.device { StudioChip(text: Text("This Mac")) }
            let role = device["access"] as? String == "editor" ? "editor" : "admin"
            StudioChip(text: Text(verbatim: DeliverPeople.roleName(role)), symbol: DeliverPeople.roleSymbol(role))
            Spacer()
            if let seen = date("lastSeen") {
                Text("seen \(seen, format: .relative(presentation: .named))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize()
            }
            if id != host.device && DeliverPeople.isAdmin(host) { Button("Remove…") { removing = device }.settingButton().fixedSize() }
        }
        .padding(.horizontal, 12).frame(height: 36)
    }

    /// A new one-time invitation (the last one stays valid until it's used or runs out, unless `replacing`: a role switch).
    func make(replacing: Bool = false) async {
        working = true
        defer { working = false }
        do {
            var op: [String: Any] = ["op": "invite", "role": "mac"]
            if DeliverPeople.roles(host) { op["access"] = access }
            if replacing, let old = invite?.code { op["replaces"] = old }
            let answer = try await ReviewHostClient.ask(host, op)
            guard let link = answer["link"] as? String else { throw Deliver.Failure("internal") }
            let expires = (answer["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now.addingTimeInterval(900)
            var anywhere = false
            if case .reviewHost(let node, _, _, _, _, _) = PrivateNetwork.Invitation(link: link)?.way { anywhere = !node.isEmpty }
            invite = (link, expires, anywhere, answer["code"] as? String)
            copied = false
            problem = nil
        } catch {
            problem = (error as? Deliver.Failure)?.code == "limit" ? String(localized: "Too many wrong codes were tried. Invitations are paused for 15 minutes.")
                : ReviewHostClient.problem(error)
        }
    }

    /// The teammates' Macs (backups are managed in the server's details).
    func load() async {
        guard let answer = try? await ReviewHostClient.ask(host, ["op": "devices"]) else { return }
        teammates = (answer["devices"] as? [[String: Any]] ?? []).filter { ($0["role"] as? String ?? "mac") == "mac" }
    }

    private func remove(_ id: String) async {
        do { _ = try await ReviewHostClient.ask(host, ["op": "device-remove", "id": id]) } catch { problem = ReviewHostClient.problem(error) }
        await load()
    }
}

// MARK: - A NAS that stops answering (4.0.7)

/// Every minute this Mac asks each paired NAS for its status. One that hasn't answered for 10 minutes (while this Mac
/// itself is online) warns the team once: a notification here and a post to the projects' webhooks (an admin Mac's
/// only, so a team of Macs doesn't post it several times over); its first answer after that says it's back.
@MainActor
final class DeliverHostWatch {
    static let shared = DeliverHostWatch()
    static let after: TimeInterval = 600

    private(set) var since: [UUID: Date] = [:]
    private(set) var warned: Set<UUID> = []
    /// Tests stand in for these: the host's answer, this Mac's own network, what the team is told.
    /// (Only no connection counts as down: a refused key, an unconfirmed certificate or a captive portal's page means
    /// something answered, and isn't an outage to tell the team about.)
    var probe: (Deliver.Host) async -> Bool = { host in
        do { _ = try await ReviewHostClient.ask(host, ["op": "status"]); return true } catch { return !DeliverHostWatch.unreachable(error) }
    }
    nonisolated static func unreachable(_ error: Error) -> Bool {
        if error is NWError || error is POSIXError || error is URLError { return true }
        // internal: a connect or answer timed out (HostSession); closed: cut before TLS; offline: the tunnel isn't up.
        return ["internal", "closed", "offline", "unreachable"].contains((error as? Deliver.Failure)?.code ?? "")
    }
    var online: () -> Bool = { DeliverHostWatch.path.currentPath.status == .satisfied }
    var tell: (Deliver.Host, _ back: Bool, _ since: Date) -> Void = { DeliverHostWatch.warn($0, back: $1, since: $2) }
    private static let path: NWPathMonitor = { let m = NWPathMonitor(); m.start(queue: .global(qos: .utility)); return m }()
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.check(ReviewPublish.shared.hosts)
            }
        }
    }

    func check(_ hosts: [Deliver.Host], now: Date = .now) async {
        // This Mac offline: nothing can be said of the NAS (and the clock starts again once it's back).
        guard online() else { since = [:]; return }
        for host in hosts where host.kind == .nas {
            if await probe(host) {
                since[host.id] = nil
                await keepHooks(host, now: now)
                if warned.remove(host.id) != nil { tell(host, true, now) }
            } else {
                let first = since[host.id] ?? now
                since[host.id] = first
                if now.timeIntervalSince(first) >= Self.after, warned.insert(host.id).inserted { tell(host, false, first) }
            }
        }
    }

    /// The projects' webhook addresses, kept while the NAS answers (an admin Mac's, every 30 min): it can't be asked
    /// for them once it's down.
    private var hooksAsked: [UUID: Date] = [:]
    private func keepHooks(_ host: Deliver.Host, now: Date) async {
        guard ScreenshotMode.scene == nil, host.mail == 1, host.role != "backup", DeliverPeople.isAdmin(host),
              hooksAsked[host.id].map({ now.timeIntervalSince($0) > 1800 }) ?? true else { return }
        hooksAsked[host.id] = now
        guard let hooks = (try? await ReviewHostClient.ask(host, ["op": "mail-state"]))?["hooks"] as? [String: [String: Any]] else { return }
        UserDefaults.standard.set(Array(Set(hooks.values.compactMap { $0["url"] as? String })).sorted(), forKey: Self.hooksKey + host.id.uuidString)
        // Which admin Mac posts when it's down (one, not each): kept now, as it can't be asked then.
        if let devices = (try? await ReviewHostClient.ask(host, ["op": "devices"]))?["devices"] as? [[String: Any]], let poster = Self.poster(devices, now: now) {
            UserDefaults.standard.set(poster, forKey: Self.posterKey + host.id.uuidString)
        }
    }
    static let hooksKey = "reviewHostHooks.", posterKey = "reviewHostPoster."

    /// The admin Mac that posts the webhook: the lowest device id among admin Macs seen in the last day (all admin Macs
    /// when none was). Every Mac's own notification still shows.
    nonisolated static func poster(_ devices: [[String: Any]], now: Date) -> String? {
        let admins = devices.filter { $0["role"] as? String == "mac" && ($0["access"] as? String ?? "admin") == "admin" }
        let recent = admins.filter { ($0["lastSeen"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }.map { now.timeIntervalSince($0) < 86400 } == true }
        return (recent.isEmpty ? admins : recent).compactMap { $0["id"] as? String }.min()
    }

    static func warn(_ host: Deliver.Host, back: Bool, since: Date) {
        guard ScreenshotMode.scene == nil else { return }
        let title = back ? String(localized: "\(host.name) is back") : String(localized: "\(host.name) isn’t answering")
        let body = back ? String(localized: "Clients can open their links again.")
            : String(localized: "Since \(since.formatted(date: .omitted, time: .shortened)). Clients see “Temporarily offline” until it’s back.")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-host-" + host.id.uuidString, content: content, trigger: nil))
        guard DeliverPeople.isAdmin(host) else { return }
        if let poster = UserDefaults.standard.string(forKey: posterKey + host.id.uuidString), let me = host.device, poster != me { return }
        // `text` first, as the host's own webhook posts (a Slack incoming webhook shows it). No signature: the secret stays on the NAS.
        let event: [String: Any] = ["text": "\(title). \(body)", "event": back ? "host-online" : "host-offline", "host": host.name,
                                    "since": DeliverServer.date(since)]
        let kept = UserDefaults.standard.stringArray(forKey: hooksKey + host.id.uuidString) ?? []
        for url in Set(kept + DeliverMail.shared.hooks.values).compactMap(URL.init(string:)) where url.scheme == "https" {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: event)
            URLSession.shared.dataTask(with: request).resume()
        }
    }
}
