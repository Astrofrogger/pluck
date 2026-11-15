import SwiftUI

/// Setting up a TrueNAS SCALE box as an always-on review host, step by step (spec §12; the helper's
/// docker/docker-compose.yml and README.md). All of the steps' wording and the compose text live here.
enum ReviewNASGuide {
    static let image = "pluck-review-host:latest"

    enum Second: String, CaseIterable { case none, nfs, smb }

    /// The template's values (placeholders are documentation addresses, never real ones).
    struct Choices {
        var data = "/mnt/tank/apps/pluck-review"
        var media = "/mnt/tank/media"
        var mediaID = "nas1"
        var second = Second.none
        var secondID = "nas2"
        var secondAddress = "192.0.2.20"
        var secondPath = "/mnt/tank/media"
        var secondShare = "media"
        var lanAddress = "192.0.2.10"
        var syncPort = 8790
        var adminPort = 8791
        var key = DeliverKeys.base64url(DeliverKeys.random(32))
        // §13: reachable from anywhere over iroh, an optional uploads root (its own dataset, read-write), relays.
        var iroh = true
        var uploads = ""
        var uploadsID = "renders"
        var extra: [String: String] = [:]
    }

    /// docker-compose.yml with the choices filled in (SMB's user and password stay in the app's env file).
    static func compose(_ c: Choices) -> String {
        var command = ["--media", "\"\(c.mediaID)=/media/\(c.mediaID)\""]
        var volumes = ["\"\(c.data):/data\"", "\"\(c.media):/media/\(c.mediaID):ro\""]
        var environment = ["PLUCK_HOST_KEY": c.key].merging(c.extra) { $1 }
        if c.iroh { environment["PLUCK_IROH"] = "1" }
        if !c.uploads.isEmpty {
            volumes.append("\"\(c.uploads):/uploads/\(c.uploadsID)\"")
            environment["PLUCK_UPLOADS"] = "\(c.uploadsID)=/uploads/\(c.uploadsID)"
        }
        if c.second != .none {
            command += ["--media", "\"\(c.secondID)=/media/\(c.secondID)\""]
            volumes.append("\"media2:/media/\(c.secondID):ro\"")
        }
        command += ["--listen", "\"\(c.lanAddress):\(c.syncPort)\"", "--admin", "\"\(c.lanAddress):\(c.adminPort)\""]
        var text = """
        name: pluck-review
        services:
          pluck-review:
            image: \(image)
            restart: unless-stopped
            network_mode: host
            user: "568:568"
            read_only: true
            cap_drop: [ALL]
            security_opt: ["no-new-privileges:true"]
            tmpfs: ["/tmp:size=64m"]
            environment:
        \(environment.sorted { $0.key < $1.key }.map { "      \($0.key): \"\($0.value)\"" }.joined(separator: "\n"))
            command:
        \(command.map { "      - \($0)" }.joined(separator: "\n"))
            volumes:
        \(volumes.map { "      - \($0)" }.joined(separator: "\n"))
            pids_limit: 256
            mem_limit: 3g
            cpus: 2.0

        """
        switch c.second {
        case .none: break
        case .nfs:
            text += """
            volumes:
              media2:
                driver: local
                driver_opts:
                  type: nfs
                  o: "addr=\(c.secondAddress),ro,nfsvers=4,soft,timeo=150"
                  device: ":\(c.secondPath)"

            """
        case .smb:
            text += """
            volumes:
              media2:
                driver: local
                driver_opts:
                  type: cifs
                  o: "addr=\(c.secondAddress),ro,username=${MEDIA_2_SMB_USER},password=${MEDIA_2_SMB_PASSWORD},vers=3.0,uid=568,gid=568,file_mode=0444,dir_mode=0555"
                  device: "//\(c.secondAddress)/\(c.secondShare)"

            """
        }
        return text
    }

    /// The numbered steps: a title, a short line, and text to copy where there is some.
    static func steps(_ c: Choices) -> [(title: String, line: String, copy: String?)] {
        var steps: [(String, String, String?)] = [
            (String(localized: "Make a data dataset"),
             String(localized: "Datasets › Add: one for the host's own data. Give the apps user (568) read and write there, and read on your media."), c.data),
        ]
        if c.second != .none {
            steps.append((String(localized: "Share the second NAS"),
                          c.second == .nfs
                            ? String(localized: "On the other NAS: Shares › NFS › Add, its media folder, Read only on, and only this NAS's address under Networks.")
                            : String(localized: "On the other NAS: an SMB share of its media with a user that can only read it. Put that user and password in the app's env file."),
                          c.second == .nfs ? "\(c.lanAddress)/32" : nil))
        }
        steps += [
            (String(localized: "Install the app"),
             String(localized: "Apps › Discover Apps › ⋮ › Install via YAML. Paste this. The image comes from Pluck's docker folder, built on the NAS or pushed to your own registry."),
             compose(c)),
            (String(localized: "Start it"), String(localized: "Its log shows the address it listens on and its certificate fingerprint."), nil),
            (String(localized: "Connect"),
             String(localized: "Type the NAS's address below and choose Connect. Pluck knows the host key already; check that the fingerprint it shows matches the log, then confirm."), nil),
            (String(localized: "Admin page"),
             String(localized: "From a computer on your network, open this. The browser warns once. The first visit asks for the host key and a new password (10 characters or more)."),
             "https://\(c.lanAddress):\(c.adminPort)"),
        ]
        return steps.map { (title: $0.0, line: $0.1, copy: $0.2) }
    }
}

/// The guide as a sheet: choices at the top, the numbered steps, then Connect.
struct ReviewNASGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choices = ReviewNASGuide.Choices(extra: DeliverRelay.shared.environment)
    @State private var name = "NAS"
    @State private var pairing = ""
    @State private var state: String?
    @State private var connecting = false
    /// A first connect's certificate, waiting for the owner to compare it with the NAS's log.
    @State private var unconfirmed: (host: UUID, fingerprint: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up a NAS Host").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        StudioField(label: "This NAS") {
                            TextField("192.0.2.10", text: $choices.lanAddress).settingField(width: 200)
                            TextField("8790", value: $choices.syncPort, format: .number.grouping(.never)).settingField(width: 60)
                        }
                        StudioField(label: "Data") { TextField("/mnt/tank/apps/pluck-review", text: $choices.data).settingField(width: 300) }
                        StudioField(label: "Media") {
                            TextField("/mnt/tank/media", text: $choices.media).settingField(width: 230)
                            TextField("nas1", text: $choices.mediaID).settingField(width: 66).help("Its short name; links refer to it, so keep it")
                        }
                        StudioField(label: "Second NAS") {
                            StudioSegmented(options: [(ReviewNASGuide.Second.none, "None"), (.nfs, "NFS"), (.smb, "SMB")], selection: $choices.second)
                        }
                        if choices.second != .none {
                            StudioField(label: "Its address") { TextField("192.0.2.20", text: $choices.secondAddress).settingField(width: 300) }
                            if choices.second == .nfs {
                                StudioField(label: "Its folder") { TextField("/mnt/tank/media", text: $choices.secondPath).settingField(width: 300) }
                            } else {
                                StudioField(label: "Its share") { TextField("media", text: $choices.secondShare).settingField(width: 300) }
                            }
                            StudioField(label: "Its name") { TextField("nas2", text: $choices.secondID).settingField(width: 300) }
                        }
                        StudioField(label: "Uploads") {
                            TextField("Optional: /mnt/tank/renders", text: $choices.uploads).settingField(width: 230).help("Its own dataset: Pluck can write there")
                            TextField("renders", text: $choices.uploadsID).settingField(width: 66)
                        }
                        StudioSwitchRow(title: "Reach it from anywhere (iroh)", isOn: $choices.iroh)
                    }
                    ForEach(Array(ReviewNASGuide.steps(choices).enumerated()), id: \.offset) { number, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: "\(number + 1)").font(Design.Studio.body.weight(.medium)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(Design.Brand.deep, in: .circle)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: step.title).font(Design.Studio.body.weight(.medium)).foregroundStyle(Design.Studio.text)
                                Text(verbatim: step.line).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                                if let copy = step.copy {
                                    HStack(alignment: .top) {
                                        Text(verbatim: copy).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Design.Studio.text).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string) }
                                            .buttonStyle(StudioFlatButtonStyle())
                                    }
                                    .padding(10)
                                    .studioBox()
                                }
                            }
                        }
                    }
                    StudioField(label: "Pairing line") {
                        TextField("Only if the NAS made its own key: pluck-host:…", text: $pairing).settingField(width: 300)
                    }
                    if let unconfirmed {
                        StudioField(label: "Fingerprint") {
                            Text(verbatim: unconfirmed.fingerprint).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Design.Studio.text)
                                .textSelection(.enabled).frame(width: 300, alignment: .leading)
                            Button("Matches the Log") {
                                ReviewPublish.shared.pinned(unconfirmed.fingerprint, host: unconfirmed.host)
                                self.unconfirmed = nil
                                Task { await connect() }
                            }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Name", text: $name).settingField(width: 120)
                Button("Connect") { Task { await connect() } }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .disabled(choices.lanAddress.isEmpty || connecting)
                if connecting { PlumSpinner() }
                if let state { Text(verbatim: state).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 660, height: 660)
        .background(Design.Studio.panel)
    }

    /// Pairs with the host key (the certificate pinned on this first connect), then lists the media roots.
    private func connect() async {
        connecting = true
        defer { connecting = false }
        let publish = ReviewPublish.shared
        let address = "\(choices.lanAddress):\(choices.syncPort)"
        // (Again after confirming: the same host, now pinned.)
        let known = publish.hosts.first { $0.kind == .nas && $0.address == address && $0.pin != nil }
        guard let host = known ?? publish.addNAS(name: name, address: address, pairing: pairing.isEmpty ? choices.key : pairing) else {
            state = String(localized: "That pairing line isn’t complete.")
            return
        }
        if known == nil { publish.setMounts(ReviewPublish.guessMounts(server: choices.lanAddress), host: host.id) }
        do {
            var roots: [String] = []
            try await ReviewHostClient.session(host) { session in
                roots = try await session.ask(["op": "roots"])["roots"] as? [String] ?? []
            }
            let pin = publish.host(host.id)?.pin ?? ""
            state = String(localized: "Connected: \(roots.joined(separator: ", ")) · \(String(pin.prefix(11)))…")
        } catch let error as ReviewHostClient.Unconfirmed where !error.fingerprint.isEmpty {
            unconfirmed = (host.id, error.fingerprint)
            state = String(localized: "Compare the fingerprint with the NAS’s log.")
        } catch {
            state = String(localized: "The NAS didn’t answer. Is the app running?")
        }
    }
}
