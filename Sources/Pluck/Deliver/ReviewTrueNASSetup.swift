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
    /// Ask for Files links may put files straight into the first media dataset (the helper's `--drop`, block drop1).
    /// Change Folders reads it back from the installed app (TrueNASClient.Installed.drop).
    var dropFiles = false
    var role = Role.main
    var backupMax = 50
    var quality = "1080-low"
    var cpus = 2
    var memory = 3
    var iroh = true
    var mainLink = ""
    var name = "NAS"
    /// The second NAS's media id as installed (Change Folders keeps it: links refer to it).
    var secondIDKept: String?
    /// Change Folders: the server being changed (its record, key and pin stay; only the app's settings change).
    private(set) var editing: Deliver.Host?

    private(set) var pools: [String] = []
    private(set) var datasets: [String] = []
    private(set) var step: String?
    private(set) var problem: String?
    /// Per media dataset: whether the app (uid 568) can read it and what's inside (nil: not checked yet).
    private(set) var access: [String: Bool] = [:]
    private(set) var checkingAccess = false
    private(set) var connected = false
    var done: Deliver.Host?
    /// A first connect's certificate, waiting for the owner to confirm it.
    var fingerprint: String?
    @ObservationIgnored private var client: TrueNASClient?
    @ObservationIgnored var publish = ReviewPublish.shared
    /// After Install: the server's certificate as it answered, waiting for the owner to compare it with the app's log.
    var serverFingerprint: String?
    /// Fingerprints the owner confirmed in this sheet: one never comes back as a question.
    @ObservationIgnored private var confirmedPins: Set<String> = []

    init() {}

    /// Change Folders for a server set up here: the API key from the Keychain when it was kept (else it's asked).
    init(editing host: Deliver.Host) {
        editing = host
        address = Self.nasAddress(host)
        apiKey = TrueNASKeychain.load(address) ?? ""
        role = host.role == "backup" ? .backup : .main
        name = host.name
    }

    /// The NAS's own address (its sync address without the port).
    static func nasAddress(_ host: Deliver.Host) -> String {
        let address = host.address ?? ""
        return address.split(separator: ":").count == 2 ? String(address.split(separator: ":")[0]) : address
    }

    /// A server Pluck set up through TrueNAS's API (its compose kept here, its API key kept, or its NAS certificate pinned).
    static func isTrueNAS(_ host: Deliver.Host) -> Bool {
        let address = nasAddress(host)
        let compose = DeliverStore.shared.root.appendingPathComponent("hosts/\(host.id.uuidString)/compose.yml")
        return host.kind == .nas && (TrueNASKeychain.load(address) != nil || TrueNASKeychain.pin(address) != nil || FileManager.default.fileExists(atPath: compose.path))
    }

    /// Tests: the image the stand-in TrueNAS "runs" (no signed host release in a test copy).
    static var testImage: String?
    var image: String? { Self.testImage ?? DeliverHostUpdate.shared.release?.image }
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
            if editing != nil { try await prefill(client) }
            if pool.isEmpty { pool = data.split(separator: "/").first.map(String.init) ?? pools.first ?? "" }
            if data.isEmpty { data = "\(pool)/apps/\(client.appName)" }
            connected = true
            step = nil
            await checkAccess()
        } catch let unconfirmed as TrueNASClient.Unconfirmed {
            fingerprint = unconfirmed.fingerprint
            step = nil
        } catch {
            problem = error.localizedDescription
            step = nil
        }
    }

    /// Change Folders: the form filled in from what's installed (`app.config`).
    private func prefill(_ client: TrueNASClient) async throws {
        guard try await client.app() != nil else { throw TrueNASClient.Failure(message: String(localized: "\(client.appName) isn’t installed on this NAS.")) }
        let config: Any
        do { config = try await client.config() } catch { throw Self.unreadable(client.appName, error.localizedDescription) }
        guard let found = TrueNASClient.installed(config) else { throw Self.unreadable(client.appName, "PLUCK_HOST_KEY") }
        data = found.data ?? data
        media = zip(found.media, found.mediaIDs).map { (dataset: $0, id: $1) }
        secondIDKept = found.secondID
        uploads = found.uploads ?? ""
        dropFiles = found.drop
        secondAddress = found.secondAddress ?? ""
        secondPath = found.secondPath ?? ""
        cpus = found.cpus.map { min(max($0, 1), 8) } ?? cpus
        memory = found.memory.map { min(max($0, 2), 16) } ?? memory
        iroh = found.iroh ?? iroh
        mainLink = found.mainLink ?? mainLink
        backupMax = found.backupMax ?? backupMax
        quality = found.quality ?? quality
        name = found.name ?? name
        if let editing { publish.update(host: editing.id) { $0.rootNames = Self.names(found) } }
    }

    /// The roots' names as installed ("nas1" → its dataset's last part), for Browse.
    static func names(_ found: TrueNASClient.Installed) -> [String: String] {
        var roots = zip(found.mediaIDs, found.media).map { (id: $0, path: $1) }
        if let id = found.secondID, let path = found.secondPath { roots.append((id, path)) }
        if let path = found.uploads { roots.append((found.uploadsID ?? "renders", path)) }
        return Deliver.Host.names(roots)
    }

    /// The uploads dataset is a media one, inside one or holds one: written files would show in a read-only root (or the other way).
    var uploadsOverlap: Bool {
        !uploads.isEmpty && media.contains { $0.dataset == uploads || uploads.hasPrefix($0.dataset + "/") || $0.dataset.hasPrefix(uploads + "/") }
    }

    /// The names as this form will install them.
    var rootNames: [String: String] {
        var roots = media.map { (id: $0.id, path: $0.dataset) }
        if !secondAddress.isEmpty, !secondPath.isEmpty { roots.append((secondID, secondPath)) }
        if !uploads.isEmpty { roots.append(("renders", uploads)) }
        return Deliver.Host.names(roots)
    }

    /// A server installed before names were kept: read back from app.config once, when its API key was kept.
    static func readNames(_ host: Deliver.Host, publish: ReviewPublish = .shared) async {
        let address = nasAddress(host)
        guard host.kind == .nas, host.rootNames == nil, let apiKey = TrueNASKeychain.load(address), let pin = TrueNASKeychain.pin(address) else { return }
        let client = TrueNASClient(address: address, pin: pin)
        client.appName = host.role == "backup" ? "pluck-backup" : "pluck-review"
        defer { client.close() }
        guard (try? await client.connect()) != nil, (try? await client.login(apiKey)) != nil,
              let config = try? await client.config(), let found = TrueNASClient.installed(config) else { return }
        publish.update(host: host.id) { $0.rootNames = names(found) }
    }

    static func unreadable(_ app: String, _ reason: String) -> TrueNASClient.Failure {
        TrueNASClient.Failure(message: String(localized: "\(app) is already on the NAS, but Pluck can’t read its host key (\(reason)). Nothing was changed. Remove the app in TrueNAS › Apps, then install again."))
    }

    /// The host key of the app already installed (nil: none installed). Never a new key over a running app's:
    /// it would keep its own and refuse this Mac's.
    static func existingKey(_ client: TrueNASClient) async throws -> String? {
        guard try await client.app() != nil else { return nil }
        let config: Any
        do { config = try await client.config() } catch { throw unreadable(client.appName, error.localizedDescription) }
        guard let key = TrueNASClient.installed(config)?.key else { throw unreadable(client.appName, "PLUCK_HOST_KEY") }
        return key
    }

    /// Pair Again › Read the Key from TrueNAS: the installed app's key, with the API key kept in the Keychain.
    static func readKey(_ host: Deliver.Host) async throws -> String {
        let address = nasAddress(host)
        guard let apiKey = TrueNASKeychain.load(address) else { throw TrueNASClient.Failure(message: String(localized: "Pluck didn’t keep an API key for this NAS.")) }
        let client = TrueNASClient(address: address, pin: TrueNASKeychain.pin(address))
        client.appName = host.role == "backup" ? "pluck-backup" : "pluck-review"
        defer { client.close() }
        do { try await client.connect() } catch is TrueNASClient.Unconfirmed {
            throw TrueNASClient.Failure(message: String(localized: "The NAS’s certificate isn’t confirmed yet: use Change Folders… first."))
        }
        try await client.login(apiKey)
        guard let key = try await existingKey(client) else { throw TrueNASClient.Failure(message: String(localized: "\(client.appName) isn’t installed on this NAS.")) }
        return key
    }

    /// After installing: this Mac's key really opens the server's sync port, as Browse uses it. Retried while the
    /// helper starts (60 s at most); a refused key or another certificate isn't retried. Returns the certificate to
    /// confirm on a first connect; `problem` says what went wrong.
    func verify(_ host: Deliver.Host, timeout: TimeInterval = 60, poll: Duration = .seconds(3)) async -> String? {
        step = String(localized: "Checking that it answers…")
        problem = nil
        defer { step = nil }
        let end = Date.now.addingTimeInterval(timeout)
        while true {
            do {
                try await ReviewHostClient.session(host) { _ in }
                verified = true
                return nil
            } catch let unconfirmed as ReviewHostClient.Unconfirmed where !unconfirmed.fingerprint.isEmpty {
                return unconfirmed.fingerprint
            } catch {
                let code = (error as? Deliver.Failure)?.code
                if code == "auth" || code == "pin" || code == "incompatible" || Date.now >= end {
                    problem = code == "auth" ? String(localized: "The NAS server rejected Pluck’s key. Choose Install again to read the key it runs with, or Pair Again.")
                        : ReviewHostClient.problem(error)
                    return nil
                }
            }
            try? await Task.sleep(for: poll)
        }
    }

    private(set) var verified = false

    var appName: String { role == .main ? "pluck-review" : "pluck-backup" }

    /// The installed server, by id, else by its address (the record is what's pinned, never a stale copy).
    private var installed: Deliver.Host? {
        guard let done else { return nil }
        return publish.host(done.id) ?? publish.hosts.first { $0.kind == .nas && $0.address == done.address }
    }

    /// After Install: checks the server; a first connect asks the owner for its fingerprint (`serverFingerprint`).
    func check() async {
        guard let host = installed else { problem = String(localized: "Pluck can’t find this server in its list any more. Install again."); return }
        serverFingerprint = nil
        guard let seen = await verify(host) else { return }
        if let normal = HostSession.normalized(seen), confirmedPins.contains(normal) {
            problem = String(localized: "The fingerprint was confirmed, but Pluck still can’t use it for this server. Close this, then choose Pair Again on the server in Browse.")
            return
        }
        // Installed through the API just now: the app's own log says which certificate it made. The same one answering
        // here is pinned without asking; anything else (no log, another one) goes to the owner.
        if let client, done?.id != nil {
            client.appName = appName
            step = String(localized: "Reading the server’s fingerprint from TrueNAS…")
            let logged = await client.logFingerprint()
            self.client = nil
            step = nil
            if let logged, HostSession.normalized(logged) == HostSession.normalized(seen) {
                serverFingerprint = seen
                await confirmServer()
                return
            }
        }
        serverFingerprint = seen
    }

    /// "Matches": kept as this server's pin (one from an earlier attempt gives way), then checked again.
    func confirmServer() async {
        guard let seen = serverFingerprint, let done else { return }
        if let why = publish.pinned(seen, host: done.id, address: done.address, replace: true) {
            problem = why
            return
        }
        if let normal = HostSession.normalized(seen) { confirmedPins.insert(normal) }
        serverFingerprint = nil
        await check()
    }

    /// "Doesn't Match": nothing is pinned or sent.
    func rejectServer() {
        serverFingerprint = nil
        problem = String(localized: "Not paired: the server that answered isn’t the one in TrueNAS’s log. Check the NAS address, then install again.")
    }

    /// The fingerprint matched what TrueNAS shows (System › Certificates): pinned for this address.
    func confirm() async {
        guard let fingerprint else { return }
        TrueNASKeychain.setPin(fingerprint, for: address)
        self.fingerprint = nil
        await connect()
    }

    /// Check Again (and after Connect or Add): each media dataset read through a fresh connection (TrueNAS closes an idle one).
    func checkAccess() async {
        guard !media.isEmpty, !checkingAccess else { return }
        checkingAccess = true
        defer { checkingAccess = false }
        let client = TrueNASClient(address: address, pin: TrueNASKeychain.pin(address))
        defer { client.close() }
        do {
            try await client.connect()
            try await client.login(apiKey)
            for item in media { access[item.dataset] = try await client.readable(item.dataset) }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A new media dataset gets the first free id (nas1, nas2…); ids already there never change (links refer to them).
    func addMedia(_ dataset: String) {
        guard !media.contains(where: { $0.dataset == dataset }) else { return }
        // (After the highest one: an id a removed dataset had may still be in links, so it isn't given to another.)
        let numbers = (media.map(\.id) + [secondIDKept].compactMap { $0 }).compactMap { Int($0.dropFirst(3)) }
        media.append((dataset, "nas\((numbers.max() ?? 0) + 1)"))
    }

    /// The second NAS's media id: as installed, else the first one no dataset has.
    var secondID: String {
        if let secondIDKept { return secondIDKept }
        let taken = Set(media.map(\.id))
        return (2...).lazy.map { "nas\($0)" }.first { !taken.contains($0) }!
    }

    /// A dataset chosen together with one inside it: the same files twice.
    var overlap: String? {
        for outer in media {
            if let inner = media.first(where: { $0.dataset.hasPrefix(outer.dataset + "/") }) {
                return String(localized: "\(outer.dataset) already holds \(inner.dataset): its files would show twice. Keep one of them.")
            }
        }
        return nil
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
        if role == .main, !media.isEmpty, dropFiles { blocks.insert("drop1") }
        // Datasets after the first: copies of the media1 block (TrueNASClient.moreMedia), mediax1, mediax2…
        for (index, item) in media.dropFirst().enumerated() {
            values["mediax\(index + 1)"] = "/mnt/\(item.dataset)"
            values["mediax\(index + 1)_id"] = item.id
        }
        if !secondAddress.isEmpty, !secondPath.isEmpty {
            blocks.insert("media2")
            values["media2_id"] = secondID
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
        guard let template = TrueNASClient.template else {
            problem = String(localized: "This build of Pluck doesn’t have the TrueNAS template.")
            return
        }
        guard image != nil else {
            problem = String(localized: "No signed host release for this version of Pluck yet.")
            return
        }
        problem = nil
        do {
            // A fresh connection: TrueNAS closes one that sat idle while the form was filled in ("Socket is not connected").
            step = String(localized: "Connecting…")
            self.client?.close()
            let client = TrueNASClient(address: address, pin: TrueNASKeychain.pin(address))
            client.appName = role == .main ? "pluck-review" : "pluck-backup"
            self.client = client
            try await client.connect()
            try await client.login(apiKey)
            step = String(localized: "Making datasets…")
            try await client.ensureDataset(data)
            try await client.own(data)
            if !uploads.isEmpty { try await client.ensureDataset(uploads); try await client.own(uploads) }
            // (Only warned about, per media row: the install goes on.)
            for item in media { access[item.dataset] = try await client.readable(item.dataset) }
            step = String(localized: "Installing the app…")
            // The app may be there already (an install that lost its connection after app.create, or Change Folders): its key stays.
            let key = try await Self.existingKey(client) ?? DeliverKeys.base64url(DeliverKeys.random(32))
            let (values, blocks) = values(hostKey: key)
            let compose = try TrueNASClient.render(TrueNASClient.moreMedia(template, count: role == .main ? max(media.count - 1, 0) : 0), values, blocks: blocks)
            try await client.deploy(compose)
            step = String(localized: "Waiting for it to start…")
            try await client.waitRunning()
            step = String(localized: "Pairing…")
            if let editing {
                // The same server: its record, pin and publications stay; the key is the one it already ran with.
                publish.repair(editing.id, pairing: key)
                publish.update(host: editing.id) { $0.rootNames = rootNames }
                save(compose, host: editing.id)
                done = publish.host(editing.id) ?? editing
            } else if role == .main {
                guard let host = publish.addNAS(name: name, address: syncAddress, pairing: key) else { throw TrueNASClient.Failure(message: "pairing") }
                publish.update(host: host.id) { $0.rootNames = rootNames }
                save(compose, host: host.id)
                done = publish.host(host.id) ?? host
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
    @State var setup: TrueNASSetup
    @State private var askKeep = false
    /// Media rows whose ⚠︎ steps are open.
    @State var expanded: Set<String> = []

    @MainActor init() { _setup = State(initialValue: TrueNASSetup()) }
    init(setup: TrueNASSetup, expanded: Set<String> = []) { _setup = State(initialValue: setup); _expanded = State(initialValue: expanded) }
    /// Change Folders… for a server set up here.
    @MainActor init(editing host: Deliver.Host) { _setup = State(initialValue: TrueNASSetup(editing: host)) }

    static let width: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setup.editing != nil ? LocalizedStringKey("Change Folders") : setup.role == .main ? "TrueNAS (automatic)" : "TrueNAS Backup")
                .font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            if setup.editing != nil {
                Text("Pluck reads what’s installed, keeps the server’s key, and updates the app with your changes.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            if let fingerprint = setup.serverFingerprint {
                serverCheck(fingerprint)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        StudioField(label: "NAS") { TextField("192.0.2.10", text: $setup.address).settingField(width: 220).disabled(setup.editing != nil) }
                        StudioField(label: "API key") { SecureField("A key for the user pluck, never root’s", text: $setup.apiKey).settingField(width: 280) }
                        if !setup.connected { keySteps }
                        if let fingerprint = setup.fingerprint {
                            hint(Text("Check TrueNAS’s own certificate: System › Certificates. It should match:"))
                            fingerprintBox(fingerprint)
                            HStack { Spacer(); Button("Matches TrueNAS") { Task { await setup.confirm() } }.buttonStyle(StudioFlatButtonStyle(prominent: true)) }
                        }
                        if setup.connected { choices }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let step = setup.step { HStack { PlumSpinner(); Text(verbatim: step).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) } }
            if let problem = setup.problem {
                Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if askKeep {
                Text("Keep the API key for automatic updates?").font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                HStack {
                    Spacer()
                    Button("Forget") { setup.keepKey(false); dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Keep (Recommended)") { setup.keepKey(true); dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
            } else if setup.serverFingerprint != nil {
                HStack {
                    Spacer()
                    Button("Doesn’t Match") { setup.rejectServer() }.buttonStyle(StudioFlatButtonStyle())
                    Button("Matches") { Task { await setup.confirmServer(); await finish() } }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(setup.step != nil)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                    if setup.done != nil, !setup.verified {
                        Button("Check Again") { Task { await setup.check(); await finish() } }.buttonStyle(StudioFlatButtonStyle()).disabled(setup.step != nil)
                    }
                    if setup.connected {
                        Button(setup.editing != nil ? "Update" : "Install") { Task { await setup.install(); if setup.problem == nil { await setup.check(); await finish() } } }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(setup.step != nil || setup.uploadsOverlap)
                    } else {
                        Button("Connect") { Task { await setup.connect() } }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                            .disabled(setup.address.isEmpty || setup.apiKey.isEmpty || setup.step != nil)
                    }
                }
            }
        }
        .padding(Design.Spacing.sheet)
        // Fixed width, leading: nothing inside may widen the sheet (long names truncate, text wraps).
        .frame(width: Self.width, height: 600, alignment: .topLeading)
        .background(Design.Studio.panel)
        .task { if setup.editing != nil, !setup.apiKey.isEmpty, !setup.connected { await setup.connect() } }
    }

    /// Before Connect: how to make the key, as TrueNAS 25.10 names things.
    private var keySteps: some View {
        Self.steps([
            Text("Credentials › Users › Add: a user “pluck”."),
            Text("Credentials › Groups › Privileges › Add: name “Pluck”, local group “pluck”, roles \(TrueNASClient.roles.joined(separator: ", "))."),
            Text("Your user menu (top right) › API Keys › Add, for the user pluck. Copy the key right away: TrueNAS shows it once."),
        ])
        .padding(.leading, 94).padding(.top, 4)
    }

    /// A short numbered list in hint type.
    static func steps(_ lines: [Text]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { number, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(number + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Design.Brand.deep, in: .circle)
                    line.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A media dataset the server can't read: what to change in TrueNAS (Pluck never changes it), then Check Again.
    static func fixSteps(_ dataset: String) -> some View {
        steps([
            Text("Datasets › \(dataset) › Permissions › Edit."),
            Text("Add Item: Who User, User apps, Permissions Read, Flags Inherit."),
            Text("Tick “Apply permissions recursively” and “Apply permissions to child datasets”."),
            Text("Save Access Control List."),
        ])
    }

    private func hint(_ text: Text) -> some View {
        text.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 94)
    }

    /// A fingerprint in two lines of 16 bytes, so it wraps the same everywhere.
    private func fingerprintBox(_ fingerprint: String) -> some View {
        let parts = (HostSession.normalized(fingerprint) ?? fingerprint).split(separator: ":")
        let lines = parts.count == 32 ? parts[..<16].joined(separator: ":") + "\n" + parts[16...].joined(separator: ":") : fingerprint
        return Text(verbatim: lines).font(.system(size: 11, design: .monospaced)).foregroundStyle(Design.Studio.text).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(10).studioBox()
    }

    /// After Install: the one step left, the owner comparing the server's fingerprint with its log.
    private func serverCheck(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check the server’s fingerprint").font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text)
            Text("In TrueNAS: Apps › \(setup.appName) › Logs, the line with “fingerprint”. It should match:")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            fingerprintBox(fingerprint)
            Text("Pluck sends nothing to the server until you confirm.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Media: one row per dataset (its name and the id links use), each removable, then Add; the second NAS the same.
    @ViewBuilder private var mainChoices: some View {
        StudioField(label: "Media") {
            Menu {
                ForEach(setup.datasets.filter { d in !setup.media.contains { $0.dataset == d } }, id: \.self) { dataset in
                    Button(dataset) { setup.addMedia(dataset); Task { await setup.checkAccess() } }
                }
            } label: { StudioMenuLabel(title: String(localized: "Add")) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        ForEach(setup.media, id: \.dataset) { item in
            mediaRow(symbol: "externaldrive", title: item.dataset, id: item.id, readable: setup.access[item.dataset]) { setup.media.removeAll { $0.dataset == item.dataset } }
        }
        if let overlap = setup.overlap {
            hint(Text(verbatim: overlap)).foregroundStyle(Design.Studio.warn)
        }
        if setup.role == .main, let first = setup.media.first {
            Toggle("Let upload links write here", isOn: $setup.dropFiles)
            hint(Text("Ask for Files links put their files straight into folders of \(first.dataset); nothing there is ever replaced. The app needs write access to it. Off: Pluck moves them there from an office Mac."))
        }
        StudioField(label: "Second NAS") {
            TextField("192.0.2.20", text: $setup.secondAddress).settingField(width: 120)
            TextField("/mnt/tank/media", text: $setup.secondPath).settingField(width: 150)
        }
        if !setup.secondAddress.isEmpty, !setup.secondPath.isEmpty {
            mediaRow(symbol: "network", title: "\(setup.secondAddress):\(setup.secondPath)", id: setup.secondID) { setup.secondAddress = ""; setup.secondPath = "" }
        }
        StudioField(label: "Uploads folder") {
            Menu {
                Button("None") { setup.uploads = "" }
                Divider()
                ForEach(setup.datasets.filter { d in !setup.media.contains { $0.dataset == d } }, id: \.self) { dataset in Button(dataset) { setup.uploads = dataset } }
            } label: { StudioMenuLabel(title: setup.uploads.isEmpty ? String(localized: "None") : setup.uploads) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            TextField("Or type one: tank/renders", text: $setup.uploads).settingField(width: 170)
        }
        hint(Text("Where originals you share from your Mac are saved. Its own dataset: the server may write there; the media folders stay read-only."))
        if setup.uploadsOverlap { hint(Text("The uploads folder can’t be a media dataset, inside one, or hold one.")).foregroundStyle(Design.Studio.warn) }
    }

    /// `readable`: ✓ the server can read it, ⚠︎ it can't (click for the steps), nil not checked (the second NAS).
    private func mediaRow(symbol: String, title: String, id: String, readable: Bool? = nil, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Design.Studio.textQuiet).frame(width: 16)
                Text(verbatim: title).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if readable == true {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Design.Studio.good).help("The server can read this folder")
                } else if readable == false {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Design.Studio.warn)
                }
                Text(verbatim: id).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.textQuiet)
                Button { remove() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Remove")
            }
            .frame(height: 16)
            if readable == false {
                Button {
                    if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
                } label: {
                    HStack(spacing: 4) {
                        Text("The server can’t read this folder (or its subfolders)")
                        Image(systemName: expanded.contains(title) ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.leading, 24)
                if expanded.contains(title) {
                    Self.fixSteps(title).padding(.leading, 24)
                    HStack {
                        Spacer()
                        if setup.checkingAccess { PlumSpinner() }
                        Button("Check Again") { Task { await setup.checkAccess() } }.buttonStyle(StudioFlatButtonStyle()).disabled(setup.checkingAccess)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .studioBox()
        .padding(.leading, 94)
    }

    /// Done only once this Mac's key is accepted; then this Mac's node is registered. A backup has no server here to check.
    private func finish() async {
        guard let done = setup.done else { if setup.problem == nil { askKeep = true }; return }
        guard setup.verified, let host = ReviewPublish.shared.host(done.id) ?? Optional(done) else { return }
        if let node = try? await ReviewHostTunnel.nodeID(host) { _ = try? await ReviewHostClient.ask(host, ["op": "device-node", "node": node]) }
        askKeep = true
    }
}
