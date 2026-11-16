import SwiftUI

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
    @State private var preferFastest = false // the owner's "Prefer fastest even if lighter" (kept on the host)
    @State private var invite: (link: String, expires: Date)?
    @State private var backup = false
    @State private var problem: String?
    @State private var quiet = "04:00"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: host.name).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                if let status = ReviewHostTunnel.status(host) { StudioChip(text: Text(verbatim: status)) }
            }
            if let banner = DeliverHostUpdate.banner(host) { Text(verbatim: banner).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
            VStack(alignment: .leading, spacing: 2) {
                SettingRow(text: Text("Version"), detail: Text(verbatim: "\(host.version ?? "–") · protocol \(host.protocol.map(String.init) ?? "–")")) {
                    Button("Update Now") { Task { await updateNow() } }.settingButton()
                        .disabled(updates.release == nil || updates.updating != nil || host.version == updates.release?.version)
                }
                if let last = updates.results[host.id] {
                    Text("Last update: \(last.result) · \(last.at.formatted(date: .abbreviated, time: .shortened))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 14)
                    if let error = last.error { Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14) }
                }
                SettingRow("Update hosts at") {
                    TextField("04:00", text: $quiet).settingField(width: 70)
                        .onSubmit { if quiet.wholeMatch(of: #/[0-2]\d:[0-5]\d/#) != nil { UserDefaults.standard.set(quiet, forKey: DeliverHostUpdate.timeKey + host.id.uuidString) } }
                }
            }
            .studioBox()
            Text("Devices").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            VStack(spacing: 0) {
                ForEach(Array(devices.enumerated()), id: \.offset) { _, device in deviceRow(device) }
                if devices.isEmpty { Text("None yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
            }
            .studioBox()
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
            if let invite {
                Text("Anyone with this link in the next 15 minutes can browse your NAS media").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                HStack {
                    Text(verbatim: invite.link).font(Design.Studio.hint.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Copy") { DeliverLinkShare.copy(invite.link) }.settingButton()
                }
                Text("Until \(invite.expires.formatted(date: .omitted, time: .shortened))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                Button("Pair a Mac…") { Task { await makeInvite() } }.buttonStyle(StudioFlatButtonStyle())
                Button("Backup Host…") { backup = true }.buttonStyle(StudioFlatButtonStyle())
                Button("Replace Host Key") { Task { await rotate() } }.buttonStyle(StudioFlatButtonStyle()).disabled(ReviewHostClient.key(host) == nil)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
        .background(Design.Studio.panel)
        .task { quiet = DeliverHostUpdate.quietTime(host.id); await load() }
        .sheet(isPresented: $backup) { DeliverBackupSheet(main: host) }
    }

    private func deviceRow(_ device: [String: Any]) -> some View {
        let role = device["role"] as? String ?? "mac"
        let seen = (device["lastSeen"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let id = device["id"] as? String ?? ""
        let serving = role == "backup" && (!mainReachable || backups.contains { $0["id"] as? String == id && $0["serving"] as? Bool == true })
        return HStack(spacing: 8) {
            Image(systemName: role == "backup" ? "externaldrive.badge.timemachine" : "laptopcomputer").foregroundStyle(Design.Studio.textQuiet)
            Text(verbatim: device["name"] as? String ?? "").font(Design.Studio.body)
            if role == "backup", let node = device["node"] as? String { Text(verbatim: DeliverBackup.checkCode(node)).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.textQuiet) }
            if serving { StudioChip(text: Text("Serving now"), colour: Design.Studio.good, tinted: true) }
            Spacer()
            if role == "backup", let up = Self.uplink(backups.first { $0["id"] as? String == id }) {
                Text("\(up) Mbit/s up").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if let seen { Text(seen, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            if id != host.device { Button("Remove") { Task { await remove(id) } }.settingButton() }
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
            preferFastest = status?["preferFastest"] as? Bool ?? false
            mainReachable = true
        } catch {
            mainReachable = false
        }
    }

    private func makeInvite() async {
        do {
            let answer = try await ReviewHostClient.ask(host, ["op": "invite", "role": "mac"])
            guard let link = answer["link"] as? String else { throw Deliver.Failure("internal") }
            invite = (link, (answer["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now.addingTimeInterval(900))
        } catch { problem = String(localized: "\(host.name) didn’t answer.") }
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

    /// TrueNAS: through its API (DeliverHostUpdate); Proxmox: the host asks its own updater (`update`).
    private func updateNow() async {
        guard let release = updates.release else { return }
        if TrueNASKeychain.load(host.address?.split(separator: ":").first.map(String.init) ?? "") != nil {
            await updates.update(host, to: release, forced: false)
        } else {
            _ = try? await ReviewHostClient.ask(host, ["op": "update", "version": release.version])
        }
    }
}
