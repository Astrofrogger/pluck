import SwiftUI

/// "Set up a NAS host › TrueNAS (automatic)" (§13.13): Pluck makes the datasets, installs the app from R2's compose
/// template with its image pinned by digest, waits for it to run, and pairs. ReviewNASGuide stays as the manual path.
@MainActor
@Observable
final class TrueNASSetup {
    enum Role: String { case main, backup }

    var address = ""
    var apiKey = ""
    var pool = ""
    var data = ""
    var media: [(dataset: String, id: String)] = []
    var secondAddress = ""
    var secondPath = ""
    var uploads = ""
    var role = Role.main
    var backupMax = 50
    var quality = "1080-low"
    var cpus = 2
    var memory = 3
    var iroh = true
    var mainLink = ""
    var name = "NAS"

    private(set) var pools: [String] = []
    private(set) var datasets: [String] = []
    private(set) var step: String?
    private(set) var problem: String?
    private(set) var warnings: [String] = []
    private(set) var connected = false
    private(set) var done: Deliver.Host?
    /// A first connect's certificate, waiting for the owner to confirm it.
    var fingerprint: String?
    @ObservationIgnored private var client: TrueNASClient?

    var image: String? { DeliverHostUpdate.shared.release?.image }
    var syncAddress: String { "\(address):8790" }

    /// Connects (pinned, wss only), logs in with the key, checks the version and the key's roles, reads the pickers.
    func connect() async {
        problem = nil
        let client = TrueNASClient(address: address, pin: TrueNASKeychain.pin(address))
        client.appName = role == .main ? "pluck-review" : "pluck-backup"
        self.client = client
        do {
            step = String(localized: "Connecting…")
            try await client.connect()
            try await client.login(apiKey)
            _ = try await client.checkVersion()
            let missing = try await client.missingRoles()
            guard missing.isEmpty else { throw TrueNASClient.Failure(message: String(localized: "The API key’s user needs these roles: \(missing.joined(separator: ", "))")) }
            pools = try await client.pools()
            datasets = try await client.datasets()
            if pool.isEmpty { pool = pools.first ?? "" }
            if data.isEmpty { data = "\(pool)/apps/\(client.appName)" }
            connected = true
            step = nil
        } catch let unconfirmed as TrueNASClient.Unconfirmed {
            fingerprint = unconfirmed.fingerprint
            step = nil
        } catch {
            problem = error.localizedDescription
            step = nil
        }
    }

    /// The fingerprint matched what TrueNAS shows (System › Certificates): pinned for this address.
    func confirm() async {
        guard let fingerprint else { return }
        TrueNASKeychain.setPin(fingerprint, for: address)
        self.fingerprint = nil
        await connect()
    }

    /// The template's values (R2's names) and which optional blocks stay.
    func values(hostKey: String) -> (values: [String: String], blocks: Set<String>) {
        let relay = DeliverRelay.shared.environment
        // No media (always on a backup): no media mount at all, never the data dataset (its host key, its manifest).
        let first = media.first ?? (dataset: "", id: "nas1")
        var values: [String: String] = [
            "image": image ?? "", "host_key": hostKey, "host_name": name, "iroh": iroh ? "1" : "0", "role": role.rawValue,
            "main_link": role == .backup ? mainLink : "", "backup_max": role == .backup ? "\(backupMax)G" : "", "backup_quality": role == .backup ? quality : "",
            "relay_token": relay["PLUCK_RELAY_TOKEN"] ?? "", "turn_secret": relay["PLUCK_TURN_SECRET"] ?? "", "turn_urls": relay["PLUCK_TURN_URLS"] ?? "",
            "update_time": "04:00", "media1_id": first.id, "media1": "/mnt/\(first.dataset)", "lan_addr": address,
            // (A backup next to a main on the same NAS: its own ports.)
            "sync_port": role == .main ? "8790" : "8792", "admin_port": role == .main ? "8791" : "8793",
            "data": "/mnt/\(data)", "mem": "\(memory)g", "cpus": "\(cpus).0",
        ]
        var blocks: Set<String> = []
        if role == .main, !media.isEmpty { blocks.insert("media1") }
        if !secondAddress.isEmpty, !secondPath.isEmpty {
            blocks.insert("media2")
            values["media2_id"] = media.count > 1 ? media[1].id : "nas2"
            values["media2_nfs_addr"] = secondAddress
            values["media2_nfs_path"] = secondPath
        }
        if !uploads.isEmpty {
            blocks.insert("uploads")
            values["uploads"] = "/mnt/\(uploads)"
            values["uploads_id"] = "renders"
        }
        return (values, blocks)
    }

    /// Datasets, permissions on the app's own ones, the app, then pairing.
    func install() async {
        guard let client, let template = TrueNASClient.template else {
            problem = String(localized: "This build of Pluck doesn’t have the TrueNAS template.")
            return
        }
        guard image != nil else {
            problem = String(localized: "No signed host release for this version of Pluck yet.")
            return
        }
        problem = nil
        do {
            step = String(localized: "Making datasets…")
            try await client.ensureDataset(data)
            try await client.own(data)
            if !uploads.isEmpty { try await client.ensureDataset(uploads); try await client.own(uploads) }
            warnings = []
            for item in media where !(try await client.readable(item.dataset)) {
                warnings.append(String(localized: "The app (user 568) can’t read \(item.dataset)."))
            }
            step = String(localized: "Installing the app…")
            let key = DeliverKeys.base64url(DeliverKeys.random(32))
            let (values, blocks) = values(hostKey: key)
            let compose = try TrueNASClient.render(template, values, blocks: blocks)
            try await client.deploy(compose)
            step = String(localized: "Waiting for it to start…")
            try await client.waitRunning()
            step = String(localized: "Pairing…")
            if role == .main {
                guard let host = ReviewPublish.shared.addNAS(name: name, address: syncAddress, pairing: key) else { throw TrueNASClient.Failure(message: "pairing") }
                save(compose, host: host.id)
                done = host
            }
            step = nil
        } catch {
            problem = error.localizedDescription
            step = nil
        }
    }

    /// The compose kept for updates and rollback (§13.15 a).
    func save(_ compose: String, host: UUID) {
        let folder = DeliverStore.shared.root.appendingPathComponent("hosts/\(host.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? compose.write(to: folder.appendingPathComponent("compose.yml"), atomically: true, encoding: .utf8)
    }

    func keepKey(_ keep: Bool) {
        if keep { TrueNASKeychain.save(apiKey, for: address) } else { TrueNASKeychain.forget(address) }
        apiKey = ""
        client?.close()
    }
}

struct ReviewTrueNASSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var setup = TrueNASSetup()
    @State private var askKeep = false
    @State private var unconfirmed: (host: UUID, fingerprint: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setup.role == .main ? LocalizedStringKey("TrueNAS (automatic)") : "TrueNAS Backup").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    StudioField(label: "NAS") { TextField("192.0.2.10", text: $setup.address).settingField(width: 220) }
                    StudioField(label: "API key") { SecureField("A key for the user pluck, never root’s", text: $setup.apiKey).settingField(width: 280) }
                    Text("TrueNAS › Credentials › Users: add a user “pluck” with \(TrueNASClient.roles.joined(separator: ", ")), then make an API key for it.")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true).padding(.leading, 120)
                    if let fingerprint = setup.fingerprint {
                        Text(verbatim: fingerprint).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.text).textSelection(.enabled)
                        Button("Matches TrueNAS") { Task { await setup.confirm() } }.buttonStyle(StudioFlatButtonStyle())
                    }
                    if setup.connected { choices }
                    ForEach(setup.warnings, id: \.self) { Text(verbatim: $0).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
                }
            }
            if let step = setup.step { HStack { PlumSpinner(); Text(verbatim: step).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) } }
            if let problem = setup.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            if askKeep {
                Text("Keep the API key for automatic updates?").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                HStack {
                    Spacer()
                    Button("Forget") { setup.keepKey(false); dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Keep (Recommended)") { setup.keepKey(true); dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    if setup.connected {
                        Button("Install") { Task { await setup.install(); if setup.problem == nil { await pin() } } }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(setup.step != nil)
                    } else {
                        Button("Connect") { Task { await setup.connect() } }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                            .disabled(setup.address.isEmpty || setup.apiKey.isEmpty || setup.step != nil)
                    }
                }
            }
            if let unconfirmed {
                Text(verbatim: unconfirmed.fingerprint).font(Design.Studio.hint.monospaced()).textSelection(.enabled)
                Button("Matches the Log") {
                    ReviewPublish.shared.pinned(unconfirmed.fingerprint, host: unconfirmed.host)
                    self.unconfirmed = nil
                    Task { await pin() }
                }.buttonStyle(StudioFlatButtonStyle())
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560, height: 600)
        .background(Design.Studio.panel)
    }

    @ViewBuilder private var choices: some View {
        StudioField(label: "Pool") {
            Picker(selection: $setup.pool) { ForEach(setup.pools, id: \.self) { Text(verbatim: $0).tag($0) } } label: { EmptyView() }.fixedSize()
        }
        StudioField(label: "Data") { TextField("tank/apps/pluck-review", text: $setup.data).settingField(width: 280) }
        // The role comes from Set Up Server (a backup's invite is made first); a backup keeps copies, not media.
        if setup.role == .main { mainChoices } else { DeliverBackupFields(maxStorage: $setup.backupMax, quality: $setup.quality) }
        StudioField(label: "Limits") {
            Stepper("\(setup.cpus) CPUs", value: $setup.cpus, in: 1...8).fixedSize()
            Stepper("\(setup.memory) GB", value: $setup.memory, in: 2...16).fixedSize()
        }
        StudioSwitchRow(title: "Reach it from anywhere (iroh)", isOn: $setup.iroh)
    }

    @ViewBuilder private var mainChoices: some View {
        StudioField(label: "Media") {
            Menu {
                ForEach(setup.datasets.filter { d in !setup.media.contains { $0.dataset == d } }, id: \.self) { dataset in
                    Button(dataset) { setup.media.append((dataset, "nas\(setup.media.count + 1)")) }
                }
            } label: { StudioMenuLabel(title: setup.media.isEmpty ? String(localized: "Add") : setup.media.map(\.dataset).joined(separator: ", ")) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if !setup.media.isEmpty { Button("Clear") { setup.media = [] }.settingButton() }
        }
        StudioField(label: "Second NAS") {
            TextField("192.0.2.20", text: $setup.secondAddress).settingField(width: 120)
            TextField("/mnt/tank/media", text: $setup.secondPath).settingField(width: 150)
        }
        StudioField(label: "Uploads") { TextField("Optional: tank/renders", text: $setup.uploads).settingField(width: 280) }
    }

    /// The first sync connect on the LAN pins the certificate (confirmed by the owner), then this Mac's node is registered.
    private func pin() async {
        guard let host = setup.done.flatMap({ ReviewPublish.shared.host($0.id) }) else { askKeep = true; return }
        do {
            let node = try? await ReviewHostTunnel.nodeID(host)
            try await ReviewHostClient.session(host) { session in
                if let node { _ = try await session.ask(["op": "device-node", "node": node]) }
            }
            askKeep = true
        } catch let error as ReviewHostClient.Unconfirmed where !error.fingerprint.isEmpty {
            unconfirmed = (host.id, error.fingerprint)
        } catch {
            askKeep = true
        }
    }
}
