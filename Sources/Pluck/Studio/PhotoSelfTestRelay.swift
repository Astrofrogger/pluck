import Foundation

extension PhotoSelfTest {
    /// The office's own relay (part of remoteiroh): the TrueNAS compose filled in (placeholders, the DNS block, a pinned
    /// image, hardening, only 443/tcp and 7842/udp), the Proxmox command, the allowlist, and a relay-only round trip
    /// through a local iroh-relay (--dev, when one was built into the scratch folder).
    static func relayTest() async {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let template = RelaySetup.template ?? (try? String(contentsOf: source.appendingPathComponent("Helpers/PluckRelay/docker/truenas-compose.yml"), encoding: .utf8)) else {
            return check("relay: the compose template", false)
        }
        let id = String(repeating: "ab", count: 32), other = String(repeating: "cd", count: 32)
        let image = "ghcr.io/example/pluck-relay@sha256:" + String(repeating: "0", count: 64)
        var setup = RelaySetup.Setup(kind: .truenas, address: "nas.local", hostname: "relay.example.com", contact: "owner@example.com")
        do {
            let plain = try RelaySetup.compose(template, image: image, setup: setup, allow: [id, other], dnsToken: nil)
            check("relay: compose filled, nothing left over, pinned image", !plain.contains("{{") && plain.contains("image: \"\(image)\"") && !plain.contains(":latest"))
            check("relay: compose is hardened", ["user: \"568:568\"", "read_only: true", "cap_drop: [ALL]", "no-new-privileges:true", "tmpfs:", "mem_limit:", "cpus:"].allSatisfy(plain.contains))
            check("relay: only 443/tcp and 7842/udp, no port 80, no dataset", plain.contains("\"443:8443/tcp\"") && plain.contains("\"7842:7842/udp\"")
                  && !plain.contains("\"80:") && !plain.contains("/mnt/") && plain.contains("PLUCK_RELAY_ALLOW: \"\(id),\(other)\""))
            check("relay: no DNS sidecar unless asked", !plain.contains("lego") && !plain.contains("CLOUDFLARE"))
            setup.certificate = .dns
            let dns = try RelaySetup.compose(template, image: image, setup: setup, allow: [id], dnsToken: "tok\"en")
            check("relay: the DNS block carries the token, escaped", dns.contains("CLOUDFLARE_DNS_API_TOKEN: \"tok\\\"en\"") && dns.contains("PLUCK_RELAY_TLS: \"files\""))
        } catch {
            check("relay: compose", false, "\(error)")
        }
        check("relay: refused without an allowlist or with a bad domain",
              (try? RelaySetup.compose(template, image: image, setup: setup, allow: [], dnsToken: "x")) == nil
              && (try? RelaySetup.compose(template, image: image, setup: .init(kind: .truenas, hostname: "bad host", contact: "a@example.com"), allow: [id], dnsToken: nil)) == nil
              && (try? RelaySetup.compose(template, image: "ghcr.io/example/pluck-relay:latest", setup: setup, allow: [id], dnsToken: "x")) == nil)
        let sha = String(repeating: "ab", count: 32)
        let proxmox = RelaySetup.Setup(kind: .proxmox, hostname: "Relay.Example.com", contact: "owner+relay@example.com")
        let command = RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: sha, image: image, setup: proxmox, allow: [id, other]) ?? ""
        check("relay: the Proxmox command fetches the script, checks its SHA-256, then runs it", command.contains("releases/download/v4.0.7/pluck-relay-proxmox.sh")
              && command.contains("echo \"\(sha)  pluck-relay-proxmox.sh\" | sha256sum -c -") && command.contains("&& bash pluck-relay-proxmox.sh --hostname relay.example.com")
              && command.contains("--contact 'owner+relay@example.com' --tls acme") && command.contains("--allow \(id),\(other)") && !command.contains("secrets"), command)
        var dnsSetup = proxmox
        dnsSetup.certificate = .dns
        let dnsCommand = RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: sha, image: image, setup: dnsSetup, allow: [id]) ?? ""
        check("relay: Proxmox DNS certificates read the token from a root-only file, never the command line",
              dnsCommand.contains("--tls files") && dnsCommand.contains("--secrets-file \(RelaySetup.proxmoxSecrets)") && !dnsCommand.contains("TOKEN"), dnsCommand)
        check("relay: no Proxmox command with a value the script would refuse",
              RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: "x", image: image, setup: proxmox, allow: [id]) == nil
              && RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: sha, image: "ghcr.io/example/pluck-relay:latest", setup: proxmox, allow: [id]) == nil
              && RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: sha, image: image, setup: .init(kind: .proxmox, hostname: "relay.example.com", contact: "o'k;x@example.com"), allow: [id]) == nil
              && RelaySetup.proxmoxCommand(tag: "v4.0.7", sha256: sha, image: image, setup: proxmox, allow: []) == nil)
        // The script itself: shell syntax, hardening, no port 80, the token never an argument.
        if let script = try? String(contentsOf: source.appendingPathComponent("Helpers/PluckRelay/docker/proxmox/pluck-relay-proxmox.sh"), encoding: .utf8) {
            let syntax = Process()
            syntax.executableURL = URL(fileURLWithPath: "/bin/bash")
            syntax.arguments = ["-n", source.appendingPathComponent("Helpers/PluckRelay/docker/proxmox/pluck-relay-proxmox.sh").path]
            try? syntax.run()
            syntax.waitUntilExit()
            check("relay: the Proxmox script parses and is hardened", syntax.terminationStatus == 0
                  && ["--unprivileged 1", "--user 568:568", "--read-only", "--cap-drop ALL", "no-new-privileges:true", "-p 443:8443/tcp", "-p 7842:7842/udp",
                      "--perms 0600", "--dns-token is not accepted"].allSatisfy(script.contains) && !script.contains("-p 80"))
        } else {
            note("SKIP relay: the Proxmox script (no source tree here)")
        }
        check("relay: the allowlist holds only node ids", RelaySetup.allowlist().allSatisfy(PrivateNetwork.isNodeID))
        let testIDs = (try? RelaySetup.testKeys().map(\.id)) ?? []
        check("relay: the test's two kept keys are in the allowlist (same ids each time)", testIDs.count == 2 && testIDs.allSatisfy(PrivateNetwork.isNodeID)
              && Set(testIDs).isSubset(of: RelaySetup.allowlist()) && testIDs == ((try? RelaySetup.testKeys().map(\.id)) ?? []))

        // A relay-only round trip through a local iroh-relay (http on this Mac).
        let binary = source.deletingLastPathComponent().appendingPathComponent("x410/relay/bin/iroh-relay")
        guard FileManager.default.isExecutableFile(atPath: binary.path), PrivateNetwork.helper(.iroh) != nil else {
            return note("SKIP relay: round trip (no iroh-relay at \(binary.path) or no pluck-iroh)")
        }
        let relay = Process()
        relay.executableURL = binary
        relay.arguments = ["--dev"]
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        do { try relay.run() } catch { return check("relay: local iroh-relay starts", false, "\(error)") }
        defer { relay.terminate() }
        try? await Task.sleep(for: .seconds(2))
        UserDefaults.standard.set(true, forKey: "PluckScreenshotNetwork")
        defer { UserDefaults.standard.removeObject(forKey: "PluckScreenshotNetwork") }
        do {
            let speed = try await RelaySetup.measure("http://localhost:3340", bytes: 4 << 20)
            check("relay: data goes through the relay only, and is measured", speed > 0, "\(speed) Mbit/s")
            note("relay: local relay-only speed \(Int(speed)) Mbit/s")
        } catch {
            check("relay: data goes through the relay only", false, error.localizedDescription)
        }
    }
}
