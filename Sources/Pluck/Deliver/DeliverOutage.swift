import CryptoKit
import SwiftUI

/// Uploads during an outage (§13.25): while the main server is down its backup holds the room and takes uploads, the
/// editor's too. Pluck learns each backup's own way in from the main while the main is up (`status` › backups ›
/// replica.office, only when both run 4.0.4) and registers the iroh node it will use for it (`outage-node`, its own key
/// `Review/iroh/<route id>.key`); the backup then lets this Mac in on that node with the main's device key. When the main
/// is back the backup moves everything there, and the main lists it (`outage-list`) for the Inbox.
extension Deliver {
    struct OutageRoute: Codable, Hashable {
        /// The id this Mac gives the backup's route (its tunnel, its key file, its Keychain copy of the device key).
        var id = UUID()
        var name: String
        var node: String
        var relay: String?
        var pin: String
        /// This Mac's outage node as the main last accepted it (nil: not yet, so it's not offered).
        var registered: String?
    }
}

@MainActor
enum DeliverOutage {
    /// Tests: this Mac's outage node without a key file (the fake host doesn't check it).
    static var fakeNode: String?

    /// What the main's `status` says of its backups: the first that takes outage uploads becomes this Mac's route,
    /// and this Mac's node for it is registered on the main (once per node).
    static func note(status: [String: Any], host: Deliver.Host, publish: ReviewPublish = .shared) async {
        guard host.kind == .nas, host.role != "backup", host.device != nil else { return }
        let office = (status["backups"] as? [[String: Any]] ?? []).compactMap { backup -> (String, [String: Any])? in
            guard let replica = backup["replica"] as? [String: Any], replica["outage"] as? Int == 1,
                  let office = replica["office"] as? [String: Any], office["node"] is String, office["fp"] is String else { return nil }
            return (backup["name"] as? String ?? "", office)
        }.first
        guard let (name, office) = office, let node = office["node"] as? String, let pin = office["fp"] as? String else {
            // The main answered and has no such backup now (removed, or back to 4.0.3): nothing is offered any more;
            // what was queued for it waits for the main instead.
            if status["backups"] != nil, let old = host.outage { ReviewHostTunnel.forget(old.id); publish.update(host: host.id) { $0.outage = nil } }
            return
        }
        var route = host.outage ?? Deliver.OutageRoute(name: name, node: node, pin: pin)
        let changed = route.node != node || route.pin != pin
        (route.name, route.node, route.pin, route.relay) = (Deliver.clean(name, limit: 80), node, pin, office["relay"] as? String)
        if changed { route.registered = nil; ReviewHostTunnel.forget(route.id) }
        if route.registered == nil || route.registered != myNode(route) {
            guard let mine = myNode(route), let device = host.device, let key = ReviewHostClient.deviceKey(host),
                  (try? await ReviewHostClient.ask(host, ["op": "outage-node", "node": mine]))?["ok"] as? Bool == true else {
                publish.update(host: host.id) { $0.outage = route }
                return
            }
            // The backup checks the main's device key; the route has its own Keychain account for it.
            DeliverKeychain.save(Data(key.utf8), as: "\(route.id.uuidString)/\(device)", service: DeliverKeychain.hostService)
            route.registered = mine
        }
        if route != host.outage { publish.update(host: host.id) { $0.outage = route } }
    }

    /// This Mac's iroh node for a backup route: its key file's public half (made on first use, as pluck-iroh would).
    static func myNode(_ route: Deliver.OutageRoute) -> String? {
        if let fakeNode { return fakeNode }
        let file = ReviewHostTunnel.keyFile(backupHost(route, device: nil))
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: file.path, contents: Curve25519.Signing.PrivateKey().rawRepresentation, attributes: [.posixPermissions: 0o600])
        }
        guard let seed = try? Data(contentsOf: file), seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private static func backupHost(_ route: Deliver.OutageRoute, device: String?) -> Deliver.Host {
        Deliver.Host(id: route.id, name: route.name, kind: .nas, address: nil, pin: route.pin, node: route.node, relay: route.relay, device: device, role: "backup")
    }

    /// The main's backup as a server this Mac can upload to, once its node is registered there.
    static func backup(for main: Deliver.Host) -> Deliver.Host? {
        guard let route = main.outage, route.registered != nil, let device = main.device else { return nil }
        return backupHost(route, device: device)
    }

    /// The file to the backup, with the folder picked on the main; the backup's id for it (outage-list on the main has it later).
    static func upload(_ url: URL, folder: String, main: Deliver.Host) async throws -> String {
        guard let backup = backup(for: main) else { throw Deliver.Failure("offline") }
        let end = try await DeliverUploads.shared.send(url, to: "outage/" + url.lastPathComponent, host: backup, extra: ["folder": folder], attempts: 2)
        guard let id = end["outage"] as? String else { throw Deliver.Failure("internal") }
        return id
    }

    struct Item: Identifiable, Hashable {
        var id: String
        var host: UUID
        var kind: String       // asset (a client's) | editor
        var name: String
        var path: String
        var by: String
        var at: Date?
        var link: UUID?
        var moved: Bool
        var quarantine: Bool
    }

    /// What arrived on a main's backup during an outage and is on the main now.
    static func delivered(_ host: Deliver.Host) async throws -> [Item] {
        let answer = try await ReviewHostClient.ask(host, ["op": "outage-list"])
        return (answer["items"] as? [[String: Any]] ?? []).compactMap { x in
            guard let id = x["id"] as? String, let path = x["path"] as? String else { return nil }
            return Item(id: id, host: host.id, kind: x["kind"] as? String ?? "", name: x["name"] as? String ?? "", path: path, by: x["by"] as? String ?? "",
                        at: (x["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, link: (x["link"] as? String).flatMap(UUID.init(uuidString:)),
                        moved: x["moved"] as? Bool ?? false, quarantine: x["quarantine"] as? Bool ?? false)
        }
    }

    /// Move to…: inside the uploads folder (versions pointing at it follow), then the entry is done.
    static func move(_ item: Item, to folder: String, host: Deliver.Host) async throws {
        let moved = try await DeliverUploadDestination.move(item.path, to: folder, host: host)
        _ = try await ReviewHostClient.ask(host, ["op": "outage-done", "id": item.id, "path": moved])
    }

    /// The main servers that may have something.
    static var mains: [Deliver.Host] { ReviewPublish.shared.hosts.filter { $0.kind == .nas && $0.role != "backup" && $0.outage != nil } }
}

/// The Inbox's "Arrived during outage": what clients and editors uploaded to the backup while the main was down, now on
/// the main; each can be moved to its place (then it's done) or shown in Browse.
struct DeliverOutageInbox: View {
    @Bindable var nav: StudioNavigator
    @State private var items: [DeliverOutage.Item] = []
    @State private var moving: DeliverOutage.Item?
    @State private var problem: String?
    @State private var store = DeliverStore.shared

    var body: some View {
        let open = items.filter { !$0.moved }
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Arrived during outage").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                        if !open.isEmpty { StudioChip(text: Text(verbatim: "\(open.count)"), colour: Design.Studio.warn, tinted: true) }
                    }
                    if items.contains(where: \.quarantine) {
                        Text("No uploads folder on the server, so Pluck took these in as usual.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
                    ForEach(items) { row($0) }
                }
                .padding(.bottom, 16)
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .sheet(item: $moving) { item in
            if let host = ReviewPublish.shared.host(item.host) {
                DeliverUploadPicker(host: host, project: nil, title: String(localized: "Move to…"), action: String(localized: "Move"), done: { folder in
                    moving = nil
                    guard let folder else { return }
                    Task {
                        do { try await DeliverOutage.move(item, to: folder, host: host); problem = nil } catch { problem = ReviewHostClient.problem(error) }
                        await load()
                    }
                }, back: { moving = nil })
                .padding(Design.Spacing.sheet).frame(minWidth: 900, idealWidth: 1060, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
                .background(Design.Studio.panel)
            }
        }
    }

    private func load() async {
        var all: [DeliverOutage.Item] = []
        for host in DeliverOutage.mains { all += (try? await DeliverOutage.delivered(host)) ?? [] }
        items = all
    }

    /// "Interview A.mov", who, when, which link (or the editor's Mac), and its actions.
    private func row(_ item: DeliverOutage.Item) -> some View {
        let link = item.link.flatMap { store.link($0) }
        let source = link.map { link in [link.title, store.project(link.project)?.name].compactMap { $0 }.joined(separator: " · ") } ?? String(localized: "Uploaded from Pluck")
        return HStack(spacing: 10) {
            Image(systemName: item.moved ? "checkmark.circle" : "tray.and.arrow.down").font(.system(size: 12))
                .foregroundStyle(item.moved ? Design.Studio.good : Design.Studio.textQuiet).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.name).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: item.by).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                .font(Design.Studio.body)
                Text(verbatim: source).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer()
            if let at = item.at { Text(at, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint) }
            if !item.quarantine {
                Button("Show in Browse") {
                    DeliverBrowseView.pending = "nasroot:" + item.host.uuidString + "/" + item.path.split(separator: "/").dropLast().joined(separator: "/")
                    nav.deliver = .browse(.nas(item.host))
                }
                .buttonStyle(StudioFlatButtonStyle())
                if !item.moved { Button("Move to…") { moving = item }.buttonStyle(StudioFlatButtonStyle(prominent: true)) }
            }
        }
        .padding(10)
        .studioBox()
    }
}
