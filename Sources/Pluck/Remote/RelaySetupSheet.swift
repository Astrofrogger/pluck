import AppKit
import SwiftUI

/// Macs › Connection › Set up a relay: the guide (domain, router), the relay put on a TrueNAS through its API or a
/// command for Proxmox, and Test relay. Pluck never changes router or NAS network settings.
struct RelaySetupSheet: View {
    /// Called with the relay's address when the owner uses it.
    let use: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = RelaySetup.saved?.kind ?? .truenas
    @State private var hostname = RelaySetup.saved?.hostname ?? ""
    @State private var contact = RelaySetup.saved?.contact ?? ""
    @State private var certificate = RelaySetup.saved?.certificate ?? .automatic
    @State private var address = RelaySetup.saved?.address ?? ""
    @State private var apiKey = ""
    @State private var dnsToken = ""
    @State private var fingerprint: String?
    @State private var working = false
    @State private var message: String?
    @State private var speed: Double?

    private var setup: RelaySetup.Setup {
        .init(kind: kind, address: address.trimmingCharacters(in: .whitespaces), hostname: hostname.trimmingCharacters(in: .whitespaces).lowercased(),
              contact: contact.trimmingCharacters(in: .whitespaces), certificate: kind == .proxmox ? .automatic : certificate)
    }
    private var complete: Bool { RelaySetup.isHostname(setup.hostname) && RelaySetup.isEmail(setup.contact) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: Text("Your own relay"),
                       subtitle: Text("For when Macs can’t connect directly. Only your paired Macs and office Macs may use it.")) {
                if working { PlumSpinner() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Point a (sub)domain at the office’s public IP (or a dynamic DNS name).")
                Text("2. On the router, forward 443 (TCP) and 7842 (UDP) to the server. Best on a network (VLAN) of its own.")
                Text("Pluck never changes your router or NAS network settings.").foregroundStyle(Design.Studio.textQuiet)
            }
            .font(Design.Studio.hint).fixedSize(horizontal: false, vertical: true)
            Picker("Server", selection: $kind) {
                Text(verbatim: "TrueNAS").tag(RelaySetup.Kind.truenas)
                Text(verbatim: "Proxmox").tag(RelaySetup.Kind.proxmox)
            }
            .pickerStyle(.segmented).labelsHidden()
            field("Domain", $hostname, prompt: "relay.example.com")
            field("E-mail", $contact, prompt: "you@example.com")
                .help("For the free certificate from Let’s Encrypt")
            if kind == .truenas { truenas } else { proxmox }
            if let message {
                Text(message).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button("Test relay") { test() }
                    .buttonStyle(StudioFlatButtonStyle(height: 32))
                    .disabled(!complete || working)
                    .help("Sends data between two test connections through the relay only and measures it")
                if let speed { Text("\(Int(speed.rounded())) Mbit/s").font(Design.Studio.body).foregroundStyle(Design.Studio.good) }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(StudioFlatButtonStyle(height: 32))
                Button("Use this relay") { use(setup.url); dismiss() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(!complete)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .background(Design.Studio.panel)
    }

    private func field(_ label: LocalizedStringKey, _ text: Binding<String>, prompt: String, secure: Bool = false) -> some View {
        StudioField(label: label) {
            Group {
                if secure { SecureField(label, text: text, prompt: Text(verbatim: prompt)) } else { TextField(label, text: text, prompt: Text(verbatim: prompt)) }
            }
            .textFieldStyle(.plain).font(Design.Studio.body).anywhereInput()
        }
    }

    @ViewBuilder
    private var truenas: some View {
        field("NAS", $address, prompt: "nas.local")
        if TrueNASKeychain.load(setup.address) == nil { field("API key", $apiKey, prompt: "", secure: true) }
        Picker("Certificate", selection: $certificate) {
            Text("Automatic (port 443)").tag(RelaySetup.Certificate.automatic)
            Text(verbatim: "DNS (Cloudflare)").tag(RelaySetup.Certificate.dns)
        }
        .font(Design.Studio.body)
        if certificate == .dns { field("DNS token", $dnsToken, prompt: "", secure: true) }
        if let fingerprint {
            HStack {
                Text("Certificate SHA-256: \(fingerprint)").font(Design.Studio.hint).lineLimit(2).textSelection(.enabled)
                Button("It matches") {
                    TrueNASKeychain.setPin(fingerprint, for: setup.address)
                    self.fingerprint = nil
                    deploy()
                }
                .buttonStyle(StudioFlatButtonStyle(height: 28))
            }
        }
        HStack {
            Spacer()
            Button(RelaySetup.saved?.kind == .truenas ? "Update relay" : "Set up on the NAS") { deploy() }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .disabled(!complete || setup.address.isEmpty || working)
        }
    }

    @ViewBuilder
    private var proxmox: some View {
        if let image = RelaySetup.image, complete {
            let command = RelaySetup.proxmoxCommand(image: image, setup: setup, allow: RelaySetup.allowlist())
            Text("Run in a Docker container or VM on the Proxmox server. When Macs are added or removed, run the new command again.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: command).font(.system(size: 11, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                .padding(8).background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius))
            HStack {
                Spacer()
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    var saved = setup
                    saved.pushed = RelaySetup.allowlist()
                    RelaySetup.saved = saved
                }
                .buttonStyle(StudioFlatButtonStyle(height: 32))
            }
        } else if RelaySetup.image == nil {
            Text("This Pluck version has no relay image yet.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        }
    }

    private func deploy() {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await RelaySetup.deploy(setup, key: apiKey.isEmpty ? nil : apiKey, dnsToken: dnsToken.isEmpty ? nil : dnsToken)
                apiKey = ""
                dnsToken = ""
                message = String(localized: "The relay is set up on the NAS. The certificate can take a minute; then test it.")
            } catch let unconfirmed as TrueNASClient.Unconfirmed {
                fingerprint = unconfirmed.fingerprint
                message = String(localized: "Check that this is your NAS’s certificate (System › Certificates on the NAS).")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func test() {
        working = true
        speed = nil
        message = nil
        Task {
            defer { working = false }
            do { speed = try await RelaySetup.measure(setup.url) } catch { message = error.localizedDescription }
        }
    }
}
