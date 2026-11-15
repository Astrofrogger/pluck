import Foundation
import Network
import SwiftUI

/// How a NAS host is reached (§13.2): its LAN address when it answers within 1.5 s, else a home-mode `pluck-iroh`
/// of its own (its own key, `Review/iroh/<hostID>.key`, never Edit Anywhere's) leading to the NAS's node. The choice
/// is remembered per run for 5 minutes. Nothing listens on the internet: iroh is outbound.
@MainActor
enum ReviewHostTunnel {
    enum Via: String { case lan, internet, relay }
    struct Route: Equatable { var address: String; var via: Via }

    /// Tests stand in here: whether the LAN address answers, and the tunnel's local address for a host.
    static var lanProbe: ((String, TimeInterval) async -> Bool)?
    static var tunnelStart: ((Deliver.Host) async throws -> (listen: String, node: String))?
    /// Tests: settings for the real pluck-iroh ("local", "officeAddrs"), as Tunnel.testSettings.
    static var testSettings: [String: Any]?

    private static var remembered: [UUID: (route: Route, at: Date)] = [:]
    private static var tunnels: [UUID: Tunnel] = [:]

    static func keyFile(_ host: Deliver.Host) -> URL {
        DeliverStore.shared.root.appendingPathComponent("iroh/\(host.id.uuidString).key")
    }

    /// Pairing learns the host's real id: this Mac's iroh key (its node id, which the host now allows) moves to it.
    static func moved(from old: UUID, to new: UUID) {
        guard old != new else { return }
        let from = DeliverStore.shared.root.appendingPathComponent("iroh/\(old.uuidString).key"), to = DeliverStore.shared.root.appendingPathComponent("iroh/\(new.uuidString).key")
        // (A key already there is kept aside, never deleted: re-pairing the same host gets the new key.)
        if FileManager.default.fileExists(atPath: to.path) {
            try? FileManager.default.moveItem(at: to, to: to.appendingPathExtension(UUID().uuidString.prefix(8) + ".previous"))
        }
        try? FileManager.default.moveItem(at: from, to: to)
        tunnels.removeValue(forKey: old)?.stop() // (it holds the old key path; the next start reads the moved key)
        remembered[old] = nil
    }

    /// The remembered route only (the tunnel keeps running).
    static func forgetRoute(_ host: UUID) { remembered[host] = nil }

    static func forget(_ host: UUID) {
        remembered[host] = nil
        tunnels.removeValue(forKey: host)?.stop()
    }

    /// The route for this run (fakes: the LAN address as it is).
    static func route(_ host: Deliver.Host) async throws -> Route {
        if ReviewHostClient.fake != nil, lanProbe == nil { return Route(address: host.address ?? "fake", via: .lan) }
        if let known = remembered[host.id], Date.now.timeIntervalSince(known.at) < 300 { return known.route }
        var route: Route?
        if let address = host.address, await (lanProbe ?? reachable)(address, 1.5) { route = Route(address: address, via: .lan) }
        if route == nil {
            guard host.node != nil else { throw Deliver.Failure("offline") }
            let started = try await start(host)
            route = Route(address: started.listen, via: via(host))
        }
        remembered[host.id] = (route!, .now)
        return route!
    }

    /// Direct or through a relay, from pluck-iroh's `conn` report.
    private static func via(_ host: Deliver.Host) -> Via {
        guard let node = host.node, let link = tunnels[host.id]?.links[node] else { return .internet }
        return link.direct ? .internet : .relay
    }

    /// "Office NAS · LAN" | "· via internet" | "· via relay (slow)".
    static func status(_ host: Deliver.Host) -> String? {
        guard let route = remembered[host.id]?.route else { return nil }
        switch route.via {
        case .lan: return String(localized: "\(host.name) · LAN")
        case .internet: return String(localized: "\(host.name) · via internet")
        case .relay: return String(localized: "\(host.name) · via relay (slow)")
        }
    }

    static func via(of host: UUID) -> Via? { remembered[host]?.route.via }

    /// This Mac's node id for the host (its key is made first: `pair` sends it).
    static func nodeID(_ host: Deliver.Host) async throws -> String {
        try await start(host).node
    }

    private static func start(_ host: Deliver.Host) async throws -> (listen: String, node: String) {
        if let tunnelStart { return try await tunnelStart(host) }
        try FileManager.default.createDirectory(at: keyFile(host).deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tunnel = tunnels[host.id] ?? Tunnel(.home, .iroh, keyFile: keyFile(host))
        tunnel.testSettings = testSettings
        tunnels[host.id] = tunnel
        try await tunnel.start(office: host.node, officeRelay: host.relay)
        guard let listen = tunnel.listen, case .running(_, let node) = tunnel.state else { throw Deliver.Failure("offline") }
        return (listen, node)
    }

    /// A plain TCP connect within `timeout` (the TLS comes after, on the chosen route).
    nonisolated static func reachable(_ address: String, _ timeout: TimeInterval) async -> Bool {
        let parts = address.split(separator: ":")
        guard let port = NWEndpoint.Port(rawValue: UInt16(parts.count > 1 ? String(parts.last!) : "8790") ?? 8790) else { return false }
        let name = parts.count > 1 ? parts.dropLast().joined(separator: ":") : address
        let connection = NWConnection(host: NWEndpoint.Host(name), port: port, using: .tcp)
        let queue = DispatchQueue(label: "be.wideopen.pluck.review-route")
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled: if once.claim() { connection.cancel(); continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { if once.claim() { connection.cancel(); continuation.resume(returning: false) } }
        }
    }
}

/// A NAS invitation waiting for the owner's yes (§13.2), then the question where the review data lives.
@MainActor
@Observable
final class DeliverPairing {
    static let shared = DeliverPairing()
    var pending: PrivateNetwork.Invitation?
    /// Paired, and not asked yet whether the data moves there.
    var askMove: Deliver.Host?
    private(set) var working = false
    var problem: String?

    func pair(_ invitation: PrivateNetwork.Invitation) async {
        working = true
        defer { working = false }
        do {
            let host = try await ReviewHostClient.pair(invitation)
            pending = nil
            problem = nil
            if DeliverSync.shared.state.host == nil, host.role != "backup" { askMove = host }
        } catch {
            problem = (error as? PrivateNetwork.Failure)?.errorDescription ?? String(localized: "Pairing didn’t work. Ask for a new link.")
        }
    }
}

/// "Pair with Office NAS?", then "Keep review data on Office NAS?" (Move is the default).
struct DeliverPairingSheet: View {
    @State private var pairing = DeliverPairing.shared
    /// Screenshots: shown without asking (a sheet doesn't draw off screen).
    var preview: PrivateNetwork.Invitation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let host = pairing.askMove {
                Text("Keep review data on \(host.name)?").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text("Projects stay on this Mac too and work offline.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                HStack {
                    Spacer()
                    Button("Not now") { pairing.askMove = nil }.buttonStyle(StudioFlatButtonStyle())
                    Button("Move") {
                        pairing.askMove = nil
                        Task { try? await DeliverSync.shared.migrate(to: host) }
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            } else if let invitation = pairing.pending ?? preview {
                Text("Pair with \(invitation.name)?").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text("This Mac can then browse its media and keep review data there, from anywhere.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                if invitation.expired { Text("This invitation has expired.").font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
                if let problem = pairing.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
                HStack {
                    if pairing.working { PlumSpinner() }
                    Spacer()
                    Button("Cancel") { pairing.pending = nil; pairing.problem = nil }.buttonStyle(StudioFlatButtonStyle())
                    Button("Pair") { Task { await pairing.pair(invitation) } }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(invitation.expired || pairing.working)
                }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 420)
        .background(Design.Studio.panel)
    }
}
