import Foundation
import os

extension PhotoSelfTest {
    /// Several office Macs as one office (-PluckScreenshotOnly officegroup), with three simulated office Macs: merging their
    /// states spreads members, paired home Macs, rights and removals to all (a third added later included), removing one
    /// makes a new key; claims on a temp "NAS" folder split 30 clips across three workers with none made twice, and a
    /// claim of a Mac that went offline is taken over; the home Mac picks the least busy online Mac and fails over;
    /// the same NAS folder gets one id; and the protocol over this Mac: an office Mac joining with a code, groupSync,
    /// a home Mac paired on another office Mac let in here, groupNode, failover to the live office Mac.
    static func officeGroupTest() async {
        mergeChecks()
        await claimChecks()
        choiceChecks()
        queueChecks()
        await groupWireChecks()
    }

    private typealias Group = OfficeGroup

    private static func member(_ name: String, _ shares: [OfficeGroup.ShareKey] = []) -> OfficeGroup.Member {
        OfficeGroup.Member(id: UUID(), name: name, addresses: [], shares: shares, updated: .now)
    }

    private static func homeDevice(_ name: String) -> OfficeRenderServer.Device {
        OfficeRenderServer.Device(id: UUID(), name: name, secret: OfficeLink.randomBytes(32), added: .now)
    }

    private static func mergeChecks() {
        let key = OfficeGroup.Key(device: UUID(), secret: OfficeLink.randomBytes(32), version: 1)
        let a = member("Office A"), b = member("Office B"), c = member("Office C")
        let home = homeDevice("Home 1")
        var sa = OfficeGroup.Shared(key: key, members: [a], devices: [home])
        // B joins A.
        var sb = OfficeGroup.merge(sa, OfficeGroup.Shared(key: key, members: [b]))
        sa = OfficeGroup.merge(sa, sb)
        func sync(_ x: inout OfficeGroup.Shared, _ y: inout OfficeGroup.Shared) {
            let merged = OfficeGroup.merge(x, y)
            x = OfficeGroup.merge(merged, x)
            y = OfficeGroup.merge(y, merged)
        }
        check("group: a Mac joining gets the home Macs paired before", sb.devices.contains { $0.id == home.id } && sb.members.count == 2)
        // A third joins B later; A learns it at its next sync with B.
        var sc = OfficeGroup.merge(sb, OfficeGroup.Shared(key: key, members: [c]))
        sb = OfficeGroup.merge(sb, sc)
        sync(&sa, &sb)
        check("group: a third office Mac reaches every member", [sa, sb, sc].allSatisfy { Set($0.members.map(\.id)) == [a.id, b.id, c.id] },
              "\([sa, sb, sc].map { $0.members.map(\.name) })")
        check("group: a home Mac paired earlier is let in by the third", sc.devices.contains { $0.id == home.id })
        // Rights changed on C reach A through B.
        var stricter = sc.devices.first { $0.id == home.id }!
        stricter.rights = .init(browse: true, proxies: false, originals: false, render: false)
        stricter.changed = .now
        sc.devices = sc.devices.map { $0.id == home.id ? stricter : $0 }
        sync(&sc, &sb)
        sync(&sb, &sa)
        check("group: newest rights reach every office Mac", sa.devices.first { $0.id == home.id }?.allowed.proxies == false)
        let merged1 = OfficeGroup.merge(sa, sc), merged2 = OfficeGroup.merge(sc, sa)
        check("group: merging is the same both ways round", merged1.members == merged2.members && merged1.devices == merged2.devices)
        // A removes C: a new key, and B ends up without C and with the new key.
        sa.removed.append(c.id)
        sa.members.removeAll { $0.id == c.id }
        sa.key = OfficeGroup.Key(device: UUID(), secret: OfficeLink.randomBytes(32), version: 2)
        sync(&sa, &sb)
        check("group: a removed office Mac leaves every member, with a new key",
              sb.members.map(\.id).sorted { $0.uuidString < $1.uuidString } == [a.id, b.id].sorted { $0.uuidString < $1.uuidString }
              && sb.key == sa.key && sb.key.version == 2)
        // C, still on the old view, can't bring itself back.
        sync(&sb, &sc)
        check("group: a removed Mac's old view doesn't bring it back", !sb.members.contains { $0.id == c.id })
        // A home Mac removed on B goes on A.
        sb.removedDevices.append(home.id)
        sb.devices.removeAll { $0.id == home.id }
        sync(&sb, &sa)
        check("group: a home Mac removed on one office Mac goes on all", !sa.devices.contains { $0.id == home.id })
        // The same NAS folder: one id on all three.
        let nas = "smb://nas/footage/day 1"
        let ownA = [OfficeGroup.ShareKey(id: "aaaa9", nas: nas)], ownB = [OfficeGroup.ShareKey(id: "bbbb1", nas: nas)]
        let ownC = [OfficeGroup.ShareKey(id: "cccc5", nas: nas), OfficeGroup.ShareKey(id: "cccc6", nas: "smb://nas/other")]
        let aliasA = OfficeGroup.aliases(own: ownA, others: [ownB, ownC]), aliasC = OfficeGroup.aliases(own: ownC, others: [ownA, ownB])
        let canonA = aliasA["aaaa9"].map { $0.union(["aaaa9"]).min()! }, canonC = aliasC["cccc5"].map { $0.union(["cccc5"]).min()! }
        check("group: the same NAS folder gets one id on every office Mac", canonA == "aaaa9" && canonC == "aaaa9" && aliasC["cccc6"] == nil,
              "\(String(describing: canonA)) \(String(describing: canonC))")
        check("group: NAS addresses are tidied", OfficeGroup.tidied(URL(string: "smb://editor@Footage-NAS._smb._tcp.local/Media")!) == "smb://footage-nas/media")
    }

    private static func claimChecks() async {
        let fm = FileManager.default
        let nas = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("GroupNAS-\(UUID().uuidString)/Proxies", isDirectory: true)
        try? fm.createDirectory(at: nas, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: nas.deletingLastPathComponent()) }
        let targets = (1...30).map { nas.appendingPathComponent(String(format: "Day 1/A%03d.mov", $0)) }
        try? fm.createDirectory(at: nas.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        let made = OSAllocatedUnfairLock(initialState: [String: [String]]())

        /// One office Mac's worker: next unclaimed clip, "encoded" into a part file and renamed into place. `dies`: it
        /// claims its first clip and goes offline (never makes or releases it).
        @Sendable func worker(_ mac: String, stale: TimeInterval, dies: Bool = false) async {
            var pass = 0
            while targets.contains(where: { !fm.fileExists(atPath: $0.path) }), pass < 60 {
                pass += 1
                for target in targets.shuffled() where !fm.fileExists(atPath: target.path) {
                    guard let claim = OfficeGroup.claim(target, mac: mac, stale: stale) else { continue }
                    if dies { return }
                    if fm.fileExists(atPath: target.path) { OfficeGroup.release(claim); continue }
                    let part = target.deletingPathExtension().appendingPathExtension("\(UUID().uuidString.prefix(8)).part.mov")
                    fm.createFile(atPath: part.path, contents: Data(mac.utf8))
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 5...25)))
                    if rename(part.path, target.path) == 0 { made.withLock { $0[target.lastPathComponent, default: []].append(mac) } }
                    OfficeGroup.release(claim)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        // Three Macs at once, no Mac going away.
        await withTaskGroup(of: Void.self) { group in
            for mac in ["Office A", "Office B", "Office C"] { group.addTask { await worker(mac, stale: OfficeGroup.staleClaim) } }
        }
        var counts = made.withLock { $0 }
        check("claims: three Macs make every clip", targets.allSatisfy { fm.fileExists(atPath: $0.path) })
        check("claims: no clip made twice across three Macs", counts.count == 30 && counts.values.allSatisfy { $0.count == 1 },
              "\(counts.filter { $0.value.count != 1 })")
        check("claims: the work is split", Set(counts.values.flatMap { $0 }).count >= 2, "\(Set(counts.values.flatMap { $0 }))")
        check("claims: none left behind", ((try? fm.contentsOfDirectory(atPath: nas.appendingPathComponent("Day 1").path)) ?? []).allSatisfy { !$0.hasSuffix(".claim") })

        // Again, one Mac going offline holding a clip: the others take it over once its claim is stale.
        for target in targets { try? fm.removeItem(at: target) }
        made.withLock { $0 = [:] }
        await worker("Office C", stale: 1, dies: true)
        let stuck = targets.first { fm.fileExists(atPath: OfficeGroup.claimURL($0).path) }
        await withTaskGroup(of: Void.self) { group in
            for mac in ["Office A", "Office B"] { group.addTask { await worker(mac, stale: 1) } }
        }
        counts = made.withLock { $0 }
        check("claims: a Mac gone offline mid-job: its clip is taken over", stuck.map { fm.fileExists(atPath: $0.path) } == true
              && counts[stuck?.lastPathComponent ?? ""]?.allSatisfy { $0 != "Office C" } == true, "\(String(describing: stuck)) \(counts)")
        check("claims: still none made twice", counts.count == 30 && counts.values.allSatisfy { $0.count == 1 })

        // A fresh claim isn't taken over; a renewed one stays fresh; a stale one is.
        let lone = nas.appendingPathComponent("lone.mov")
        let held = OfficeGroup.claim(lone, mac: "Office B")
        check("claims: a held clip can't be claimed again", held != nil && OfficeGroup.claim(lone, mac: "Office A", stale: 60) == nil)
        try? await Task.sleep(for: .milliseconds(700))
        if let held { OfficeGroup.renew(held) }
        try? await Task.sleep(for: .milliseconds(600))
        check("claims: a renewed claim stays fresh", OfficeGroup.claim(lone, mac: "Office A", stale: 1) == nil)
        let old = OfficeGroup.claim(nas.appendingPathComponent("old.mov"), mac: "Office C", now: Date.now.addingTimeInterval(-11 * 60))
        check("claims: one older than ten minutes is taken over", old != nil
              && OfficeGroup.claim(nas.appendingPathComponent("old.mov"), mac: "Office A") != nil)
    }

    private static func choiceChecks() {
        typealias State = OfficeRenderClient.MemberState
        let a = UUID(), b = UUID(), c = UUID()
        let states: [(UUID, State)] = [(a, State(online: true, busy: true, load: 0)), (b, State(online: true, load: 3)), (c, State(online: true, load: 1))]
        check("choice: the least busy office Mac of three", OfficeGroup.choose(states, current: nil) == c)
        let cGone = states.map { $0.0 == c ? (c, State(online: false)) : $0 }
        check("choice: it goes offline: the next least busy", OfficeGroup.choose(cGone, current: c) == b)
        check("choice: a tie keeps the one in use", OfficeGroup.choose([(b, State(online: true, load: 1)), (c, State(online: true, load: 1))], current: c) == c)
        check("choice: none online, none chosen", OfficeGroup.choose(states.map { ($0.0, State(online: false)) }, current: a) == nil)
        let order = OfficeGroup.order(cGone, first: nil)
        check("choice: failover goes through all the rest, offline ones last", order == [b, a, c], "\(order)")
        let d = UUID()
        let shareA = OfficeRenderClient.RemoteShare(["id": "nas1", "name": "Footage", "online": true])!
        let shareLocal = OfficeRenderClient.RemoteShare(["id": "loc1", "name": "Scratch", "online": true])!
        let merged = OfficeGroup.mergeShares([(a, [shareA]), (b, [shareA, shareLocal]), (d, [shareA])], names: [a: "Office A", b: "Office B", d: "Office D"])
        check("choice: the same NAS folder listed once from three Macs, a local one with its Mac",
              merged.shares.count == 2 && merged.owners["nas1"] == [a, b, d] && merged.shares.contains { $0.name == "Scratch · Office B" },
              "\(merged.shares.map(\.name))")
    }

    private static func queueChecks() {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("GroupQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let me = UUID()
        let jobs = (0..<3).map { OfficeGroup.Job(id: UUID(), share: "s\($0)", paths: ["Day \($0)"], format: .light, device: nil, member: me,
                                                 from: "Office A", asked: .now) }
        check("queue: jobs go in the NAS queue", jobs.allSatisfy { OfficeGroup.publish($0, in: folder) })
        check("queue: every office Mac reads them", Set(OfficeGroup.queued(in: folder)) == Set(jobs))
        OfficeGroup.unpublish(jobs[0].id, in: folder)
        let left = OfficeGroup.queued(in: folder)
        check("queue: a finished one goes", left.count == 2 && !left.contains(jobs[0]))
        let names = (try? fm.contentsOfDirectory(atPath: OfficeGroup.queueFolder(folder).path)) ?? []
        check("queue: nothing half written left", names.allSatisfy { $0.hasSuffix(".json") }, "\(names)")
    }

    /// Over this Mac: the test copy's server is one office Mac; the others are played by clients with the group's key.
    private static func groupWireChecks() async {
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let server = OfficeRenderServer.shared, group = OfficeGroup.shared
        let local = "127.0.0.1:\(OfficeLink.listenPort)"
        group.testAddresses = [local]
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let home = OfficeRenderClient(account: "office-grouptest")
        defer {
            home.forget()
            for device in server.devices { server.remove(device) }
            group.testAddresses = nil
            server.stop()
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        // A home Mac pairs as before.
        server.startPairing()
        guard let homeCode = server.pairing?.code else { return check("group wire: pairing code", false) }
        do { try await home.pair(.address("127.0.0.1"), code: homeCode) } catch { return check("group wire: home Mac paired", false, error.localizedDescription) }
        let single = try? await home.ask("officeGroup")
        check("group wire: a single office Mac has no group", (single?["members"] as? String).flatMap(OfficeGroup.decode([OfficeGroup.Reach].self))?.isEmpty == true)

        // A home Mac's invitation code can't be used to join as an office Mac (it would get the group key).
        let invited = server.testInvitation()
        let sneaky = try? await OfficeRenderClient(account: nil).pair(.address("127.0.0.1"), code: invited,
                                                                     member: OfficeGroup.encode(member("Office X")) ?? "")
        check("group wire: an invitation code can't join the group", sneaky == nil && !group.isGrouped)

        // Another office Mac joins with a code: it gets the group's key and state.
        let other = member("Office B")
        server.startPairing()
        guard let code = server.pairing?.code, let encoded = OfficeGroup.encode(other) else { return check("group wire: second code", false) }
        let joining = OfficeRenderClient(account: nil)
        guard let answer = try? await joining.pair(.address("127.0.0.1"), code: code, member: encoded),
              let state = (answer["group"] as? String).flatMap(OfficeGroup.decode(OfficeGroup.Shared.self)) else {
            return check("group wire: an office Mac joins with a code", false)
        }
        check("group wire: an office Mac joins with a code", state.members.count == 2 && group.isGrouped
              && state.devices.contains { $0.id == home.office?.device } && server.pairedMacs.count == 1,
              "\(state.members.map(\.name)) \(server.pairedMacs.map(\.name))")
        let peer = OfficeRenderClient(account: nil)
        peer.use(.init(address: "127.0.0.1", addresses: ["127.0.0.1"], name: "Office", device: state.key.device, secret: state.key.secret))

        // A third office Mac (joined through B, so unknown here) with a home Mac paired there: it's let in here too.
        let third = member("Office C"), elsewhere = homeDevice("Home 2")
        var theirs = state
        theirs.members.append(third)
        theirs.devices.append(elsewhere)
        let synced = try? await peer.ask("groupSync", ["state": OfficeGroup.encode(theirs) ?? ""])
        let back = (synced?["state"] as? String).flatMap(OfficeGroup.decode(OfficeGroup.Shared.self))
        check("group wire: groupSync merges a third office Mac", back?.members.count == 3 && group.members.count == 3)
        let stranger = OfficeRenderClient(account: nil)
        stranger.use(.init(address: "127.0.0.1", addresses: ["127.0.0.1"], name: "Office", device: elsewhere.id, secret: elsewhere.secret))
        check("group wire: a home Mac paired on another office Mac is let in here", (try? await stranger.ask("status")) != nil)
        let reach = (try? await home.ask("officeGroup"))?["members"] as? String
        check("group wire: home Macs learn every office Mac", reach.flatMap(OfficeGroup.decode([OfficeGroup.Reach].self))?.count == 3)
        let node = String(repeating: "ab", count: 32)
        _ = try? await home.ask("groupNode", ["node": node])
        check("group wire: a home Mac's link to another office Mac is let in", server.devices.first { $0.id == home.office?.device }?.irohMore == [node]
              && group.local()?.devices.first { $0.id == home.office?.device }?.irohMore == [node])
        check("group wire: home Macs can't sync the group", (try? await home.ask("groupSync", ["state": OfficeGroup.encode(theirs) ?? ""])) == nil)

        // Home failover: the office Mac in use is gone; the question goes to the live one, which is then used.
        if let me = UUID(uuidString: (try? await home.ask("officeGroup"))?["me"] as? String ?? "") {
            let gone = UUID()
            home.useMembers([.init(id: me, name: "Office A", addresses: [local]), .init(id: gone, name: "Office B", addresses: ["127.0.0.1:1"])],
                            primary: me, active: gone)
            let asked = try? await home.ask("status")
            check("group wire: a question fails over to the office Mac that's online", asked != nil && home.memberStates[gone]?.online == false)
            await home.pickOffice()
            check("group wire: the online office Mac is then used", home.active == me)
            let shares = try? await home.shares()
            check("group wire: shares from the office Macs online", shares != nil)
        }

        // A home Mac removed on another office Mac goes here; leaving takes the group's key away.
        theirs.removedDevices.append(elsewhere.id)
        theirs.devices.removeAll { $0.id == elsewhere.id }
        _ = try? await peer.ask("groupSync", ["state": OfficeGroup.encode(theirs) ?? ""])
        check("group wire: a home Mac removed elsewhere is refused here", (try? await stranger.ask("status")) == nil)
        await group.leave()
        check("group wire: leaving: the group's key no longer gets in", (try? await peer.ask("status")) == nil && !group.isGrouped
              && !server.devices.contains { $0.isPeer })
    }
}
