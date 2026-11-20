import Foundation

extension PhotoSelfTest {
    /// Waking an office Mac (part of officegroup): the magic packet's bytes, malformed addresses refused, this Mac's
    /// Ethernet address (when it has one) in the form the packet takes, a member from before (no address) refused in
    /// words, the schedule command only shown, and an older office Mac's "unknown action" put plainly.
    static func wakeChecks() async {
        let packet = OfficeWake.packet("A1:b2:03:04:05:FF")
        let address: [UInt8] = [0xA1, 0xB2, 0x03, 0x04, 0x05, 0xFF]
        check("wake: magic packet is 6 × FF and the address 16 times", packet?.count == 102 && packet?.prefix(6).allSatisfy { $0 == 0xFF } == true
              && (0..<16).allSatisfy { Array(packet!.dropFirst(6 + $0 * 6).prefix(6)) == address })
        check("wake: malformed addresses are refused", OfficeWake.packet("a1:b2:03:04:05") == nil && OfficeWake.packet("zz:b2:03:04:05:06") == nil
              && OfficeWake.packet("a1b2:03:04:05:06:07") == nil)
        check("wake: this Mac's Ethernet address reads as one", OfficeWake.ethernet().map { OfficeWake.packet($0) != nil } ?? true)
        let old = #"{"id":"\#(UUID().uuidString)","name":"Office 2","addresses":[],"shares":[],"updated":0}"#
        let oldMember = try? JSONDecoder().decode(OfficeGroup.Member.self, from: Data(old.utf8))
        check("wake: a member from before has no address", oldMember?.ethernet == nil)
        var newMember = oldMember
        newMember?.version = "4.0.7"
        check("wake: an older office Mac is told apart by its version", !OfficeWake.canWake(oldMember) && OfficeWake.canWake(newMember) && !OfficeWake.canWake(nil))
        check("wake: the schedule command needs an administrator and is only shown", OfficeWake.schedule.hasPrefix("sudo pmset repeat wakeorpoweron"))
        OfficeActions.registerAll()
        guard let handler = OfficeActions.handler(OfficeWake.action) else { return check("wake: the office action is there", false) }
        let device = OfficeRenderServer.Device(id: UUID(), name: "Mac", secret: Data(count: 32), added: .now)
        do {
            _ = try await handler(["member": UUID().uuidString], device)
            check("wake: an office Mac not in the group is refused", false)
        } catch {
            check("wake: an office Mac not in the group is refused", true)
        }
        do {
            try await OfficeWake.wake(UUID())
            check("wake: with no other office Mac online it says so", false)
        } catch {
            check("wake: with no other office Mac online it says so", error.localizedDescription == String(localized: "No other office Mac is online to wake it."),
                  error.localizedDescription)
        }
    }
}
