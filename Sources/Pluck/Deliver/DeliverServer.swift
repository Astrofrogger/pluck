import AppKit
import AVFoundation
import CryptoKit
import Foundation
import UserNotifications

/// The Mac's side of the data-channel protocol (§3, §6, §6.1): proofs and passwords, the link's scope,
/// browsing, fetches (bytes go out through the helper's `serve`), comments, reactions, fields, approvals,
/// uploads, the activity log, events and presence. Fed the helper's stdout reports; answers with stdin
/// lines through `output`. Messages over 192 KiB go out as parts (§6.1).
@MainActor
@Observable
final class DeliverServer {
    static let shared = DeliverServer(store: .shared)

    let store: DeliverStore
    /// A line for the helper's stdin ({"send":…}, {"serve":…}, {"close":…}, {"accept":…}, {"cancel":…}).
    @ObservationIgnored var output: ([String: Any]) -> Void = { _ in }
    /// When browsers write something (a comment, a reply, an approval, an upload): the inbox, a notification.
    @ObservationIgnored var notify: (Deliver.InboxItem, String) -> Void = { _, _ in }
    /// Email updates (4.1.0): whether the main host can mail, and one op to it (nil: not reachable). Tests replace both.
    @ObservationIgnored var mailActive: () -> Bool = { DeliverMail.shared.active }
    @ObservationIgnored var mailAsk: ([String: Any]) async -> [String: Any]? = { await DeliverMail.shared.ask($0) }
    /// A comment or reply written here that may @mention this Mac's person (before, after); DeliverLink sets it.
    @ObservationIgnored var mentioned: (Deliver.Comment?, Deliver.Comment) -> Void = { _, _ in }
    /// Where uploads land (Review/Uploads/<linkID>/) and comment attachments are kept.
    var uploadsFolder: URL { store.root.appendingPathComponent("Uploads", isDirectory: true) }
    var attachmentsFolder: URL { store.root.appendingPathComponent("Attachments", isDirectory: true) }

    final class Peer {
        let id: String
        let link: UUID
        let macNonce = DeliverKeys.random(32)
        var fpLocal = "", fpRemote = ""
        var path = "direct"
        var stage = Stage.hello
        var token: String?
        var name = ""
        var email: String?
        var wrongPasswords = 0
        /// The link's password hash this session was let in under (a change ends the session).
        var admittedHash: String?
        var writes: [Date] = []
        var stills: [Date] = []
        var fetches: Set<Int> = []
        /// What each fetch in flight is (a finished original or proxy is a download in the activity log).
        var fetchWhat: [Int: (what: String, asset: UUID, version: UUID)] = [:]
        var uploads: [Int: Upload] = [:]
        /// Attachments this browser uploaded, for its next comments.
        var attachments: [UUID: Deliver.Comment.Attachment] = [:]
        var viewing: UUID?
        /// This browser's own mail row as it set it in this session (the host keeps the real one).
        var subscription: (email: String, mode: String)?
        enum Stage { case hello, welcomed, ready }
        init(id: String, link: UUID) { self.id = id; self.link = link }
    }

    /// One upload from a browser (§6.1): the helper writes the bytes to `part`; done when it says so and
    /// the browser's `upload-end` (with the SHA-256) is in.
    final class Upload {
        let id: Int, name: String, size: Int64, type: String, attachment: Bool, part: URL
        var written: Bool?
        /// The helper's own hash of what it wrote (then Swift doesn't read the file again).
        var helperSHA: String?
        var end: (id: Int, sha: String)?
        init(id: Int, name: String, size: Int64, type: String, attachment: Bool, part: URL) {
            self.id = id; self.name = name; self.size = size; self.type = type; self.attachment = attachment; self.part = part
        }
    }

    private(set) var peers: [String: Peer] = [:]
    /// Each room's state from the helper: active, standby, nohost (a NAS should serve it but none holds it), offline, taken.
    private(set) var rooms: [String: String] = [:]
    /// §13.24 H1: rooms one of the owner's servers has held (this Mac registered, or was stood by for an always-on host),
    /// kept across launches. A level-3 link is shown, copied or sent only after that, so nobody who sees the address
    /// before any server registered can take its room first.
    private(set) var heldRooms = Set(UserDefaults.standard.stringArray(forKey: DeliverServer.heldKey) ?? [])
    nonisolated static let heldKey = "reviewHeldRooms"

    /// The address to show, copy, email or put in a QR code: a level-3 link's only once its room is held (else nil:
    /// "Getting the link ready…"). Level 2 needs no wait: a link holder can't make its signed hello.
    func shareURL(_ link: Deliver.ShareLink) -> String? {
        guard store.code(link.id) == nil || heldRooms.contains(link.roomID) else { return nil }
        return store.url(link)
    }
    /// Someone else registered this link's room first (or holds it since it lapsed): the owner needs a new link.
    func isTaken(_ link: Deliver.ShareLink) -> Bool { rooms[link.roomID] == "taken" && store.key(link.id) != nil }

    /// Tests and the room reports: a room is the owner's.
    func held(_ room: String) {
        guard !heldRooms.contains(room) else { return }
        heldRooms.insert(room)
        let live = Set(store.links.map(\.roomID)) // only rooms of links still here
        heldRooms.formIntersection(live.union([room]))
        UserDefaults.standard.set(Array(heldRooms), forKey: Self.heldKey)
        if self === Self.shared { DeliverClientPage.soon() }   // a link now shown: client pages can list it
    }
    @ObservationIgnored private var wrongByLink: [UUID: [Date]] = [:]
    @ObservationIgnored private var lockedUntil: [UUID: Date] = [:]
    /// The server's clock (§13.9 enforces deadlines with it; tests move it).
    @ObservationIgnored var clock: () -> Date = { .now }
    /// The effective deadline each ready browser was last told (a change sends `deadline`).
    @ObservationIgnored private var toldDeadline: [String: Date?] = [:]
    /// Tests: a still made without AVFoundation (frame → JPEG file).
    @ObservationIgnored var stillMaker: ((Deliver.Version, Int) async -> URL?)?

    init(store: DeliverStore) {
        self.store = store
        store.listeners.append { [weak self] in self?.heard($0) }
    }

    /// Browsers connected now, per link (the eye count) and per asset (the avatar row).
    func viewers(link: UUID) -> Int { peers.values.filter { $0.link == link && $0.stage == .ready }.count }
    func viewers(asset: UUID) -> [String] { peers.values.filter { $0.viewing == asset && $0.stage == .ready }.map(\.name) }

    // MARK: - The helper's reports

    func helper(_ report: [String: Any]) {
        if let room = report["room"] as? [String: Any], let id = room["room"] as? String {
            rooms[id] = room["state"] as? String
            // "nohost" (a never-serve Mac, no NAS online): the Room accepted our register with the owner's reg before we let
            // go, so the room is the owner's and nobody else can take it: as safe for H1 as "active".
            if ["active", "registered", "standby", "nohost"].contains(rooms[id] ?? "") { held(id) }
        }
        if let info = report["peer"] as? [String: Any], let id = info["peer"] as? String {
            if info["state"] as? String == "open" {
                guard let room = info["room"] as? String, let link = store.links.first(where: { $0.roomID == room && $0.revoked == nil }),
                      let secret = store.secret(link.id) else {
                    return output(["close": ["peer": id, "reason": "unknown"]])
                }
                let peer = Peer(id: id, link: link.id)
                peer.fpLocal = info["fpLocal"] as? String ?? ""
                peer.fpRemote = info["fpRemote"] as? String ?? ""
                peer.path = info["path"] as? String ?? "direct"
                // Level 2: signed with the room key, so the browser knows it's the owner's server before it sends anything.
                // Level 3 (§13.24): a MAC with the code-derived authKey, which pluck.tools doesn't have.
                let nonce = DeliverKeys.base64url(peer.macNonce)
                let hello: [String: Any]? = if store.code(link.id) != nil, let key = store.key(link.id) {
                    ["t": "hello", "v": 3, "nonce": nonce, "mac": DeliverKeys.helloMAC(authKey: DeliverKeys.authKey(key), macNonce: peer.macNonce, fpMac: peer.fpLocal, fpBrowser: peer.fpRemote)]
                } else {
                    DeliverKeys.helloSignature(root: secret, macNonce: peer.macNonce, fpMac: peer.fpLocal, fpBrowser: peer.fpRemote).map { ["t": "hello", "v": 2, "nonce": nonce, "sig": $0] }
                }
                guard let hello else { return output(["close": ["peer": id, "reason": "unknown"]]) }
                peers[id] = peer
                send(peer, hello)
                RemoteKeepAwake.update()
            } else if info["state"] as? String == "closed" {
                closed(id)
            }
        }
        if let message = report["msg"] as? [String: Any], let id = message["peer"] as? String, let body = message["msg"] as? [String: Any] {
            if let peer = peers[id] { handle(peer, body) }
        }
        if let served = report["served"] as? [String: Any], let id = served["peer"] as? String, let fetch = served["fetch"] as? Int {
            peers[id]?.fetches.remove(fetch)
            if let peer = peers[id], let info = peer.fetchWhat.removeValue(forKey: fetch), served["result"] as? String == "done",
               info.what == "original" || info.what == "proxy" {
                log(peer, "downloaded", asset: info.asset, version: info.version, detail: .init(what: info.what))
            }
        }
        if let upload = report["upload"] as? [String: Any], let id = upload["peer"] as? String, let number = upload["upload"] as? Int,
           let peer = peers[id], let item = peer.uploads[number] {
            if upload["state"] as? String == "cancelled" {
                peer.uploads[number] = nil
                try? FileManager.default.removeItem(at: item.part)
                return
            }
            item.written = upload["state"] as? String == "done" && (upload["bytes"] as? NSNumber)?.int64Value == item.size
            item.helperSHA = upload["sha256"] as? String
            finish(peer, item)
        }
    }

    private func closed(_ id: String) {
        toldDeadline[id] = nil
        guard let peer = peers.removeValue(forKey: id) else { return }
        for upload in peer.uploads.values { try? FileManager.default.removeItem(at: upload.part) }
        if peer.viewing != nil { presence(peer.link) }
        RemoteKeepAwake.update()
    }

    private func close(_ peer: Peer, _ reason: String) {
        output(["close": ["peer": peer.id, "reason": reason]])
        closed(peer.id)
    }

    /// Whole: the helper cuts anything over the browser's message size into §6.1 parts (Mac mode too).
    private func send(_ peer: Peer, _ message: [String: Any]) {
        output(["send": ["peer": peer.id, "msg": message]])
    }

    private func reply(_ peer: Peer, _ id: Int, _ fields: [String: Any]) {
        send(peer, fields.merging(["re": id]) { $1 })
    }

    private func fail(_ peer: Peer, _ id: Int, _ failure: Deliver.Failure) {
        var error: [String: Any] = ["code": failure.code]
        if let progress = failure.progress { error["progress"] = progress }
        reply(peer, id, ["error": error])
    }

    private func log(_ peer: Peer, _ kind: String, asset: UUID? = nil, version: UUID? = nil, detail: Deliver.Activity.Detail? = nil) {
        store.log(.init(link: peer.link, peer: peer.id, name: peer.name.isEmpty ? nil : peer.name, email: peer.email, kind: kind,
                        asset: asset, version: version, detail: detail))
    }

    // MARK: - Requests

    static let messageLimit = 64 * 1024

    func handle(_ peer: Peer, _ message: [String: Any]) {
        // A browser's cancel of its upload has no id (§6.1).
        if message["t"] as? String == "cancel", let number = message["upload"] as? Int, let upload = peer.uploads.removeValue(forKey: number) {
            try? FileManager.default.removeItem(at: upload.part)
            return output(["cancel": ["peer": peer.id, "upload": number]])
        }
        guard let id = message["id"] as? Int, let type = message["t"] as? String else { return }
        guard (try? JSONSerialization.data(withJSONObject: message).count).map({ $0 <= Self.messageLimit }) == true else {
            return fail(peer, id, .init("limit"))
        }
        // Turned off, paused or run out: checked on every request, before anything else.
        guard let link = store.link(peer.link), link.revoked == nil else {
            fail(peer, id, .init("revoked"))
            send(peer, ["t": "bye", "code": "revoked"])
            return close(peer, "revoked")
        }
        guard link.isLive else {
            fail(peer, id, .init("expired"))
            send(peer, ["t": "bye", "code": "expired"])
            return close(peer, "expired")
        }
        guard !link.isPaused else {
            fail(peer, id, .init("paused"))
            send(peer, ["t": "bye", "code": "paused"])
            return close(peer, "paused")
        }
        // Past the feedback deadline (§13.9): every request, auth too; the room stays, so a reopened link works again.
        if let deadline = DeliverDeadlines.effective(link, store: store), deadline <= clock() {
            reply(peer, id, ["error": ["code": "deadline", "at": Self.date(deadline)]])
            send(peer, ["t": "bye", "code": "deadline", "at": Self.date(deadline)])
            return close(peer, "deadline")
        }
        do {
            switch (type, peer.stage) {
            case ("auth", .hello): try auth(peer, id, message, link)
            case ("password", .welcomed): try password(peer, id, message, link)
            case ("unsubscribe", .welcomed): try unsubscribe(peer, id, message)
            case ("confirm", .welcomed): try unsubscribe(peer, id, message, op: "subscribe-confirm")
            case (_, .ready): try request(peer, id, type, message, link)
            default: throw Deliver.Failure("auth")
            }
        } catch let failure as Deliver.Failure {
            fail(peer, id, failure)
            // (A name still missing on a link that asks for one also answers auth, without closing.)
            if failure.code == "auth", peer.stage != .ready { close(peer, "auth") }
        } catch {
            fail(peer, id, .init("internal"))
        }
    }

    private func auth(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        guard let level = store.level(link.id), message["v"] as? Int == level, let key = store.key(link.id),
              let nonce = (message["nonce"] as? String).flatMap(DeliverKeys.data(base64url:)), nonce.count == 32,
              let proof = message["proof"] as? String, let token = (message["token"] as? String).flatMap(DeliverKeys.data(base64url:)), token.count == 32
        else { throw Deliver.Failure("auth") }
        let authKey = DeliverKeys.authKey(key)
        let expected = DeliverKeys.proof(authKey: authKey, role: "browser", macNonce: peer.macNonce, browserNonce: nonce, fpMac: peer.fpLocal, fpBrowser: peer.fpRemote)
        guard DeliverKeys.same(Data(expected.utf8), Data(proof.utf8)) else { throw Deliver.Failure("auth") }
        peer.token = DeliverKeys.sha256(token)
        identify(peer, link, name: message["name"], email: message["email"])
        let mine = DeliverKeys.proof(authKey: authKey, role: "mac", macNonce: peer.macNonce, browserNonce: nonce, fpMac: peer.fpLocal, fpBrowser: peer.fpRemote)
        let needPassword = link.passwordHash != nil
        peer.stage = .welcomed
        reply(peer, id, ["t": "welcome", "proof": mine, "needPassword": needPassword])
        // No password: ready straight away (as an event, there being no request to answer).
        if !needPassword { ready(peer, nil, link) }
    }

    /// The viewer's name (a personal link's recipient, always) and optional email (≤ 120 chars, kept here only).
    private func identify(_ peer: Peer, _ link: Deliver.ShareLink, name: Any?, email: Any?) {
        if let recipient = link.recipient { peer.name = recipient } else if let name = name as? String { peer.name = Deliver.clean(name, limit: DeliverStore.authorLimit) }
        if let email = email as? String {
            let clean = Deliver.clean(email, limit: 120)
            peer.email = clean.isEmpty ? nil : clean
        }
    }

    private func password(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        guard let hash = link.passwordHash else { throw Deliver.Failure("invalid") }
        if let until = lockedUntil[link.id], until > .now { throw Deliver.Failure("locked") }
        if DeliverKeys.checkPassword(message["password"] as? String ?? "", hash) { return ready(peer, id, link) }
        peer.wrongPasswords += 1
        let hour = (wrongByLink[link.id] ?? []).filter { Date.now.timeIntervalSince($0) < 3600 } + [.now]
        wrongByLink[link.id] = hour
        if hour.count >= 20 {
            lockedUntil[link.id] = Date.now.addingTimeInterval(3600)
            wrongByLink[link.id] = []
            DeliverNotify.locked(link)
        }
        fail(peer, id, .init("password"))
        if peer.wrongPasswords >= 5 { close(peer, "password") }
    }

    /// `ready.link` (§6, §6.1): the link's settings a browser needs, never its key, password or scope ids beyond the root.
    static func linkInfo(_ link: Deliver.ShareLink, store: DeliverStore = .shared) -> [String: Any] {
        var info: [String: Any] = ["title": link.title, "mode": link.mode.rawValue, "allowDownload": link.allowDownload, "latestOnly": link.latestOnly,
                                   "layout": link.layout ?? "grid", "requireName": link.requireName ?? false, "askEmail": link.askEmail ?? false,
                                   "allowProxy": link.allowProxy ?? false, "audience": link.audience ?? "client", "fields": link.shownFields,
                                   "recipient": link.recipient ?? NSNull(),
                                   "featuredField": link.mode != .review || link.featuredField == "none" ? NSNull() : (link.featuredField ?? "status") as Any]
        if let expires = link.expires { info["expires"] = Self.date(expires) }
        if let description = link.description, !description.isEmpty { info["description"] = description }
        if let mark = link.watermark {
            info["watermark"] = ["text": mark.text, "position": mark.position, "opacity": mark.opacity, "size": mark.size, "burned": mark.burned]
        } else { info["watermark"] = NSNull() }
        if let uploads = link.uploads, link.mode == .review {
            info["uploads"] = ["folder": uploads.folder?.uuidString ?? NSNull(), "maxBytes": uploads.maxBytes, "types": uploads.types] as [String: Any]
        } else { info["uploads"] = NSNull() }
        if let header = store.branding(for: link.project)?.header { info["header"] = "data:image/jpeg;base64," + header.base64EncodedString() }
        if let deadline = DeliverDeadlines.effective(link, store: store) { info["deadline"] = Self.date(deadline) }
        // Workflow plan 3, 5, 6 (optional; old pages ignore them): the link's own order, custom statuses' and fields' names.
        let content = store.content(link.project)
        if let order = link.order?.isEmpty == false ? link.order : Deliver.folderOrder(content.folders, assets: content.assets) {
            // (Ids the link holds only, as the NAS host's list: the page orders what it lists, and other assets' ids stay here.)
            let mine = Set(content.assets.filter { inScope($0, link, store: store) }.map(\.id))
            info["order"] = order.filter(mine.contains).map(\.uuidString)
        }
        if link.customStatuses == true, let defs = store.library.statuses, !defs.isEmpty {
            info["statusDefs"] = defs.map { ["id": $0.id, "name": $0.name, "colour": $0.colour] }
        }
        let fieldDefs = store.fieldDefs.filter { link.isTeam || link.shownFields.contains($0.wireName) }
        if !fieldDefs.isEmpty {
            info["fieldDefs"] = fieldDefs.map { def -> [String: Any] in
                var wire: [String: Any] = ["id": def.wireName, "name": def.name, "kind": def.kind]
                if let options = def.options { wire["options"] = options }
                return wire
            }
        }
        return info
    }

    private func ready(_ peer: Peer, _ id: Int?, _ link: Deliver.ShareLink) {
        peer.stage = .ready
        peer.admittedHash = link.passwordHash
        store.opened(link.id)
        log(peer, "opened")
        if link.notifyOpened == true, link.muted != true { DeliverNotify.opened(link, by: peer.name) }
        let root: [String: Any] = switch link.scope {
        case .project(let project): ["kind": "project", "id": project.uuidString, "name": store.name(link.scope)]
        case .folder(let folder, _): ["kind": "folder", "id": folder.uuidString, "name": store.name(link.scope)]
        case .asset(let asset, _): ["kind": "asset", "id": asset.uuidString, "name": store.name(link.scope)]
        case .assets: ["kind": "assets", "id": link.id.uuidString, "name": link.title]
        }
        var message: [String: Any] = ["t": "ready", "link": Self.linkInfo(link, store: store), "root": root, "me": ["peer": peer.id, "name": peer.name],
                                      "now": Self.date(clock()), "mentions": true]
        if mailLink(link) { message["mail"] = true }
        toldDeadline[peer.id] = DeliverDeadlines.effective(link, store: store)
        if let branding = store.branding(for: link.project) { message["branding"] = branding.wire }
        if link.isPortal { message["portal"] = DeliverClientPage.wire(link, store: store, url: shareURL) }
        if let id { message["re"] = id }
        send(peer, message)
    }

    static let writes: Set<String> = ["comment-add", "reply-add", "comment-edit", "comment-delete", "comment-complete", "approve", "react", "field-set",
                                      "upload-begin"]

    private func request(_ peer: Peer, _ id: Int, _ type: String, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        // A client page lists links (in `ready`); nothing else is asked of it.
        if link.isPortal, type != "identify", type != "name" { throw Deliver.Failure("scope") }
        // A link that asks for a name: nothing but the name until it's given.
        if link.requireName == true, peer.name.isEmpty, type != "identify", type != "name" { throw Deliver.Failure("auth") }
        if Self.writes.contains(type) {
            guard link.mode == .review else { throw Deliver.Failure("readonly") }
            // Comments, replies (drawings too) and approvals carry a name: the page asks for one on `needName`.
            if peer.name.isEmpty, ["comment-add", "reply-add", "approve"].contains(type) { throw Deliver.Failure("needName") }
            // Every write, ticks included: 30 a minute per peer.
            peer.writes = peer.writes.filter { Date.now.timeIntervalSince($0) < 60 }
            guard peer.writes.count < 30 else { throw Deliver.Failure("limit") }
            peer.writes.append(.now)
        }
        switch type {
        case "name", "identify":
            identify(peer, link, name: message["name"], email: message["email"])
            reply(peer, id, ["ok": true])
            presence(link.id)
        case "list": reply(peer, id, try list(message["folder"] as? String, link))
        case "asset":
            let asset = try asset(shortAsset(message["asset"], link), link)
            reply(peer, id, ["asset": wire(asset, link), "approvals": approvals(asset, link)])
        case "fetch": try fetch(peer, id, message, link)
        case "comments":
            let (asset, version) = try version(message, link)
            reply(peer, id, ["comments": store.comments(asset.id, version: version.id).filter { visible($0, link) }.map { wire($0, peer) }])
        case "mentionable": reply(peer, id, ["people": mentionable(link).map { ["id": $0.id, "name": $0.name] }])
        case "subscribe": try subscribe(peer, id, message, link)
        case "unsubscribe": try unsubscribe(peer, id, message)
        case "confirm": try unsubscribe(peer, id, message, op: "subscribe-confirm")
        case "subscription": reply(peer, id, ["mode": peer.subscription?.mode ?? NSNull(), "email": peer.subscription?.email ?? NSNull()])
        case "comment-add":
            let (asset, version) = try version(message, link)
            let drawing = try message["drawing"].flatMap { $0 is NSNull ? nil : $0 }.map { value -> Deliver.Drawing in
                guard let data = try? JSONSerialization.data(withJSONObject: value), let drawing = try? Deliver.decoder.decode(Deliver.Drawing.self, from: data) else {
                    throw Deliver.Failure("invalid")
                }
                return drawing
            }
            // frame null (or missing) = a general comment.
            let frame = message["frame"] as? Int
            if let value = message["frame"], !(value is NSNull), frame == nil { throw Deliver.Failure("invalid") }
            let isInternal = message["internal"] as? Bool ?? false
            if isInternal, !link.isTeam { throw Deliver.Failure("scope") }
            let anchor = (message["anchor"] as? [NSNumber])?.map(\.doubleValue)
            if message["anchor"] != nil, !(message["anchor"] is NSNull), anchor == nil { throw Deliver.Failure("invalid") }
            let attachmentIDs = (message["attachments"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let attachments = try attachmentIDs.map { id -> Deliver.Comment.Attachment in
                guard let found = peer.attachments[id] else { throw Deliver.Failure("invalid") }
                return found
            }
            let comment = try store.addComment(asset: asset.id, version: version.id, frame: frame, endFrame: message["endFrame"] as? Int,
                                               text: message["text"] as? String ?? "", author: author(peer), token: peer.token, link: link.id, drawing: drawing,
                                               page: message["page"] as? Int, anchor: anchor, isInternal: isInternal, attachments: attachments,
                                               mentions: mentions(message, link))
            for id in attachmentIDs { peer.attachments[id] = nil }
            mentioned(nil, comment)
            reply(peer, id, ["comment": wire(comment, peer)])
            log(peer, "commented", asset: asset.id, version: version.id, detail: frame.map { .init(from: $0) })
            inbox(comment.id, "comment", asset, version.id, comment.text, peer, link)
        case "reply-add":
            let found = try comment(message["comment"], link)
            let isInternal = message["internal"] as? Bool ?? false
            if isInternal, !link.isTeam { throw Deliver.Failure("scope") }
            let changed = try store.reply(to: found.id, text: message["text"] as? String ?? "", author: author(peer), token: peer.token, isInternal: isInternal,
                                       mentions: mentions(message, link))
            mentioned(found, changed)
            reply(peer, id, ["comment": wire(changed, peer)])
            log(peer, "commented", asset: found.asset, version: found.version)
            if let asset = store.find(found.asset)?.asset, let made = changed.replies.last {
                inbox(made.id, "reply", asset, found.version, made.text, peer, link)
            }
        case "comment-edit":
            let found = try comment(message["comment"], link)
            let text = try DeliverStore.text(message["text"] as? String ?? "")
            let changed: Deliver.Comment
            if let replyID = (message["reply"] as? String).flatMap(UUID.init(uuidString:)) {
                guard let index = found.replies.firstIndex(where: { $0.id == replyID }) else { throw Deliver.Failure("notFound") }
                guard found.replies[index].authorToken == peer.token else { throw Deliver.Failure("scope") }
                changed = try store.change(comment: found.id) { $0.replies[index].text = text; $0.edited = .now; return true }
            } else {
                guard found.authorToken == peer.token else { throw Deliver.Failure("scope") }
                changed = try store.change(comment: found.id) { $0.text = text; $0.edited = .now; return true }
            }
            reply(peer, id, ["comment": wire(changed, peer)])
        case "comment-delete":
            let found = try comment(message["comment"], link)
            if let replyID = (message["reply"] as? String).flatMap(UUID.init(uuidString:)) {
                guard let index = found.replies.firstIndex(where: { $0.id == replyID }) else { throw Deliver.Failure("notFound") }
                guard found.replies[index].authorToken == peer.token else { throw Deliver.Failure("scope") }
                let changed = try store.change(comment: found.id) { $0.replies.remove(at: index); return true }
                reply(peer, id, ["comment": wire(changed, peer)])
            } else {
                guard found.authorToken == peer.token else { throw Deliver.Failure("scope") }
                try store.deleteComment(found.id)
                reply(peer, id, ["comment": ["id": found.id.uuidString, "asset": found.asset.uuidString, "version": found.version.uuidString]])
            }
        case "comment-complete":
            let found = try comment(message["comment"], link)
            reply(peer, id, ["comment": wire(try store.complete(found.id, message["completed"] as? Bool ?? true), peer)])
        case "react":
            let found = try comment(message["comment"], link)
            guard let token = peer.token, let emoji = message["emoji"] as? String else { throw Deliver.Failure("invalid") }
            reply(peer, id, ["comment": wire(try store.react(found.id, emoji: emoji, by: token, on: message["on"] as? Bool ?? true), peer)])
        case "approve":
            // Approving sets status: only where reviewers may set it (the featured field), as on a host.
            guard link.isTeam || (link.featuredField ?? "status") == "status" else { throw Deliver.Failure("scope") }
            let (asset, version) = try version(message, link)
            guard let decision = (message["decision"] as? String).flatMap(Deliver.Approval.Decision.init(rawValue:)) else { throw Deliver.Failure("invalid") }
            let approval = try approve(peer, asset, version, decision, link)
            reply(peer, id, ["status": decision == .approve ? "approved" : "needsChanges",
                             "approval": ["id": approval.id.uuidString, "decision": decision.rawValue, "proof": true],
                             "asset": summary(store.find(asset.id)?.asset ?? asset, link)])
        case "field-set":
            let asset = try asset(message["asset"], link)
            // (A custom field only when the link lists it, as the built-in ones.)
            guard let field = message["field"] as? String, Deliver.Fields.names.contains(field)
                    || (field.hasPrefix("cf:") && (link.isTeam || link.shownFields.contains(field))) else { throw Deliver.Failure("invalid") }
            // Clients set only the link's featured field; a team link sets any.
            guard link.isTeam || field == (link.featuredField ?? "status") else { throw Deliver.Failure("scope") }
            if field == "status" {
                // (Custom statuses are the owner's to set: browsers set the built-in ones.)
                guard let value = (message["value"] as? String).map(Deliver.Status.init(rawValue:)), value.isBuiltin, value != .none else { throw Deliver.Failure("invalid") }
                switch value {
                case .approved: try approve(peer, asset, asset.current, .approve, link)
                case .needsChanges: try approve(peer, asset, asset.current, .changes, link)
                default: store.setStatus(value, of: asset.id, by: author(peer))
                }
            } else {
                try store.setField(field, message["value"], of: asset.id, by: author(peer))
            }
            reply(peer, id, ["asset": summary(store.find(asset.id)?.asset ?? asset, link)])
        case "viewing":
            let asset = message["asset"] is String ? try self.asset(message["asset"], link).id : nil
            if let asset, asset != peer.viewing { log(peer, "viewed", asset: asset) }
            peer.viewing = asset
            reply(peer, id, ["ok": true])
            presence(link.id)
        case "played":
            let (asset, version) = try version(message, link)
            guard let from = message["from"] as? Int, let to = message["to"] as? Int, to >= from, from >= 0 else { throw Deliver.Failure("invalid") }
            log(peer, "played", asset: asset.id, version: version.id, detail: .init(from: from, to: to))
            reply(peer, id, ["ok": true])
        case "upload-begin": try uploadBegin(peer, id, message, link)
        case "upload-end":
            guard let number = message["upload"] as? Int, let upload = peer.uploads[number], let sha = message["sha256"] as? String else { throw Deliver.Failure("invalid") }
            upload.end = (id, sha)
            finish(peer, upload)
        default:
            throw Deliver.Failure("invalid")
        }
    }

    @discardableResult
    private func approve(_ peer: Peer, _ asset: Deliver.Asset, _ version: Deliver.Version, _ decision: Deliver.Approval.Decision, _ link: Deliver.ShareLink) throws -> Deliver.Approval {
        let approval = try store.approve(asset: asset.id, version: version.id, decision: decision, author: author(peer), link: link.id, email: peer.email)
        log(peer, "approved", asset: asset.id, version: version.id, detail: .init(what: decision.rawValue))
        inbox(approval.id, "approval", asset, version.id, decision == .approve ? "approved" : "needsChanges", peer, link)
        // The proof waits for the original's hash: made now when it isn't there yet.
        if approval.sha256 == nil { DeliverProof.hashSoon(asset: asset.id, version: version.id, store: store) }
        return approval
    }

    /// The asset's approvals a link may see (§13.8): those made through it, every one for team links.
    private func approvals(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> [[String: Any]] {
        guard let project = store.find(asset.id)?.project else { return [] }
        return store.approvals(project).filter { $0.asset == asset.id && (link.isTeam || $0.link == link.id) }.map { approval in
            ["id": approval.id.uuidString, "decision": approval.decision.rawValue, "by": approval.author, "at": Self.date(approval.created),
             "version": approval.version.uuidString, "number": approval.versionNumber ?? asset.versions.first { $0.id == approval.version }?.number ?? 0]
        }
    }

    /// A new version shared while browsers watch (§13.4): `asset-changed`, then `version-added` (not for latest-only links).
    func versionAdded(_ asset: Deliver.Asset, _ version: Deliver.Version) {
        broadcast(asset: asset.id) { _, _ in ["t": "asset-changed", "asset": asset.id.uuidString] }
        broadcast(asset: asset.id) { _, link in
            link.latestOnly ? nil : ["t": "version-added", "asset": asset.id.uuidString, "version": version.id.uuidString, "number": version.number, "name": asset.name]
        }
    }

    /// Deadlines changed or passed (DeliverDeadlines' check): `deadline` to those whose effective one moved, `bye` past it.
    func deadlinesChanged() {
        for peer in peers.values where peer.stage == .ready {
            guard let link = store.link(peer.link) else { continue }
            let deadline = DeliverDeadlines.effective(link, store: store)
            if let deadline, deadline <= clock() {
                send(peer, ["t": "bye", "code": "deadline", "at": Self.date(deadline)])
                close(peer, "deadline")
                continue
            }
            if toldDeadline[peer.id] != deadline {
                toldDeadline[peer.id] = deadline
                send(peer, ["t": "deadline", "deadline": deadline.map { Self.date($0) as Any } ?? NSNull()])
            }
        }
    }

    private func author(_ peer: Peer) -> String { peer.name.isEmpty ? String(localized: "Guest") : peer.name }

    private func inbox(_ id: UUID, _ kind: String, _ asset: Deliver.Asset, _ version: UUID, _ text: String, _ peer: Peer, _ link: Deliver.ShareLink) {
        let item = Deliver.InboxItem(id: id, project: link.project, asset: asset.id, version: version, kind: kind,
                                     summary: String(text.prefix(120)), author: author(peer))
        store.addInbox(item)
        if link.muted != true { notify(item, asset.name) }
    }

    // MARK: - Mentions and email updates (4.1.0)

    /// Who a browser can @mention on this link: the team (names only), then authors of the comments and replies it can see.
    func mentionable(_ link: Deliver.ShareLink) -> [(id: String, name: String)] {
        var seen = Set<String>(), list: [(id: String, name: String)] = []
        func add(_ id: String, _ name: String) { if !name.isEmpty, list.count < 200, seen.insert(id).inserted { list.append((id, name)) } }
        for person in DeliverPeople.shared.team { add(person.id, person.name ?? "") }
        for asset in store.content(link.project).assets where inScope(asset, link) {
            for comment in store.comments(asset.id) {
                if visible(comment, link), let token = comment.authorToken { add(DeliverMail.mentionID(token), comment.author) }
                for reply in comment.replies where link.isTeam || !reply.isInternal {
                    if !comment.isInternal || link.isTeam, let token = reply.authorToken { add(DeliverMail.mentionID(token), reply.author) }
                }
            }
        }
        return list
    }

    /// `mentions` of a write: strings only, ids the link's `mentionable` has, at most 10.
    private func mentions(_ message: [String: Any], _ link: Deliver.ShareLink) -> [String]? {
        // (Strings only, the rest dropped, as the NAS host does: one bad item doesn't lose the others.)
        guard let asked = (message["mentions"] as? [Any])?.compactMap({ $0 as? String }), !asked.isEmpty else { return nil }
        let known = Set(mentionable(link).map(\.id))
        return Array(NSOrderedSet(array: asked.filter(known.contains)).array.prefix(10)) as? [String]
    }

    /// A browser may ask for mail on this link: mail is on, the link has Email updates and its mail code is here (without
    /// the code the host has no link for its mails; the NAS host checks the same).
    private func mailLink(_ link: Deliver.ShareLink) -> Bool {
        mailActive() && link.notify?.email == true && store.code(link.id) != nil
    }

    /// Forwarded to the main host as `subscriber-set`. No outbox for this: it needs the host's answer, so it goes at once
    /// and answers `off` when the host isn't reachable.
    private func subscribe(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        guard let token = peer.token else { throw Deliver.Failure("auth") }
        guard mailLink(link) else { throw Deliver.Failure("off") }
        let email = (message["email"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard DeliverMail.validEmail(email), let mode = message["mode"] as? String, ["instant", "daily", "off"].contains(mode) else { throw Deliver.Failure("invalid") }
        var op: [String: Any] = ["op": "subscriber-set", "kind": "client", "email": email, "link": link.id.uuidString, "author": token, "mode": mode]
        if let lang = message["lang"] as? String { op["lang"] = String(lang.prefix(8)) }
        if peer.name.isEmpty == false { op["name"] = peer.name }
        Task {
            let answer = await mailAsk(op)
            if let answer, answer["ok"] as? Bool == true {
                peer.subscription = (email, mode)
                // (A typed address waits for the host's confirmation mail: the page says to check the inbox.)
                reply(peer, id, ["ok": true, "pending": answer["pending"] as? Bool == true])
            } else {
                // The host's own refusal as a NAS host answers it ("later": an address change too soon), else off.
                let code = (answer?["error"] as? [String: Any])?["code"] as? String
                fail(peer, id, .init(code.flatMap { ["later", "invalid"].contains($0) ? $0 : nil } ?? "off"))
            }
        }
    }

    /// A mail's token (the stop link, or with `subscribe-confirm` the confirmation link), passed on to the host.
    private func unsubscribe(_ peer: Peer, _ id: Int, _ message: [String: Any], op: String = "unsubscribe") throws {
        guard peer.token != nil else { throw Deliver.Failure("auth") }
        guard let token = message["token"] as? String, token.count == 43 else { throw Deliver.Failure("invalid") }
        Task {
            if let answer = await mailAsk(["op": op, "token": token]), answer["ok"] as? Bool == true {
                reply(peer, id, op == "unsubscribe" ? ["ok": true, "scope": answer["scope"] as? String ?? "link"] : ["ok": true, "confirmed": answer["confirmed"] as? Bool == true])
            } else { fail(peer, id, .init("off")) }
        }
    }

    // MARK: - Scope

    /// The asset, when the link holds it (folder links hold their subfolders).
    func inScope(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> Bool { Self.inScope(asset, link, store: store) }

    static func inScope(_ asset: Deliver.Asset, _ link: Deliver.ShareLink, store: DeliverStore) -> Bool {
        guard store.find(asset.id)?.project == link.project else { return false }
        switch link.scope {
        case .project: return true
        case .folder(let folder, let project): return asset.folder.map { store.subfolders(folder, in: project).contains($0) } ?? false
        case .asset(let id, _): return asset.id == id
        case .assets(let ids, _): return ids.contains(asset.id)
        }
    }

    /// Internal comments only for team links.
    func visible(_ comment: Deliver.Comment, _ link: Deliver.ShareLink) -> Bool { !comment.isInternal || link.isTeam }

    /// On a version the link shows (latestOnly hides older ones, events included).
    private func shown(_ comment: Deliver.Comment, _ link: Deliver.ShareLink) -> Bool {
        !link.latestOnly || store.find(comment.asset)?.asset.current.id == comment.version
    }

    /// A level-3 deep link's `/a/<8>` (§13.24): the one asset in the link's scope whose id starts with it (else notFound).
    private func shortAsset(_ value: Any?, _ link: Deliver.ShareLink) throws -> Any? {
        guard let short = (value as? String)?.lowercased(), short.count == 8 else { return value }
        let hits = store.content(link.project).assets.filter { $0.id.uuidString.prefix(8).lowercased() == short && inScope($0, link) }
        guard hits.count == 1 else { throw Deliver.Failure("notFound") }
        return hits[0].id.uuidString
    }

    private func asset(_ value: Any?, _ link: Deliver.ShareLink) throws -> Deliver.Asset {
        guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { throw Deliver.Failure("invalid") }
        guard let found = store.find(id)?.asset else { throw Deliver.Failure("notFound") }
        guard inScope(found, link) else { throw Deliver.Failure("scope") }
        return found
    }

    private func versions(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> [Deliver.Version] {
        link.latestOnly ? [asset.current] : asset.versions
    }

    private func version(_ message: [String: Any], _ link: Deliver.ShareLink) throws -> (Deliver.Asset, Deliver.Version) {
        let asset = try asset(message["asset"], link)
        guard let id = (message["version"] as? String).flatMap(UUID.init(uuidString:)) else { throw Deliver.Failure("invalid") }
        guard let version = versions(asset, link).first(where: { $0.id == id }) else {
            throw Deliver.Failure(asset.versions.contains { $0.id == id } ? "scope" : "notFound")
        }
        return (asset, version)
    }

    private func comment(_ value: Any?, _ link: Deliver.ShareLink) throws -> Deliver.Comment {
        guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { throw Deliver.Failure("invalid") }
        guard let found = store.comment(id) else { throw Deliver.Failure("notFound") }
        guard let asset = store.find(found.asset)?.asset, inScope(asset, link), versions(asset, link).contains(where: { $0.id == found.version }) else {
            throw Deliver.Failure("scope")
        }
        // (An internal comment doesn't exist for a client link.)
        guard visible(found, link) else { throw Deliver.Failure("notFound") }
        return found
    }

    func list(_ folderText: String?, _ link: Deliver.ShareLink) throws -> [String: Any] {
        let project = link.project, content = store.content(project)
        var rootFolder: UUID?
        switch link.scope {
        case .asset(let id, _):
            guard folderText == nil, let asset = store.find(id)?.asset else { throw Deliver.Failure("scope") }
            return ["path": [], "folders": [], "assets": [summary(asset, link)]]
        case .assets(let ids, _):
            guard folderText == nil else { throw Deliver.Failure("scope") }
            return ["path": [], "folders": [], "assets": ids.compactMap { store.find($0)?.asset }.map { summary($0, link) }]
        case .folder(let id, _): rootFolder = id
        case .project: rootFolder = nil
        }
        var folder = rootFolder
        if let folderText {
            guard let id = UUID(uuidString: folderText) else { throw Deliver.Failure("invalid") }
            guard content.folders.contains(where: { $0.id == id }) else { throw Deliver.Failure("notFound") }
            if let rootFolder, !store.subfolders(rootFolder, in: project).contains(id) { throw Deliver.Failure("scope") }
            folder = id
        }
        // The path from the link's root down to this folder.
        var path: [[String: Any]] = rootFolder == nil ? [["id": project.uuidString, "name": store.project(project)?.name ?? ""]] : []
        let chain = store.folderPath(folder, in: project)
        let start = rootFolder.flatMap { root in chain.firstIndex { $0.id == root } } ?? 0
        path += chain[start...].map { ["id": $0.id.uuidString, "name": $0.name] }
        let folders = content.folders.filter { $0.parent == folder }.map { sub -> [String: Any] in
            let inside = store.subfolders(sub.id, in: project)
            return ["id": sub.id.uuidString, "name": sub.name, "count": content.assets.filter { $0.folder.map(inside.contains) == true }.count]
        }
        return ["path": path, "folders": folders, "assets": content.assets.filter { $0.folder == folder }.map { summary($0, link) }]
    }

    private func ready(_ version: Deliver.Version) -> [String]? {
        if case .ready(let renditions) = version.copy { return renditions }
        return nil
    }

    /// The asset's fields a link shows (§6.1: only those in `link.fields`; status goes as `status`).
    private func fields(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> [String: Any] {
        let shown = link.isTeam ? Deliver.Fields.names : link.shownFields
        let fields = asset.fields ?? .init()
        var json: [String: Any] = [:]
        if shown.contains("rating"), let rating = fields.rating { json["rating"] = rating }
        if shown.contains("keywords"), let keywords = fields.keywords { json["keywords"] = keywords }
        if shown.contains("assignee"), let assignee = fields.assignee { json["assignee"] = assignee }
        if shown.contains("due"), let due = fields.due { json["due"] = due }
        if shown.contains("notes"), let notes = fields.notes { json["notes"] = notes }
        for (id, value) in asset.customFields ?? [:] where link.isTeam || shown.contains("cf:" + id) { json["cf:" + id] = value }
        return json
    }

    private func summary(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> [String: Any] {
        let current = asset.current
        var current_: [String: Any] = ["id": current.id.uuidString, "number": current.number, "added": Self.date(current.added), "duration": current.probe?.duration ?? 0,
                                       "fpsNum": current.probe?.fpsNum ?? 25, "fpsDen": current.probe?.fpsDen ?? 1, "ready": ready(current) != nil,
                                       "comments": store.comments(asset.id, version: current.id).filter { visible($0, link) }.count]
        if let pages = current.pages { current_["pages"] = pages }
        return ["id": asset.id.uuidString, "name": asset.name, "kind": asset.kind.rawValue, "status": asset.status.rawValue,
                "current": current_, "versions": versions(asset, link).count, "fields": fields(asset, link)]
    }

    private func wire(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> [String: Any] {
        // (The folder lets the viewer's Back return to it; a folder outside the link's scope is never named.)
        ["id": asset.id.uuidString, "name": asset.name, "kind": asset.kind.rawValue, "status": asset.status.rawValue,
         "folder": visibleFolder(asset, link).map { $0.uuidString as Any } ?? NSNull(), "fields": fields(asset, link),
         "versions": versions(asset, link).map { version -> [String: Any] in
             let probe = version.probe
             var item: [String: Any] = ["id": version.id.uuidString, "number": version.number, "added": Self.date(version.added),
                                        "duration": probe?.duration ?? 0, "fpsNum": probe?.fpsNum ?? 25, "fpsDen": probe?.fpsDen ?? 1,
                                        "width": probe?.width ?? 0, "height": probe?.height ?? 0, "startTimecode": probe?.startTimecode ?? "00:00:00:00",
                                        "dropFrame": probe?.dropFrame ?? false, "frames": probe?.frames ?? 1,
                                        // (A burned-in watermark plays its own copies: the H.264 ladder only, no 4K.)
                                        "renditions": (ready(version) ?? []).filter { link.watermark?.burned != true || !$0.hasPrefix("2160") },
                                        "ready": ready(version) != nil, "canDownload": link.allowDownload, "size": link.allowDownload ? version.size : 0,
                                        "canProxy": link.allowProxy == true && ready(version)?.contains("1080") == true]
             if let pages = version.pages { item["pages"] = pages }
             let folder = store.copies(version.id)
             for (name, file) in [("waveform", "waveform.json"), ("captions", "captions.vtt"), ("transcript", "transcript.json")] {
                 item["has" + name.prefix(1).uppercased() + name.dropFirst()] = FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
             }
             return item
         }]
    }

    private func visibleFolder(_ asset: Deliver.Asset, _ link: Deliver.ShareLink) -> UUID? {
        switch link.scope {
        case .project: asset.folder
        case .folder(let root, let project): asset.folder.flatMap { store.subfolders(root, in: project).contains($0) ? $0 : nil }
        case .asset, .assets: nil
        }
    }

    /// §1's comment with `authorToken` turned into `mine`, reactions in their wire form, and no `link`.
    func wire(_ comment: Deliver.Comment, _ peer: Peer?) -> [String: Any] {
        guard let data = try? Deliver.encoder.encode(comment), var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        json["authorToken"] = nil
        json["link"] = nil
        json["frame"] = comment.frame ?? NSNull()
        json["endFrame"] = comment.endFrame ?? NSNull()
        json["internal"] = comment.isInternal
        json["mine"] = peer?.token != nil && comment.authorToken == peer?.token
        json["reactions"] = Self.reactions(comment, mine: peer?.token ?? "owner")
        // An internal reply goes to team links only (as on the helper): a client keeps the thread without it.
        let team = peer.map { store.link($0.link)?.isTeam == true } ?? true
        json["replies"] = comment.replies.filter { team || !$0.isInternal }.map { reply -> [String: Any] in
            var wire: [String: Any] = ["id": reply.id.uuidString, "text": reply.text, "author": reply.author, "created": Self.date(reply.created),
                                       "mine": peer?.token != nil && reply.authorToken == peer?.token]
            if reply.isInternal { wire["internal"] = true }
            if let mentions = reply.mentions, !mentions.isEmpty { wire["mentions"] = mentions }
            return wire
        }
        return json
    }

    /// [{"emoji","count","mine"}] in the fixed order.
    static func reactions(_ comment: Deliver.Comment, mine: String) -> [[String: Any]] {
        Deliver.Comment.emoji.compactMap { emoji in
            guard let who = comment.reactions?[emoji], !who.isEmpty else { return nil }
            return ["emoji": emoji, "count": who.count, "mine": who.contains(mine)]
        }
    }

    nonisolated static func date(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: - Fetches (the helper reads the file and sends the bytes on `media`)

    static let fetchLimit = 4, stillsPerMinute = 60
    /// Tests and DeliverLink: makes a link's burned-in copies when asked for one that isn't there yet.
    @ObservationIgnored var markMaker: ((_ asset: UUID, _ version: UUID, _ link: UUID) -> Void)?

    private func fetch(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        if message["what"] as? String == "proof" { return try proof(peer, id, message, link) }
        let (asset, version) = try version(message, link)
        guard peer.fetches.count < Self.fetchLimit else { throw Deliver.Failure("limit") }
        let what = message["what"] as? String ?? ""
        let plain = store.copies(version.id)
        var folder = plain
        // A link with a burned-in watermark plays and downloads its own copies (never the plain ones).
        if link.watermark?.burned == true, ["index", "init", "segment", "poster", "strip", "image", "proxy"].contains(what), ready(version) != nil {
            folder = DeliverCopies.marked(plain, link: link.id)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) else {
                markMaker?(asset.id, version.id, link.id)
                throw Deliver.Failure("notReady", progress: 0)
            }
        }
        var pieces: [(path: String, offset: Int64, length: Int64)] = []
        var type = "application/octet-stream"
        var extra: [String: Any] = [:]
        func file(_ url: URL, _ kind: String) throws {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { throw Deliver.Failure("notFound") }
            pieces = [(url.path, 0, size)]
            type = kind
        }
        func inline(_ url: URL) throws -> [String: Any] {
            guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else { throw Deliver.Failure("notFound") }
            return ["json": json]
        }
        switch what {
        case "original":
            guard link.allowDownload, let original = store.original(version) else { throw Deliver.Failure(link.allowDownload ? "notFound" : "scope") }
            try file(original, "application/octet-stream")
            extra["name"] = "\(asset.name) v\(version.number).\(original.pathExtension)"
        case "waveform": return reply(peer, id, try inline(plain.appendingPathComponent("waveform.json")))
        case "transcript": return reply(peer, id, try inline(plain.appendingPathComponent("transcript.json")))
        case "captions": try file(plain.appendingPathComponent("captions.vtt"), "text/vtt")
        case "attachment":
            guard let attachment = (message["attachment"] as? String).flatMap(UUID.init(uuidString:)) else { throw Deliver.Failure("invalid") }
            guard let found = store.comments(asset.id, version: version.id).first(where: { visible($0, link) && $0.attachments?.contains { $0.id == attachment } == true }),
                  let item = found.attachments?.first(where: { $0.id == attachment }) else { throw Deliver.Failure("notFound") }
            try file(attachmentsFolder.appendingPathComponent(attachment.uuidString), item.type)
            extra["name"] = item.name
        case "still":
            guard let frame = message["frame"] as? Int, frame >= 0, frame < max(version.probe?.frames ?? 1, 1) else { throw Deliver.Failure("invalid") }
            peer.stills = peer.stills.filter { Date.now.timeIntervalSince($0) < 60 }
            guard peer.stills.count < Self.stillsPerMinute else { throw Deliver.Failure("limit") }
            peer.stills.append(.now)
            peer.fetches.insert(id)
            Task {
                guard let made = await still(asset, version, frame), let size = (try? FileManager.default.attributesOfItem(atPath: made.path)[.size] as? NSNumber)?.int64Value else {
                    peer.fetches.remove(id)
                    return fail(peer, id, .init("notFound"))
                }
                serve(peer, id, [(made.path, 0, size)], type: "image/jpeg", extra: [:])
            }
            return
        default:
            guard let renditions = ready(version) else {
                if case .making(let share) = version.copy { throw Deliver.Failure("notReady", progress: share) }
                throw Deliver.Failure("notReady", progress: 0)
            }
            switch what {
            case "index", "init", "segment":
                guard let rendition = message["rendition"] as? String, renditions.contains(rendition),
                      let index = DeliverCopies.index(folder.appendingPathComponent(rendition)) else { throw Deliver.Failure("invalid") }
                let base = folder.appendingPathComponent(rendition)
                if what == "index" {
                    let data = try Deliver.encoder.encode(index)
                    return reply(peer, id, ["json": (try JSONSerialization.jsonObject(with: data))])
                }
                type = rendition == "a" ? "audio/mp4" : "video/mp4"
                if what == "init" {
                    pieces = [(base.appendingPathComponent(index.`init`.file).path, index.`init`.offset, index.`init`.length)]
                } else {
                    guard let n = message["n"] as? Int, index.segments.indices.contains(n) else { throw Deliver.Failure("invalid") }
                    let segment = index.segments[n]
                    pieces = [(base.appendingPathComponent(segment.file).path, segment.offset, segment.length)]
                }
            case "proxy":
                // The 1080 copy's init and every segment back to back: a plain MP4 (§6.1).
                guard link.allowProxy == true else { throw Deliver.Failure("scope") }
                guard renditions.contains("1080"), let index = DeliverCopies.index(folder.appendingPathComponent("1080")) else { throw Deliver.Failure("invalid") }
                pieces = DeliverCopies.proxyPieces(index, folder: folder.appendingPathComponent("1080"))
                type = "video/mp4"
                extra["name"] = "\(asset.name) v\(version.number) (review).mp4"
            case "poster", "strip":
                guard asset.kind == .video else { throw Deliver.Failure("invalid") }
                try file(folder.appendingPathComponent(what + ".jpg"), "image/jpeg")
            case "image":
                guard asset.kind == .image else { throw Deliver.Failure("invalid") }
                try file(folder.appendingPathComponent("image.jpg"), "image/jpeg")
            case "page":
                guard asset.kind == .document, let n = message["n"] as? Int, (1...max(version.pages ?? 0, 1)).contains(n), version.pages != nil else { throw Deliver.Failure("invalid") }
                try file(plain.appendingPathComponent("pages/\(n).jpg"), "image/jpeg")
            default:
                throw Deliver.Failure("invalid")
            }
        }
        peer.fetchWhat[id] = (what, asset.id, version.id)
        serve(peer, id, pieces, type: type, extra: extra)
    }

    /// An approval proof (§13.8): for an approval in scope made through this link (team links: any); `notReady` while hashing.
    private func proof(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        guard peer.fetches.count < Self.fetchLimit else { throw Deliver.Failure("limit") }
        guard let approvalID = (message["approval"] as? String).flatMap(UUID.init(uuidString:)),
              let approval = store.approvals(link.project).first(where: { $0.id == approvalID }) else { throw Deliver.Failure("notFound") }
        guard let asset = store.find(approval.asset)?.asset, inScope(asset, link), link.isTeam || approval.link == link.id else { throw Deliver.Failure("scope") }
        let url = try DeliverProof.file(for: approval, store: store, servedBy: Host.current().localizedName ?? "Mac")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { throw Deliver.Failure("notFound") }
        serve(peer, id, [(url.path, 0, size)], type: "application/pdf", extra: ["name": DeliverProof.fileName(approval, asset: asset)])
    }

    /// The answer, then the helper's `serve` (one piece as §5; several, a proxy, as `pieces`, §6.1).
    private func serve(_ peer: Peer, _ id: Int, _ pieces: [(path: String, offset: Int64, length: Int64)], type: String, extra: [String: Any]) {
        peer.fetches.insert(id)
        let size = pieces.reduce(Int64(0)) { $0 + $1.length }
        reply(peer, id, extra.merging(["fetch": id, "size": size, "type": type]) { $1 })
        if pieces.count == 1, let piece = pieces.first {
            output(["serve": ["peer": peer.id, "fetch": id, "path": piece.path, "offset": piece.offset, "length": piece.length]])
        } else {
            output(["serve": ["peer": peer.id, "fetch": id, "pieces": pieces.map { ["path": $0.path, "offset": $0.offset, "length": $0.length] }]])
        }
    }

    /// A JPEG of one frame, ≤ 1920 px, from the original (or the copy's picture), in Review/Stills (old ones go).
    private func still(_ asset: Deliver.Asset, _ version: Deliver.Version, _ frame: Int) async -> URL? {
        if let stillMaker { return await stillMaker(version, frame) }
        let folder = store.root.appendingPathComponent("Stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date.now.timeIntervalSince(date) > 600 {
                try? FileManager.default.removeItem(at: old)
            }
        }
        let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        if asset.kind == .image || asset.kind == .document {
            let source = asset.kind == .image ? store.copies(version.id).appendingPathComponent("image.jpg") : store.copies(version.id).appendingPathComponent("pages/1.jpg")
            return (try? FileManager.default.copyItem(at: source, to: out)) != nil ? out : nil
        }
        guard let original = store.original(version) ?? Optional(store.copies(version.id).appendingPathComponent("poster.jpg")) else { return nil }
        let probe = version.probe
        let seconds = (Double(frame) + 0.5) * Double(probe?.fpsDen ?? 1) / Double(probe?.fpsNum ?? 25)
        return await DeliverExport.frame(original, seconds: seconds, maxSide: 1920, into: out) ? out : nil
    }

    // MARK: - Uploads (§6.1: browser → Mac on the media channel; the helper writes, Swift checks and files)

    static let uploadCredit = 8_388_608, attachmentBytes: Int64 = 50_000_000, uploadsPerLink = 4

    /// A file name from a browser made safe for one folder: no paths, no leading dots, no control characters.
    nonisolated static func safeName(_ name: String) -> String {
        var clean = Deliver.clean(name, limit: 200).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        while clean.hasPrefix(".") || clean.hasPrefix("-") || clean.hasPrefix(" ") { clean.removeFirst() }
        return String(clean.prefix(120))
    }

    private func uploadBegin(_ peer: Peer, _ id: Int, _ message: [String: Any], _ link: Deliver.ShareLink) throws {
        guard let uploads = link.uploads else { throw Deliver.Failure("scope") }
        let attachment = message["for"] as? String == "attachment"
        guard let size = (message["size"] as? NSNumber)?.int64Value, size > 0, let raw = message["name"] as? String else { throw Deliver.Failure("invalid") }
        let name = Self.safeName(raw)
        guard !name.isEmpty else { throw Deliver.Failure("invalid") }
        if attachment {
            guard size <= Self.attachmentBytes else { throw Deliver.Failure("tooLarge") }
        } else {
            guard size <= uploads.maxBytes else { throw Deliver.Failure("tooLarge") }
            guard uploads.types.contains(DeliverStore.kind(URL(fileURLWithPath: name)).rawValue) else { throw Deliver.Failure("scope") }
        }
        guard peers.values.filter({ $0.link == link.id }).reduce(0, { $0 + $1.uploads.count }) < Self.uploadsPerLink else { throw Deliver.Failure("limit") }
        let parts = uploadsFolder.appendingPathComponent("\(link.id.uuidString)/.parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let part = parts.appendingPathComponent("\(peer.id)-\(id).part")
        peer.uploads[id] = Upload(id: id, name: name, size: size, type: Deliver.clean(message["type"] as? String ?? "", limit: 100), attachment: attachment, part: part)
        // (The helper must know the upload before the browser starts sending.)
        output(["accept": ["peer": peer.id, "upload": id, "path": part.path, "size": size]])
        reply(peer, id, ["upload": id, "credit": Self.uploadCredit])
    }

    /// Once the helper has written every byte and the browser has said `upload-end`: the hash checked, the file filed.
    private func finish(_ peer: Peer, _ upload: Upload) {
        if upload.written == false {
            peer.uploads[upload.id] = nil
            try? FileManager.default.removeItem(at: upload.part)
            if let end = upload.end { fail(peer, end.id, .init("invalid")) }
            return
        }
        guard upload.written == true, let end = upload.end, let link = store.link(peer.link) else { return }
        peer.uploads[upload.id] = nil
        let part = upload.part
        Task {
            let sha = if let known = upload.helperSHA { known } else { await Task.detached { DeliverServer.sha256(of: part) }.value }
            guard sha == end.sha else {
                try? FileManager.default.removeItem(at: part)
                return fail(peer, end.id, .init("invalid"))
            }
            do {
                if upload.attachment {
                    let item = Deliver.Comment.Attachment(name: upload.name, size: upload.size, type: upload.type.isEmpty ? "application/octet-stream" : upload.type)
                    try FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: part, to: attachmentsFolder.appendingPathComponent(item.id.uuidString))
                    peer.attachments[item.id] = item
                    reply(peer, end.id, ["attachment": ["id": item.id.uuidString, "name": item.name, "size": item.size, "type": item.type]])
                    return
                }
                let target = Self.unique(uploadsFolder.appendingPathComponent(link.id.uuidString, isDirectory: true).appendingPathComponent(upload.name))
                try FileManager.default.moveItem(at: part, to: target)
                let folder = uploadFolder(link)
                guard let made = try store.add([target], to: link.project, folder: folder).first else { throw Deliver.Failure("invalid") }
                reply(peer, end.id, ["asset": summary(made, link)])
                log(peer, "uploaded", asset: made.id, version: made.current.id, detail: .init(name: upload.name))
                inbox(made.current.id, "upload", made, made.current.id, upload.name, peer, link)
            } catch let failure as Deliver.Failure {
                fail(peer, end.id, failure)
            } catch {
                fail(peer, end.id, .init("internal"))
            }
        }
    }

    /// Where a link's uploads go: its chosen folder when that's in the project, else the folder it shares, else the top.
    private func uploadFolder(_ link: Deliver.ShareLink) -> UUID? {
        let folders = store.content(link.project).folders
        if let chosen = link.uploads?.folder, folders.contains(where: { $0.id == chosen }) { return chosen }
        if case .folder(let id, _) = link.scope { return id }
        return nil
    }

    nonisolated static func unique(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }

    /// base64url SHA-256 of a file, read 1 MiB at a time.
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return DeliverKeys.base64url(Data(hasher.finalize()))
    }

    // MARK: - Events

    private func heard(_ event: DeliverStore.Event) {
        switch event {
        case .comment(let op, let comment):
            broadcast(asset: comment.asset) { peer, link in
                self.visible(comment, link) && self.shown(comment, link) ? ["t": "comment", "op": op, "comment": self.wire(comment, peer)] : nil
            }
        case .commentDeleted(let comment):
            broadcast(asset: comment.asset) { _, link in
                self.visible(comment, link) && self.shown(comment, link) ? ["t": "comment", "op": "delete",
                                               "comment": ["id": comment.id.uuidString, "asset": comment.asset.uuidString, "version": comment.version.uuidString]] : nil
            }
        case .status(let asset, let status, let by):
            let approval = store.lastApproval.removeValue(forKey: asset)
            broadcast(asset: asset) { _, _ in
                var event: [String: Any] = ["t": "status", "asset": asset.uuidString, "status": status.rawValue, "by": by]
                if let approval { event["approval"] = approval.uuidString }
                return event
            }
        case .assetChanged(let asset): broadcast(asset: asset) { _, _ in ["t": "asset-changed", "asset": asset.uuidString] }
        case .field(let asset, let field, let by): if let found = store.find(asset)?.asset { broadcastField(found, field, by: by) }
        case .linkOff(let link):
            for peer in peers.values where peer.link == link.id {
                send(peer, ["t": "bye", "code": "revoked"])
                close(peer, "revoked")
            }
        case .linksChanged:
            deadlinesChanged()
            // A link run out or paused ends its sessions too.
            for peer in peers.values {
                let link = store.link(peer.link)
                // A password set or changed since this session got in ends it too.
                let passwordChanged = peer.stage == .ready && link.map { $0.passwordHash != peer.admittedHash } == true
                guard link?.isLive != true || link?.isPaused == true || passwordChanged else { continue }
                let code = link?.revoked != nil || link == nil ? "revoked" : link?.isPaused == true ? "paused" : link?.isLive != true ? "expired" : "password"
                send(peer, ["t": "bye", "code": code])
                close(peer, code)
            }
        }
    }

    private func broadcastField(_ asset: Deliver.Asset, _ field: String, by: String) {
        let value = fields(asset, .init(title: "", scope: .project(UUID()), roomID: "", audience: "team"))[field] ?? NSNull()
        broadcast(asset: asset.id) { _, link in
            link.isTeam || link.shownFields.contains(field) ? ["t": "field", "asset": asset.id.uuidString, "field": field, "value": value, "by": by] : nil
        }
    }

    /// To every ready browser whose link holds the asset (for a removed asset: those of its project).
    private func broadcast(asset id: UUID, _ message: (Peer, Deliver.ShareLink) -> [String: Any]?) {
        let found = store.find(id)?.asset
        for peer in peers.values where peer.stage == .ready {
            guard let link = store.link(peer.link) else { continue }
            if let found { guard inScope(found, link) else { continue } }
            if let body = message(peer, link) { send(peer, body) }
        }
    }

    private func presence(_ link: UUID) {
        let ready = peers.values.filter { $0.link == link && $0.stage == .ready }
        let viewers = ready.map { peer -> [String: Any] in
            ["peer": peer.id, "name": peer.name, "asset": peer.viewing?.uuidString ?? NSNull()]
        }
        for peer in ready { send(peer, ["t": "presence", "viewers": viewers]) }
    }
}

/// Notifications for what clients wrote (§8): "New comment on Hero 30s", "Hero 30s v3 approved", one per
/// asset per minute, none while Pluck is in front on the Deliver page (only the inbox badge changes).
@MainActor
enum DeliverNotify {
    static let assetKey = "reviewAsset", versionKey = "reviewVersion", commentKey = "reviewComment"
    private static var last: [UUID: Date] = [:]

    static func post(_ item: Deliver.InboxItem, assetName: String, versionNumber: Int?) {
        if NSApp.isActive, StudioNavigator.shared.page == .deliver { return }
        if let at = last[item.asset], Date.now.timeIntervalSince(at) < 60 { return }
        last[item.asset] = .now
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        if item.kind == "approval" {
            content.title = item.summary == "approved" ? String(localized: "\(assetName) v\(versionNumber ?? 1) approved")
                : String(localized: "\(assetName) v\(versionNumber ?? 1) needs changes")
        } else {
            content.title = String(localized: "New comment on \(assetName)")
            content.body = String(item.summary.prefix(100))
        }
        content.userInfo = [assetKey: item.asset.uuidString, versionKey: item.version.uuidString, commentKey: item.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-" + item.asset.uuidString, content: content, trigger: nil))
    }

    /// "Anna opened “Spring – cuts”" (opt-in per link).
    static func opened(_ link: Deliver.ShareLink, by name: String) {
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? String(localized: "“\(link.title)” was opened") : String(localized: "\(name) opened “\(link.title)”")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-open-" + link.id.uuidString, content: content, trigger: nil))
    }

    // MARK: @mentions (4.1.0)

    /// This Mac's person on the team: the one whose name is the owner's comment name (as "Assigned to Me" matches).
    static func me(team: [Deliver.Person]? = nil, name: String? = nil) -> String? {
        let name = name ?? DeliverSettings.author
        return (team ?? DeliverPeople.shared.team).first { ($0.name ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// What in `after` mentions `me` and wasn't there in `before`: the comment itself when new, else a new reply.
    nonisolated static func newMention(of me: String, before: Deliver.Comment?, after: Deliver.Comment) -> (author: String, text: String)? {
        if before == nil, after.mentions?.contains(me) == true { return (after.author, after.text) }
        let old = Set(before?.replies.map(\.id) ?? [])
        return after.replies.last { !old.contains($0.id) && $0.mentions?.contains(me) == true }.map { ($0.author, $0.text) }
    }

    /// "You were mentioned on Hero 30s" for a comment or reply that @mentions this Mac's person (not on a muted link).
    static func mentioned(before: Deliver.Comment?, after: Deliver.Comment, store: DeliverStore? = nil) {
        let store = store ?? .shared
        guard let me = me(), let said = newMention(of: me, before: before, after: after),
              after.link.flatMap(store.link)?.muted != true, let name = store.find(after.asset)?.asset.name else { return }
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "You were mentioned on \(name)")
        content.body = String("\(said.author): \(said.text)".prefix(140))
        content.userInfo = [assetKey: after.asset.uuidString, versionKey: after.version.uuidString, commentKey: after.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-mention-" + after.id.uuidString + "-\(after.replies.count)", content: content, trigger: nil))
    }

    static func locked(_ link: Deliver.ShareLink) {
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "“\(link.title)” is locked for an hour")
        content.body = String(localized: "Someone tried the wrong password too many times.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-lock-" + link.id.uuidString, content: content, trigger: nil))
    }
}
