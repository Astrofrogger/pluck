import AppKit
import Foundation

/// Archive a share (wf-deliver): its comments (CSV and text), approval proofs and sign-off sheet into
/// `<project folder>/Pluck · Review/<link title>/`, then the link shows a calm "archived" page (it stays, and can be
/// reopened). After `forgetMonths` the clients' emails and the link's activity go; approvals keep name and date.
@MainActor
enum DeliverShareArchive {
    static let folderName = "Pluck · Review"
    static let forgetKey = "reviewArchiveForgetMonths", forgetChoices = [6, 12, 24, 0]
    /// Months after archiving that a link's client emails and activity are kept; 0 = forever.
    static var forgetMonths: Int {
        let v = UserDefaults.standard.object(forKey: forgetKey) as? Int ?? 12
        return forgetChoices.contains(v) ? v : 12
    }

    /// The main NAS server is from before Delivered and archived links (4.0.6: no `portal` in its hello, which came with
    /// them): it serves an archived link as before and leaves a delivered one's comments open.
    static var hostIsOlder: Bool { DeliverPeople.main().map { $0.portal != 1 } ?? false }

    /// Writes the record and archives the link. `projectFolder` nil: the project's NAS folder (nil when unknown: throws).
    @discardableResult
    static func archive(_ id: UUID, projectFolder: URL? = nil, store: DeliverStore = .shared, now: Date = .now) throws -> URL {
        guard let link = store.link(id) else { throw Deliver.Failure("notFound") }
        guard let project = projectFolder ?? DeliverProjectFile.folder(link.project, store: store) else { throw Deliver.Failure("noFolder") }
        let folder = try newFolder(in: project.appendingPathComponent(folderName, isDirectory: true), title: link.title, id: id)
        let assets = store.content(link.project).assets.filter { DeliverServer.inScope($0, link, store: store) }
        // What the link showed: internal comments and replies only on a team link.
        let comments = assets.flatMap { asset in store.comments(asset.id).filter { !$0.isInternal || link.isTeam }.map { comment in
            var shown = comment
            if !link.isTeam { shown.replies.removeAll(where: \.isInternal) }
            return (asset, shown)
        } }
            .sorted { ($0.0.name, $0.1.position) < ($1.0.name, $1.1.position) }
        // (Never over a file on the NAS: the folder is new, each file is created only if it isn't there.)
        try Data(commentsCSV(comments).utf8).write(to: folder.appendingPathComponent("Comments.csv"), options: .withoutOverwriting)
        try Data(commentsText(comments, title: link.title).utf8).write(to: folder.appendingPathComponent("Comments.txt"), options: .withoutOverwriting)
        let approvals = DeliverSignOff.approvals(link: id, store: store)
        var names: Set<String> = []
        for approval in approvals {
            guard let asset = store.find(approval.asset)?.asset else { continue }   // (its file is gone; the sign-off sheet still lists it)
            guard let pdf = DeliverProof.make(approval, store: store, servedBy: "Pluck") else { throw Deliver.Failure("internal") }
            var name = DeliverServer.safeName(DeliverProof.fileName(approval, asset: asset))
            if !names.insert(name).inserted { name = (name as NSString).deletingPathExtension + " " + approval.id.uuidString.prefix(8) + ".pdf"; names.insert(name) }
            try pdf.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        }
        try DeliverSignOff.write(title: link.title, approvals: approvals, into: folder, store: store, exclusive: true)
        store.updateLink(id) { $0.archived = now }
        DeliverProjectFile.merge(["reviewArchived": DeliverProof.iso(now)], into: project)
        return folder
    }

    /// `<review folder>/<title>/`, made new: " 2", " 3"… when that name is taken (another link of the same title, or this
    /// one archived before), the link id's start when the title leaves no name. Never an existing folder.
    nonisolated static func newFolder(in review: URL, title: String, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        let base = DeliverServer.safeName(title).trimmingCharacters(in: .whitespaces)
        let name = base.isEmpty ? "Link " + id.uuidString.prefix(8) : base
        for n in 1...999 {
            let folder = review.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw Deliver.Failure("internal")
    }

    /// Reopened: the link works again (what was written stays where it is).
    static func reopen(_ id: UUID, store: DeliverStore = .shared) {
        guard let link = store.link(id), link.archived != nil else { return }
        store.updateLink(id) { $0.archived = nil }
        // (Only once no other link of the project is archived.)
        guard !store.links.contains(where: { $0.id != id && $0.project == link.project && $0.archived != nil && $0.revoked == nil }) else { return }
        DeliverProjectFile.mark("reviewArchived", nil, project: link.project, store: store, replace: true)
    }

    nonisolated static func timecode(_ comment: Deliver.Comment, _ asset: Deliver.Asset) -> String {
        if let page = comment.page { return "p. \(page)" }
        guard let frame = comment.frame, let probe = asset.versions.first(where: { $0.id == comment.version })?.probe ?? asset.current.probe else { return "" }
        let fps = max(1, Int(probe.fps.rounded()))
        let (s, f) = (frame / fps, frame % fps)
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, f)
    }

    nonisolated static func commentsCSV(_ comments: [(Deliver.Asset, Deliver.Comment)]) -> String {
        func cell(_ text: String) -> String {
            let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
            return safe.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : safe
        }
        var lines = [["Asset", "Version", "Timecode", "Author", "Time (UTC)", "Comment", "Reply to", "Done"]]
        for (asset, comment) in comments {
            let version = "v\(asset.versions.first { $0.id == comment.version }?.number ?? 1)"
            lines.append([asset.name, version, timecode(comment, asset), comment.author, DeliverProof.iso(comment.created), comment.text, "", comment.completed ? "yes" : ""])
            for reply in comment.replies {
                lines.append([asset.name, version, timecode(comment, asset), reply.author, DeliverProof.iso(reply.created), reply.text, comment.id.uuidString, ""])
            }
        }
        return lines.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    nonisolated static func commentsText(_ comments: [(Deliver.Asset, Deliver.Comment)], title: String) -> String {
        var text = "\(title)\n\n", last = ""
        for (asset, comment) in comments {
            let version = asset.versions.first { $0.id == comment.version }?.number ?? 1
            if asset.name + "\(version)" != last { text += "\n\(asset.name) v\(version)\n"; last = asset.name + "\(version)" }
            let at = timecode(comment, asset)
            text += "\(at.isEmpty ? "" : at + "  ")\(comment.author): \(comment.text)\(comment.completed ? " (done)" : "")\n"
            for reply in comment.replies { text += "    \(reply.author): \(reply.text)\n" }
        }
        return text
    }

    /// Archived longer than `forgetMonths`: the link's activity log goes, and its approvals lose the email (name and
    /// date stay). At launch and now and then; a NAS host does the same for its copy (manifest `archiveForgetDays`).
    static func forget(store: DeliverStore = .shared, now: Date = .now) {
        let months = forgetMonths
        guard months > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) ?? now
        for link in store.links where (link.archived ?? .distantFuture) < cutoff {
            try? FileManager.default.removeItem(at: store.activityFile(link.id))
            for approval in store.approvals(link.project) where approval.link == link.id && approval.email != nil {
                store.update(approval: approval.id, in: link.project) { $0.email = nil }
            }
        }
    }

    /// Asks before archiving (and where, when the project's NAS folder isn't known), then shows the folder.
    static func ask(_ id: UUID, store: DeliverStore = .shared) {
        guard let link = store.link(id) else { return }
        var folder = DeliverProjectFile.folder(link.project, store: store)
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = String(localized: "Archive Here")
            panel.message = String(localized: "Choose the project’s folder. The review goes in “\(folderName)” inside it.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Archive “\(link.title)”?")
            alert.informativeText = String(localized: "Comments, approvals and the sign-off sheet go into the project’s folder. The link then says it’s archived; you can reopen it.")
            if hostIsOlder { alert.informativeText += "\n\n" + String(localized: "The link says it’s archived once the NAS server is updated.") }
            alert.addButton(withTitle: String(localized: "Archive"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try archive(id, projectFolder: folder, store: store)])
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t archive “\(link.title)”")
            alert.informativeText = error is Deliver.Failure ? String(localized: "Check that the project’s folder can be written to, then try again.") : error.localizedDescription
            alert.runModal()
        }
    }
}
