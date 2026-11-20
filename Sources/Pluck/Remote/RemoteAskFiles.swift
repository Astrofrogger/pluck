import AppKit
import Darwin
import Foundation
import SwiftUI

/// "Ask for Files" (plan 2026-11-20 §2): a link anyone can upload to, whose files land straight in a folder of a share on
/// the NAS. The office Mac makes it through its own Deliver connection to the NAS's review server: a link with no assets
/// and `uploads.into` = the folder as that server's media root has it. Bytes go browser → NAS (the helper's resumable
/// upload path); the editor's Mac is never involved. The helper puts the file in the folder itself when that root was
/// started droppable (`--drop`); otherwise it stays in the server's quarantine and an office Mac that has the folder
/// mounted moves it over SMB (a claim file first, so only one does). It never overwrites: "Name 2.mov".
@MainActor
@Observable
final class RemoteAskFiles {
    static let shared = RemoteAskFiles()
    nonisolated static let key = "editAnywhereAskedLinks"
    /// A claim not finished for this long is from a Mac that went away: another one takes the move over.
    nonisolated static let staleClaim: TimeInterval = 30 * 60

    struct Arrival: Codable, Hashable {
        var id: String
        var name: String
        var size: Int64
        var at: Date
        /// Where it is now, as the NAS has it ("<root>/<folder>/<name>"); nil while it waits to be moved.
        var placed: String?
    }

    struct Asked: Codable, Identifiable, Hashable {
        var id: UUID               // the Deliver link
        var device: UUID?          // the home Mac it was made for (nil: on this Mac)
        var share: String
        var path: String
        var title: String
        var host: UUID
        var root: String
        var folder: String
        var url: String
        var expires: Date?
        var arrivals: [Arrival] = []
    }

    private(set) var asked: [Asked] = []
    /// Uploads being moved now (ids).
    @ObservationIgnored private var moving: Set<String> = []

    private init() {
        asked = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Asked].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(asked) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static var needsServer: String { String(localized: "Needs Pluck’s review server on the NAS that holds this folder.") }

    // MARK: - Actions for paired Macs

    static func register() {
        // {share, path, name, password, days, maxBytes, types} → {url, id}: needs Editor in that folder.
        OfficeActions.register("askFiles") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"])
            let path = try OfficeActions.text(arguments["path"], empty: true)
            let folder = try OfficeActions.require(\.render, device, share: place, path: path)
            let made = try await shared.make(folder: folder, share: place.id, path: RemoteEditHost.relative(folder, in: place.root),
                                             title: try OfficeActions.text(arguments["name"] ?? "", 200, empty: true),
                                             password: arguments["password"] as? String, days: arguments["days"] as? Int ?? 14,
                                             maxBytes: (arguments["maxBytes"] as? NSNumber)?.int64Value ?? Deliver.ShareLink.Uploads().maxBytes,
                                             types: arguments["types"] as? [String], device: device.id)
            return ["url": made.url, "id": made.id.uuidString]
        }
        // → {links: [{id, title, url, expires, arrivals: [{name, size, at, placed}]}]}: this Mac's own.
        OfficeActions.register("askFilesList") { _, device in
            ["links": shared.asked.filter { $0.device == device.id }.map(summary)]
        }
    }

    static func summary(_ asked: Asked) -> [String: Any] {
        ["id": asked.id.uuidString, "title": asked.title, "url": asked.url, "path": asked.path, "share": asked.share,
         "expires": asked.expires?.timeIntervalSince1970 ?? 0,
         "arrivals": asked.arrivals.map { ["name": $0.name, "size": $0.size, "at": $0.at.timeIntervalSince1970, "placed": $0.placed != nil] }]
    }

    // MARK: - Making a link

    /// A folder here as a NAS review server has it: the server, its media root and the folder inside it.
    static func nasPlace(_ folder: URL) -> (host: Deliver.Host, root: String, folder: String)? {
        let probe = folder.appendingPathComponent("x").path
        for host in ReviewPublish.shared.hosts where host.kind == .nas && host.role != "backup" {
            guard let reference = ReviewPublish.reference(probe, on: host), reference.hasSuffix("/x") else { continue }
            let parts = reference.dropLast(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let root = parts.first, !root.isEmpty, !parts.contains("..") else { continue }
            return (host, root, parts.dropFirst().joined(separator: "/"))
        }
        return nil
    }

    func make(folder: URL, share: String, path: String, title: String, password: String?, days: Int, maxBytes: Int64, types: [String]?,
              device: UUID?) async throws -> (url: String, id: UUID) {
        guard let place = Self.nasPlace(folder) else { throw OfficeLink.Failure.office(Self.needsServer) }
        let store = DeliverStore.shared
        let projectName = String(localized: "Ask for Files")
        let project = try store.projects.first { $0.name == projectName } ?? store.newProject(projectName)
        let name = title.isEmpty ? folder.lastPathComponent : title
        let expires = days > 0 ? Date.now.addingTimeInterval(Double(min(days, 365)) * 86_400) : nil
        let link = try store.newLink(scope: .assets([], project: project.id), title: name, expires: expires,
                                     password: password?.isEmpty == false ? password : nil)
        let allowed = Deliver.ShareLink.Uploads().types
        store.updateLink(link.id) { link in
            link.uploads = .init(folder: nil, maxBytes: max(1, min(maxBytes, Deliver.ShareLink.Uploads().maxBytes * 10)),
                                 types: types?.filter(allowed.contains).nilIfEmpty ?? allowed,
                                 into: .init(root: place.root, folder: place.folder))
        }
        ReviewPublish.shared.problem = nil
        await ReviewPublish.shared.publish(.project(project.id), to: place.host)
        if let problem = ReviewPublish.shared.problem {
            store.deleteLink(link.id)
            throw OfficeLink.Failure.office(problem)
        }
        guard let url = store.url(link) else { throw OfficeLink.Failure.office(String(localized: "The link couldn’t be made.")) }
        asked.append(Asked(id: link.id, device: device, share: share, path: path, title: name, host: place.host.id, root: place.root,
                           folder: place.folder, url: url, expires: expires))
        save()
        return (url, link.id)
    }

    // MARK: - Arrivals

    /// Uploads to Ask for Files links in a host's log: noted on their link, and the ones the NAS couldn't put in their
    /// folder (a read-only root) moved there from this Mac when it has that folder.
    func arrived(_ entries: [[String: Any]], host: Deliver.Host) {
        for entry in entries {
            guard let upload = entry["upload"] as? [String: Any], upload["for"] as? String == "asset", let into = upload["into"] as? [String: Any],
                  let id = upload["id"] as? String, let link = (upload["link"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            let placed = upload["placed"] as? String
            let name = upload["name"] as? String ?? ""
            if let index = asked.firstIndex(where: { $0.id == link }), !asked[index].arrivals.contains(where: { $0.id == id }) {
                asked[index].arrivals.append(Arrival(id: id, name: name, size: (upload["size"] as? NSNumber)?.int64Value ?? 0, at: .now, placed: placed))
                save()
            }
            guard placed == nil, let path = upload["path"] as? String, path.hasPrefix("uploads/"), !path.split(separator: "/").contains(".."),
                  let root = into["root"] as? String, !moving.contains(id),
                  let target = Self.localFolder(root: root, folder: into["folder"] as? String ?? "", host: host) else { continue }
            let folder = into["folder"] as? String ?? ""
            moving.insert(id)
            let size = (upload["size"] as? NSNumber)?.int64Value ?? 0
            Task {
                defer { moving.remove(id) }
                if let placedName = try? await Self.move(id: id, path: path, name: name, size: size, into: target, host: host),
                   let index = asked.firstIndex(where: { $0.id == link }), let at = asked[index].arrivals.firstIndex(where: { $0.id == id }) {
                    asked[index].arrivals[at].placed = [root, folder, placedName].filter { !$0.isEmpty }.joined(separator: "/")
                    save()
                }
            }
        }
    }

    /// Where a NAS media root's folder is on this Mac: under one of its shares that the server maps to that root.
    static func localFolder(root: String, folder: String, host: Deliver.Host) -> URL? {
        func join(_ a: String, _ b: String) -> String { b.isEmpty ? a : a + "/" + b }
        let wanted = join(root, folder)
        for share in OfficeArchive.shared.folders {
            guard let place = nasPlace(share), place.host.id == host.id, place.root == root else { continue }
            let base = join(root, place.folder)
            guard wanted == base || wanted.hasPrefix(base + "/") else { continue }
            let rest = wanted == base ? "" : String(wanted.dropFirst(base.count + 1))
            guard let resolved = try? RemoteEditHost.resolve(rest, in: share), RemoteEditHost.isDirectory(resolved) else { continue }
            return resolved
        }
        return nil
    }

    /// One quarantined upload into its folder: a claim file first (O_EXCL; a stale one is taken over), the bytes fetched
    /// from the server into a hidden file there, put under a free name, then taken off the server.
    static func move(id: String, path: String, name: String, size: Int64, into folder: URL, host: Deliver.Host) async throws -> String? {
        let claim = folder.appendingPathComponent(".pluck-asked-\(id)")
        let made = open(claim.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if made < 0 {
            // Done by another Mac (it says "done"), or being done: left alone unless that Mac went away.
            let said = (try? String(contentsOf: claim, encoding: .utf8)) ?? ""
            let date = (try? claim.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            guard said != "done", Date.now.timeIntervalSince(date) > staleClaim else { return nil }
            try? Data(Host.current().localizedName.map { Array($0.utf8) } ?? []).write(to: claim)
        } else {
            close(made)
        }
        let name = RemoteSendInto.nameOK(name) ? name : "\(id).\((path as NSString).pathExtension)"
        let part = folder.appendingPathComponent(".\(id).pluckpart")
        try? FileManager.default.removeItem(at: part)
        do {
            try await ReviewHostClient.session(host) { session in try await session.get(path, to: part, expected: size) }
            guard RemotePullManager.size(of: part) == size else { throw OfficeLink.Failure.garbled }
            let placed = try RemoteSendInto.place(part, in: folder, name: name)
            try? Data("done".utf8).write(to: claim)
            _ = try? await ReviewHostClient.session(host) { session in _ = try await session.ask(["op": "delete", "path": path]) }
            return placed
        } catch {
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.removeItem(at: claim)
            throw error
        }
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// The sheet for Ask for Files: a name, a password, how long it works, the largest file and what kinds. `ask` makes the
/// link (on the office Mac itself, or asked of it from a home Mac) and gives its address.
struct RemoteAskFilesSheet: View {
    let folderName: String
    let ask: (_ name: String, _ password: String, _ days: Int, _ maxBytes: Int64, _ types: [String]) async throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var days = 14
    @State private var largestGB = 20
    @State private var types: Set<String> = ["video", "audio", "image", "document", "other"]
    @State private var working = false
    @State private var url: String?
    @State private var problem: String?

    private static let kinds: [(String, LocalizedStringKey)] = [("video", "Video"), ("audio", "Audio"), ("image", "Pictures"),
                                                                ("document", "PDFs"), ("other", "Other files")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask for Files").font(Design.Typography.sheetTitle)
            Text("Anyone with the link can add files to “\(folderName)”. They land on the NAS; nothing there is replaced.")
                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            if let url {
                HStack {
                    Text(verbatim: url).font(Design.Studio.body).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text(verbatim: folderName))
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                    Picker("Works for", selection: $days) {
                        ForEach([1, 7, 14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                        Text("Always").tag(0)
                    }
                    Picker("Largest file", selection: $largestGB) {
                        ForEach([1, 5, 20, 50, 200], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    LabeledContent("Kinds") {
                        VStack(alignment: .leading) {
                            ForEach(Self.kinds, id: \.0) { kind in
                                Toggle(kind.1, isOn: Binding(get: { types.contains(kind.0) }, set: { if $0 { types.insert(kind.0) } else { types.remove(kind.0) } }))
                            }
                        }
                    }
                }
                .formStyle(.columns)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Design.Studio.warn).font(Design.Studio.body) }
            HStack {
                if working { PlumSpinner() }
                Spacer()
                Button(url == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                if url == nil {
                    Button("Make Link") { make() }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                        .disabled(working || types.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Design.Studio.panel)
    }

    private func make() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do { url = try await ask(name, password, days, Int64(largestGB) * 1_000_000_000, Array(types)) } catch { problem = error.localizedDescription }
        }
    }
}
