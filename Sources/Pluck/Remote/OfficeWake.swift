import Darwin
import Foundation
import SwiftUI
import SystemConfiguration

/// Waking an office Mac that sleeps: its helper can't answer, so another online office Mac of the group (OfficeGroup)
/// sends a Wake-on-LAN magic packet on the office network to its Ethernet address (each office Mac puts its own in the
/// group's record). Wi-Fi wake is unreliable. `pmset repeat wakeorpoweron` needs an administrator: shown, never run.
enum OfficeWake {
    static let action = "wake"

    /// 6 × 0xFF, then the address 16 times; nil for a malformed address.
    static func packet(_ address: String) -> Data? {
        let bytes = address.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, address.split(whereSeparator: { $0 == ":" || $0 == "-" }).allSatisfy({ $0.count == 2 }) else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    /// This Mac's wired Ethernet address ("a1:b2:…"), nil without one.
    static func ethernet() -> String? {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return all.lazy.filter { SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeEthernet }
            .compactMap { SCNetworkInterfaceGetHardwareAddressString($0) as String? }
            .first { packet($0) != nil }?.lowercased()
    }

    /// The packet to the office network's broadcast address, ports 9 and 7.
    static func send(_ packet: Data) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw OfficeLink.Failure.office(String(localized: "The wake message couldn’t be sent.")) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for port: UInt16 in [9, 7] {
            var target = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
                                     sin_addr: in_addr(s_addr: INADDR_BROADCAST), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let n = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            sent = sent || n == packet.count
        }
        guard sent else { throw OfficeLink.Failure.office(String(localized: "The wake message couldn’t be sent.")) }
    }

    /// The command that wakes the Mac on schedule (the owner runs it in Terminal, as an administrator).
    static let schedule = "sudo pmset repeat wakeorpoweron MTWRF 07:30:00"

    // MARK: - Office

    @MainActor
    static func register() {
        // {member: id} → wakes that office Mac of the group from here (on the office network).
        OfficeActions.register(action) { arguments, _ in
            let id = try OfficeActions.text(arguments["member"], 40)
            guard let member = OfficeGroup.shared.members.first(where: { $0.id.uuidString == id }) else { throw OfficeActions.incomplete() }
            guard let address = member.ethernet, let packet = packet(address) else {
                throw OfficeLink.Failure.office(String(localized: "\(member.name) has no Ethernet address in the office group (Wi-Fi can’t be woken reliably)."))
            }
            try send(packet)
            return ["sent": true]
        }
    }

    // MARK: - Home

    /// Asks another online office Mac of the group to wake `member`. An office Mac from before says it can't.
    @MainActor
    static func wake(_ member: UUID) async throws {
        let client = OfficeRenderClient.shared
        let helpers = client.members.filter { $0.id != member && client.memberStates[$0.id]?.online != false }
        guard !helpers.isEmpty else { throw OfficeLink.Failure.office(String(localized: "No other office Mac is online to wake it.")) }
        var last: Error?
        for helper in helpers {
            do {
                _ = try await client.ask(on: helper.id, action, ["member": member.uuidString], timeout: 30)
                return
            } catch OfficeLink.Failure.office(let message) where message == String(localized: "The host Mac doesn’t know how to do that.") {
                last = OfficeLink.Failure.office(String(localized: "\(helper.name)’s Pluck can’t wake other Macs yet. Update it there."))
            } catch {
                last = error
            }
        }
        throw last ?? OfficeLink.Failure.unreachable
    }
}

/// Office › Macs: how this Mac can be woken from the others (Energy settings, Ethernet), and the schedule command to run.
struct WakeGuide: View {
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Another office Mac can wake this one when it sleeps:")
                Text("1. System Settings › Energy: turn on Wake for network access.")
                Text("2. Keep it on its power adapter and on Ethernet. Wake over Wi-Fi is unreliable.")
                Text(OfficeWake.ethernet() == nil ? "This Mac has no Ethernet port in use." : "This Mac’s Ethernet address is shared with the office Macs.")
                    .foregroundStyle(OfficeWake.ethernet() == nil ? Design.Studio.warn : Design.Studio.textQuiet)
                Text("To have it wake every weekday morning, run this in Terminal yourself (it needs an administrator):")
                HStack {
                    Text(verbatim: OfficeWake.schedule).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    PinkLink(title: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(OfficeWake.schedule, forType: .string)
                    }
                }
            }
            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.top, 4)
        } label: {
            Text("Waking this Mac").font(Design.Studio.hint)
        }
    }
}
