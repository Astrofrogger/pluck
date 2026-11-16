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
    /// A pluck://edit-anywhere link this Pluck can't read (a newer kind of invitation, or a cut-off link).
    var unreadable = false
    private(set) var working = false
    var problem: String?

    /// Join a Teammate's Server… keeps the "Join?" steps in its own sheet (Deliver's sidebar doesn't open a second one).
    var inline = false
    var showing: Bool { pending != nil || askMove != nil || unreadable }

    /// A pluck://edit-anywhere link, clicked or pasted: a review server's waits for "Join “X”?", one Pluck can't read is
    /// said. Returns an Edit Anywhere invitation (for its own window); nil when Deliver has it.
    func take(_ link: String) -> PrivateNetwork.Invitation? {
        guard let invitation = PrivateNetwork.Invitation(link: link) else { unreadable = true; return nil }
        guard case .reviewHost = invitation.way else { return invitation }
        problem = nil
        pending = invitation
        return nil
    }

    func pair(_ invitation: PrivateNetwork.Invitation) async {
        working = true
        defer { working = false }
        do {
            let host = try await ReviewHostClient.pair(invitation)
            pending = nil
            problem = nil
            StudioNavigator.shared.deliver = .browse(.nas(host.id)) // Browse › Review server, as on the owner's Mac
            if DeliverSync.shared.state.host == nil, host.role != "backup" { askMove = host }
        } catch {
            problem = Self.problem(error, name: invitation.name)
        }
    }

    /// Why joining didn't work, in words: an expired or used link, a server out of reach, an old Pluck.
    static func problem(_ error: Error, name: String) -> String {
        switch error {
        case PrivateNetwork.Failure.inviteExpired: return String(localized: "This invitation has expired. Ask for a new one.")
        case PrivateNetwork.Failure.inviteUsed: return String(localized: "This invitation was already used. Ask for a new one.")
        default: break
        }
        switch (error as? Deliver.Failure)?.code {
        case "unreachable": return String(localized: "Pluck can’t reach “\(name)”. Check that this Mac is online, or try again on the office network.")
        case "incompatible", "newer": return String(localized: "This invitation needs a newer Pluck. Update Pluck, then open the link again.")
        case "pin": return String(localized: "“\(name)” shows a different certificate than the invitation. Ask for a new one.")
        default: return String(localized: "Joining didn’t work. Ask for a new invitation.")
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
                Text("Join “\(invitation.name)”?").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text("This Mac will use this review server: browse its media and keep review data there. Pluck sets everything up.")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                if invitation.expired { Text("This invitation has expired. Ask for a new one.").font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
                if let problem = pairing.problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
                HStack {
                    if pairing.working { PlumSpinner() }
                    Spacer()
                    Button("Cancel") { pairing.pending = nil; pairing.problem = nil }.buttonStyle(StudioFlatButtonStyle())
                    Button("Join") { Task { await pairing.pair(invitation) } }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(invitation.expired || pairing.working)
                }
            } else if pairing.unreadable {
                Text("Pluck can’t read this invitation").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text(DeliverPairing.problem(Deliver.Failure("newer"), name: "")).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") { pairing.unreadable = false }.buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 420)
        .background(Design.Studio.panel)
    }
}

/// Set Up Server › Join a Teammate's Server…: the invitation link pasted (the clipboard's when it holds one), then the
/// same steps as clicking it (DeliverPairing.take, DeliverPairingSheet).
struct DeliverJoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = DeliverPairing.shared
    @State var link = ""
    /// A review server's invitation was taken: when its steps end, this sheet closes.
    @State private var taken = false

    var body: some View {
        Group {
            if pairing.showing {
                DeliverPairingSheet()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Join a Teammate’s Server").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                    TextField("Paste the invitation link", text: $link).settingField(width: 372).onSubmit(join)
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                        Button("Join", action: join).buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(Design.Spacing.sheet)
                .frame(width: 420)
                .background(Design.Studio.panel)
            }
        }
        .onAppear {
            pairing.inline = true
            if link.isEmpty, let copied = NSPasteboard.general.string(forType: .string), Self.isReviewInvitation(copied) {
                link = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onDisappear { pairing.inline = false }
        .onChange(of: pairing.showing) { _, showing in if !showing, taken { dismiss() } }
    }

    static func isReviewInvitation(_ text: String) -> Bool {
        guard let invitation = PrivateNetwork.Invitation(link: text), case .reviewHost = invitation.way else { return false }
        return true
    }

    private func join() {
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let other = pairing.take(link) { dismiss(); URLScheme.editAnywhere(other); return }
        taken = pairing.pending != nil
    }
}
