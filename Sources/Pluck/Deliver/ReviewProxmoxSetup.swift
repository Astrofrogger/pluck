import SwiftUI

/// The backup host (§13.3) and its Proxmox setup (§13.14): one command to paste into the Proxmox host's shell. It
/// downloads pluck-proxmox.sh from Pluck's own release, checks its SHA-256 (from the signed host-release.json) and
/// only then runs it with the pairing link. No `curl | bash`.
enum DeliverBackup {
    /// `--quality` values: 540p / 720p / 1080p × Low / Medium / High, plus "Same as main".
    static let qualities = ["540-low", "540-medium", "540-high", "720-low", "720-medium", "720-high", "1080-low", "1080-medium", "1080-high", "same"]

    /// kbit/s of video (≤ 30 fps) and audio for a quality.
    static func rates(_ quality: String) -> (video: Int, audio: Int)? {
        let table: [String: (Int, Int)] = ["540-low": (800, 128), "540-medium": (1200, 128), "540-high": (2000, 128),
                                           "720-low": (1500, 128), "720-medium": (2500, 128), "720-high": (4000, 160),
                                           "1080-low": (2500, 128), "1080-medium": (4000, 128), "1080-high": (6000, 160)]
        return table[quality]
    }

    static func title(_ quality: String) -> String {
        guard quality != "same" else { return String(localized: "Same as main") }
        let parts = quality.split(separator: "-")
        let level = ["low": String(localized: "Low"), "medium": String(localized: "Medium"), "high": String(localized: "High")][String(parts.last ?? "")] ?? ""
        return "\(parts.first ?? "")p \(level)"
    }

    /// About how many hours of video fit in `gigabytes` (nil for "same", which copies main's renditions as they are).
    static func hours(_ gigabytes: Int, quality: String) -> Double? {
        guard let rates = rates(quality) else { return nil }
        // (+ the main's 360 copy, kept as it is: 330 + 48 kbit/s.)
        let bytesPerHour = Double(rates.video + rates.audio + 378) * 1000 / 8 * 3600
        return Double(gigabytes) * 1e9 / bytesPerHour
    }

    /// The Proxmox command (every value checked; the link must be a pairing link, nothing that breaks out of its quotes).
    static func command(tag: String, sha256: String, storage: String, size: Int, quality: String, cores: Int, memory: Int,
                        bridge: String, name: String, ip: String?, link: String) -> String? {
        guard tag.wholeMatch(of: #/v[0-9A-Za-z.\-]{1,40}/#) != nil, sha256.wholeMatch(of: #/[0-9a-f]{64}/#) != nil,
              storage.wholeMatch(of: #/[A-Za-z0-9_.\-]{1,64}/#) != nil, bridge.wholeMatch(of: #/[A-Za-z0-9_.\-]{1,32}/#) != nil,
              name.wholeMatch(of: #/[a-z0-9-]{1,32}/#) != nil, (1...10_000).contains(size), (1...64).contains(cores), (512...262_144).contains(memory),
              qualities.contains(quality), link.wholeMatch(of: #/pluck://edit-anywhere/join\?i=[A-Za-z0-9_\-]{1,4000}/#) != nil else { return nil }
        if let ip, ip.wholeMatch(of: #/[0-9.]{7,15}/[0-9]{1,2}(,gw=[0-9.]{7,15})?/#) == nil { return nil }
        return "cd /root && curl -fsSLO https://github.com/Astrofrogger/pluck/releases/download/\(tag)/pluck-proxmox.sh \\\n"
            + "  && echo \"\(sha256)  pluck-proxmox.sh\" | sha256sum -c - \\\n"
            + "  && bash pluck-proxmox.sh --storage \(storage) --size \(size) --quality \(quality) --cores \(cores) --memory \(memory) \\\n"
            + "     --bridge \(bridge) --name \(name) \(ip.map { "--ip \($0) " } ?? "")--pair '\(link)'"
    }

    /// The check code the script prints: the first 8 characters of the backup's node id, grouped ("ABCD-EFGH").
    static func checkCode(_ node: String) -> String {
        let head = String(node.prefix(8)).uppercased()
        return head.count == 8 ? String(head.prefix(4)) + "-" + String(head.suffix(4)) : head
    }
}

/// Max storage and quality, with how much video that holds.
struct DeliverBackupFields: View {
    @Binding var maxStorage: Int
    @Binding var quality: String

    var body: some View {
        StudioField(label: "Max storage") {
            Stepper("\(maxStorage) GB", value: $maxStorage, in: 10...10_000, step: 10).fixedSize()
        }
        StudioField(label: "Quality") {
            Picker(selection: $quality) { ForEach(DeliverBackup.qualities, id: \.self) { Text(verbatim: DeliverBackup.title($0)).tag($0) } } label: { EmptyView() }.fixedSize()
            if let hours = DeliverBackup.hours(maxStorage, quality: quality) {
                Text("About \(Int(hours)) hours of video").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            } else {
                Text("Byte copies of the main host’s review copies").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
    }
}

/// Settings › Review › <NAS> › "Backup host…": where it runs, max storage and quality; the invite comes from the main.
struct DeliverBackupSheet: View {
    let main: Deliver.Host
    enum Kind: String { case truenas, proxmox, docker }
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.proxmox
    @State private var maxStorage = 50
    @State private var quality = "1080-low"
    @State private var storage = "local-lvm"
    @State private var cores = 2
    @State private var memory = 2
    @State private var ip = ""
    @State private var bridge = "vmbr0"
    @State private var name = "pluck-backup"
    @State private var invite: (link: String, expires: Date)?
    @State private var problem: String?
    @State private var truenas = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Host").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            StudioSegmented(options: [(Kind.truenas, LocalizedStringKey("TrueNAS")), (.proxmox, LocalizedStringKey("Proxmox")), (.docker, LocalizedStringKey("Another Docker host"))],
                            selection: $kind).fixedSize()
            DeliverBackupFields(maxStorage: $maxStorage, quality: $quality)
            if kind == .proxmox {
                StudioField(label: "Storage") { TextField("local-lvm", text: $storage).settingField(width: 160) }
                StudioField(label: "CPUs, RAM") {
                    Stepper("\(cores)", value: $cores, in: 1...16).fixedSize()
                    Stepper("\(memory) GB", value: $memory, in: 1...32).fixedSize()
                }
                StudioField(label: "IP") { TextField("DHCP", text: $ip).settingField(width: 160) }
                StudioField(label: "Bridge") { TextField("vmbr0", text: $bridge).settingField(width: 160) }
                StudioField(label: "Name") { TextField("pluck-backup", text: $name).settingField(width: 160) }
            }
            if let invite {
                Text("Anyone with this link in the next 15 minutes can browse your NAS media").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                Text("Until \(invite.expires.formatted(date: .omitted, time: .shortened))").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                if let text = output(invite.link) {
                    Text(verbatim: text).font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.text).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius))
                    Button("Copy") { DeliverLinkShare.copy(text) }.buttonStyle(StudioFlatButtonStyle())
                } else if kind == .proxmox {
                    Text("No signed host release for this version of Pluck yet.").font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
                }
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button(kind == .truenas ? "Set Up on TrueNAS…" : "Make Invitation") { Task { await makeInvite() } }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
        .background(Design.Studio.panel)
        .sheet(isPresented: $truenas) {
            ReviewTrueNASSetupSheet(setup: {
                let setup = TrueNASSetup()
                setup.role = .backup
                setup.backupMax = maxStorage
                setup.quality = quality
                setup.mainLink = invite?.link ?? ""
                return setup
            }())
        }
    }

    /// What to paste: the Proxmox command, or for another Docker host the environment lines.
    private func output(_ link: String) -> String? {
        switch kind {
        case .truenas: return nil
        case .proxmox:
            guard let release = DeliverHostUpdate.shared.release, let sha = release.assets["pluck-proxmox.sh"] else { return nil }
            return DeliverBackup.command(tag: "v" + DeliverHostUpdate.pluckVersion, sha256: sha, storage: storage, size: maxStorage + 8, quality: quality,
                                         cores: cores, memory: memory * 1024, bridge: bridge, name: name, ip: ip.isEmpty ? nil : ip, link: link)
        case .docker:
            var env = ["PLUCK_ROLE": "backup", "PLUCK_IROH": "1", "PLUCK_MAIN_LINK": link, "PLUCK_BACKUP_MAX": "\(maxStorage)G", "PLUCK_BACKUP_QUALITY": quality]
            env.merge(DeliverRelay.shared.environment) { $1 }
            return env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private func makeInvite() async {
        do {
            let answer = try await ReviewHostClient.ask(main, ["op": "invite", "role": "backup"])
            guard let link = answer["link"] as? String else { throw Deliver.Failure("internal") }
            invite = (link, (answer["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now.addingTimeInterval(900))
            problem = nil
            if kind == .truenas { truenas = true }
        } catch {
            problem = String(localized: "\(main.name) didn’t answer.")
        }
    }
}
