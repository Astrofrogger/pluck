import Foundation

extension PhotoSelfTest {
    /// Edit Anywhere over iroh (-PluckScreenshotOnly remoteiroh): v2 invitation links (round trip,
    /// bad links, expiry), the transport choice and its migration (Tailscale setups stay on it),
    /// then, offline, a real pairing through two local pluck-iroh helpers (no relays, direct
    /// loopback addresses, own keys in the test home): join by link, a status request, the link
    /// working once, and a removed Mac cut off.
    static func remoteIrohTest() async {
        // Links.
        let node = String(repeating: "ab", count: 32), code = OfficeLink.newPairingCode()
        let expires = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 900).rounded(.down))
        let invitation = PrivateNetwork.Invitation(way: .iroh(node: node, relay: "https://relay.example.com", expires: expires), name: "Office", code: code)
        let link = invitation.link?.absoluteString ?? ""
        check("iroh: link is pluck://edit-anywhere/join?i=…", link.hasPrefix("pluck://edit-anywhere/join?i="), link)
        check("iroh: link reads back the same", PrivateNetwork.Invitation(link: link) == invitation && invitation.expired == false)
        func linkFor(_ json: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            return "pluck://edit-anywhere/join?i=" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let good: [String: Any] = ["v": 2, "o": node, "n": "Office", "c": code, "e": 2_000_000_000]
        check("iroh: link without a relay reads", PrivateNetwork.Invitation(link: linkFor(good))?.way == .iroh(node: node, relay: nil, expires: Date(timeIntervalSince1970: 2_000_000_000)))
        check("iroh: bad links are refused", PrivateNetwork.Invitation(link: linkFor(good.merging(["o": "xyz"]) { $1 })) == nil
              && PrivateNetwork.Invitation(link: linkFor(good.merging(["c": "nope"]) { $1 })) == nil
              && PrivateNetwork.Invitation(link: linkFor(good.merging(["r": "ftp://x"]) { $1 })) == nil
              && PrivateNetwork.Invitation(link: linkFor(good.filter { $0.key != "e" })) == nil
              && PrivateNetwork.Invitation(link: "https://edit-anywhere/join?i=" + linkFor(good).split(separator: "=").last!) == nil)
        check("iroh: Tailscale (v1) links still read", PrivateNetwork.Invitation(link: linkFor(["key": "tskey-auth-x", "office": "100.1.2.3", "name": "Office", "code": code]))?.way
              == .tailscale(key: "tskey-auth-x", address: "100.1.2.3"))
        let old = PrivateNetwork.Invitation(way: .iroh(node: node, relay: nil, expires: .now.addingTimeInterval(-1)), name: "Office", code: code)
        check("iroh: an expired link reads, and says so", old.expired && PrivateNetwork.Invitation(link: old.link?.absoluteString ?? "")?.expired == true)
        do {
            try await OfficeRenderClient.shared.join(old)
            check("iroh: joining with an expired link is refused", false)
        } catch {
            check("iroh: joining with an expired link is refused", (error as? PrivateNetwork.Failure).map { if case .inviteExpired = $0 { true } else { false } } == true,
                  error.localizedDescription)
        }
        check("iroh: relay addresses", PrivateNetwork.relayAddress(" https://relay.example.com ") == "https://relay.example.com"
              && PrivateNetwork.relayAddress("relay.example.com") == nil && PrivateNetwork.relayAddress("https://") == nil)
        check("iroh: relays use https (http only on this Mac or a .test name)", PrivateNetwork.relayAddress("http://relay.example.com") == nil
              && PrivateNetwork.relayAddress("http://localhost:3340") != nil && PrivateNetwork.relayAddress("http://relay.test") != nil
              && PrivateNetwork.Invitation(link: linkFor(good.merging(["r": "http://relay.example.com"]) { $1 })) == nil)

        // The transport choice.
        let defaults = UserDefaults.standard
        let savedTransport = defaults.string(forKey: PrivateNetwork.transportKey)
        defer { defaults.set(savedTransport, forKey: PrivateNetwork.transportKey) }
        check("iroh: new setups use iroh, Tailscale setups stay, a choice is kept",
              PrivateNetwork.transport(saved: nil, onTailscale: false) == .iroh && PrivateNetwork.transport(saved: nil, onTailscale: true) == .tailscale
              && PrivateNetwork.transport(saved: "iroh", onTailscale: true) == .iroh && PrivateNetwork.transport(saved: "tailscale", onTailscale: false) == .tailscale)
        defaults.removeObject(forKey: PrivateNetwork.transportKey)
        PrivateNetwork.Account.save(token: "tskey-api-test")
        let migrated = PrivateNetwork.transport
        PrivateNetwork.Account.forget()
        check("iroh: a Mac with a Tailscale token stays on Tailscale, and that's saved",
              migrated == .tailscale && PrivateNetwork.transport == .tailscale && defaults.string(forKey: PrivateNetwork.transportKey) == "tailscale")
        PrivateNetwork.transport = .iroh
        check("iroh: the choice persists", defaults.string(forKey: PrivateNetwork.transportKey) == "iroh" && PrivateNetwork.transport == .iroh)
        let secret = Data(repeating: 1, count: 32).base64EncodedString()
        let oldOffice = #"{"address":"10.0.0.2","network":"100.64.0.1","name":"Office","device":"\#(UUID().uuidString)","secret":"\#(secret)"}"#
        let decoded = try? JSONDecoder().decode(OfficeRenderClient.Office.self, from: Data(oldOffice.utf8))
        check("iroh: a home Mac paired over Tailscale keeps that way", decoded?.network == "100.64.0.1" && decoded?.iroh == nil && decoded?.fromAnywhere == true)
        let oldDevice = #"{"id":"\#(UUID().uuidString)","name":"Mac","secret":"\#(secret)","added":0}"#
        check("iroh: paired Macs from before decode", (try? JSONDecoder().decode(OfficeRenderServer.Device.self, from: Data(oldDevice.utf8)))?.iroh == nil)

        await irohLoopback()
        await relayTest()
    }

    /// Two local helpers on this Mac carrying the Pluck protocol: no internet, no relays. Also: a
    /// helper that can't start says why, the office's helper restarted keeps the invitation open,
    /// a stranger dialing first (wrong codes, a false node id) uses nothing up, and a damaged key
    /// is replaced.
    private static func irohLoopback() async {
        guard PrivateNetwork.helper(.iroh) != nil else {
            return note("SKIP iroh: loopback (no pluck-iroh in this build's Contents/Helpers)")
        }
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("IrohTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, office = Tunnel.irohOffice
        let home = Tunnel(.home, .iroh), stranger = Tunnel(.home, .iroh)
        office.testSettings = ["local": true, "keyFile": base.appendingPathComponent("office.key").path]
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            server.stop()
            home.stop()
            stranger.stop()
            office.testSettings = nil
            client.irohTunnel = Tunnel.irohHome
            try? fm.removeItem(at: base)
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        do {
            office.setAllow([])
            try await office.start()
        } catch {
            return check("iroh: office helper starts offline", false, error.localizedDescription)
        }
        // A helper that stops before carrying anything (here: its key can't be saved) says why.
        let broken = Tunnel(.home, .iroh)
        broken.testSettings = ["local": true, "keyFile": base.appendingPathComponent("missing/home.key").path]
        do {
            try await broken.start(office: String(repeating: "ab", count: 32))
            check("iroh: a helper that can't start says why", false)
        } catch {
            check("iroh: a helper that can't start says why", (error as? PrivateNetwork.Failure).map { if case .helper = $0 { true } else { false } } == true,
                  error.localizedDescription)
        }
        broken.stop()
        let link: URL
        do { link = try await server.invite() } catch { return check("iroh: invitation made", false, error.localizedDescription) }
        guard let invitation = PrivateNetwork.Invitation(link: link.absoluteString), case .iroh(let node, _, let expires) = invitation.way else {
            return check("iroh: invitation made", false, link.absoluteString)
        }
        check("iroh: invitation works for 15 minutes", abs(expires.timeIntervalSinceNow - 900) < 5)

        // The office's helper restarted (a relay change, say): the invitation still lets a Mac in.
        UserDefaults.standard.set(true, forKey: "PluckScreenshotNetwork")
        server.restartNetwork()
        UserDefaults.standard.removeObject(forKey: "PluckScreenshotNetwork")
        for _ in 0..<200 {
            if case .running = office.state, !office.bound.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard case .running(_, let restarted) = office.state, restarted == node,
              let port = office.bound.first(where: { $0.hasPrefix("0.0.0.0:") })?.split(separator: ":").last else {
            return check("iroh: office helper restarts with the same id", false, "\(office.state) \(office.bound) \(server.networkProblem ?? "")")
        }
        for (tunnel, name) in [(home, "home"), (stranger, "stranger")] {
            tunnel.testSettings = ["local": true, "keyFile": base.appendingPathComponent("\(name).key").path, "officeAddrs": ["127.0.0.1:\(port)"]]
        }

        // A stranger dials first, with a damaged key: it gets a new one, and is let in only to try
        // pairing. Wrong codes and a node id that isn't its own use nothing up for the invitee.
        try? Data([1, 2, 3]).write(to: base.appendingPathComponent("stranger.key"))
        do {
            try await stranger.start(office: node)
        } catch {
            return check("iroh: a stranger's helper starts", false, error.localizedDescription)
        }
        let renewed = (try? Data(contentsOf: base.appendingPathComponent("stranger.key")))?.count == 32
            && fm.fileExists(atPath: base.appendingPathComponent("stranger.key.damaged").path)
        check("iroh: a damaged key is set aside and replaced", renewed)
        guard let strangerListen = stranger.listen, case .running(_, let strangerID) = stranger.state else {
            return check("iroh: a stranger's helper starts", false, "\(stranger.state)")
        }
        for _ in 0...(OfficeLink.pairingTries * 2) {
            try? await client.pair(.address(strangerListen), code: OfficeLink.newPairingCode(), iroh: (node, nil, strangerID))
        }
        do {
            try await client.pair(.address(strangerListen), code: invitation.code, iroh: (node, nil, String(repeating: "cd", count: 32)))
            check("iroh: a node id that isn't the sender's is refused", false)
        } catch {
            check("iroh: a node id that isn't the sender's is refused", server.devices.isEmpty && client.office == nil)
        }

        client.irohTunnel = home
        do {
            try await client.join(invitation)
        } catch {
            return check("iroh: joined and paired through pluck-iroh", false, error.localizedDescription)
        }
        guard case .running(_, let mine) = home.state, let device = server.devices.first else {
            return check("iroh: joined and paired through pluck-iroh", false, "no device")
        }
        check("iroh: joined and paired through pluck-iroh", client.office?.iroh == invitation.way.node && device.iroh == mine,
              "\(device.iroh ?? "-") vs \(mine)")
        do {
            let status = try await client.status()
            check("iroh: a request goes through the link", !status.office.isEmpty)
        } catch {
            check("iroh: a request goes through the link", false, error.localizedDescription)
        }
        for _ in 0..<20 where home.links.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        check("iroh: the link reports a direct path", home.links[invitation.way.node ?? ""]?.direct == true, "\(home.links)")
        for _ in 0..<30 where !stranger.refused { try? await Task.sleep(for: .milliseconds(100)) }
        check("iroh: once the invitation is used, the stranger let in to try is cut off", stranger.refused)

        // The same link a second time, from another Mac: turned away by the office's helper.
        client.irohTunnel = stranger
        do {
            try await client.join(invitation)
            check("iroh: a used link is refused", false)
        } catch {
            check("iroh: a used link is refused, saying so", (error as? PrivateNetwork.Failure).map { if case .inviteUsed = $0 { true } else { false } } == true,
                  "\(error.localizedDescription) \(stranger.state) \(stranger.listen ?? "-") refused \(stranger.refused) \(stranger.warning ?? "")")
        }
        check("iroh: still one paired Mac", server.devices.count == 1)
        do {
            try await client.pair(.address("127.0.0.1"), code: invitation.code)
            check("iroh: the link's code works once", false)
        } catch {
            check("iroh: the link's code works once", true)
        }

        // Removed on the office: cut off at once.
        client.irohTunnel = home
        server.remove(device)
        try? await Task.sleep(for: .milliseconds(300))
        do {
            _ = try await client.status()
            check("iroh: a removed Mac is cut off", false)
        } catch {
            check("iroh: a removed Mac is cut off", true)
        }
        check("iroh: the office's helper turned it away", home.refused)
    }
}

private extension PrivateNetwork.Invitation.Way {
    var node: String? {
        if case .iroh(let node, _, _) = self { return node }
        return nil
    }
}
