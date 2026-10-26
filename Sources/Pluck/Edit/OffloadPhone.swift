import Foundation
import Network
import Security
import SwiftUI

/// Offload on a phone: a small page on this network that shows the offloads, how far they are,
/// each drive's speed, problems and today's totals.
///
/// How it stays closed:
/// - Off until it's turned on, and never kept on: quitting Pluck or turning it off stops it.
/// - Only private addresses and this Mac get an answer (the same rule as Edit Anywhere); anyone
///   else is hung up on before a byte is read.
/// - Every address needs a random secret (32 bytes) that's new each time it's turned on.
/// - GET only, and only the page and its status: no files, nothing that changes anything.
/// - Small requests only, a few at a time, and each one gets ten seconds.
@MainActor
@Observable
final class OffloadPhone {
    static let shared = OffloadPhone()

    /// Serving the page. Turning it on makes a new link.
    var on: Bool {
        get { isOn }
        set { newValue ? start() : stop() }
    }

    /// The address to open on a phone (nil while starting, or with no network).
    var link: URL? {
        guard let port, let path, let address = LibraryServer.localIPAddress() else { return nil }
        return URL(string: "http://\(address):\(port)\(path)")
    }

    /// The port it listens on, once it does.
    private(set) var port: UInt16?
    private(set) var problem: String?
    private var isOn = false

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var session: Session?

    /// The page's own path ("/<secret>/"), while it's on.
    var path: String? { session.map { "/\($0.token)/" } }

    nonisolated static let maxRequest = 8 * 1024
    nonisolated static let maxConnections = 16
    nonisolated static let timeout: TimeInterval = 10
    nonisolated private static let queue = DispatchQueue(label: "be.wideopen.pluck.offload-phone")

    private init() {}

    private func start() {
        guard listener == nil else { return }
        problem = nil
        let session = Session(token: Self.newToken())
        guard let listener = try? NWListener(using: .tcp, on: .any) else {
            problem = String(localized: "Pluck couldn’t start the phone page.")
            return
        }
        listener.newConnectionHandler = { @Sendable connection in Self.accept(connection, session) }
        listener.stateUpdateHandler = { @Sendable [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, listener === self.listener else { return }
                self.changed(state, listener)
            }
        }
        self.listener = listener
        self.session = session
        isOn = true
        listener.start(queue: Self.queue)
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        session?.close()
        session = nil
        port = nil
        isOn = false
    }

    private func changed(_ state: NWListener.State, _ listener: NWListener) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
        case .failed(let error):
            stop()
            problem = error.localizedDescription
        default:
            break
        }
    }

    /// 32 random bytes, base64url without padding (43 characters).
    nonisolated static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Who may get an answer: Edit Anywhere's rule (the local network, this Mac, VPNs on private
    /// ranges and Tailscale's 100.64.0.0/10). Anything on the internet is refused.
    nonisolated static func allows(_ host: NWEndpoint.Host) -> Bool { OfficeLink.isPrivate(host) }

    // MARK: - One time on

    /// The secret and the open connections of one time it's on.
    final class Session: @unchecked Sendable {
        let token: String
        private let lock = NSLock()
        private var open: [ObjectIdentifier: NWConnection] = [:]
        private var closed = false

        init(token: String) { self.token = token }

        /// Room for one more (false once it's off, or with too many open).
        func admit(_ connection: NWConnection) -> Bool {
            lock.withLock {
                guard !closed, open.count < OffloadPhone.maxConnections else { return false }
                open[ObjectIdentifier(connection)] = connection
                return true
            }
        }

        func drop(_ connection: NWConnection) {
            lock.withLock { _ = open.removeValue(forKey: ObjectIdentifier(connection)) }
        }

        var isOpen: Bool { lock.withLock { !closed } }

        func close() {
            let all = lock.withLock {
                closed = true
                defer { open.removeAll() }
                return Array(open.values)
            }
            for connection in all { connection.cancel() }
        }

        /// The secret, compared in the same time however much of it is right.
        func matches(_ candidate: Substring) -> Bool {
            let a = Array(token.utf8), b = Array(candidate.utf8)
            var difference = a.count ^ b.count
            for index in a.indices { difference |= Int(a[index] ^ (index < b.count ? b[index] : 0)) }
            return difference == 0
        }
    }

    // MARK: - Requests (on the listener's queue)

    nonisolated private static func accept(_ connection: NWConnection, _ session: Session) {
        // The address is checked before anything is read.
        guard case .hostPort(let host, _) = connection.endpoint, allows(host), session.admit(connection) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { @Sendable state in
            switch state {
            case .failed, .cancelled:
                session.drop(connection)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Slow or idle: gone after ten seconds, answered or not.
        queue.asyncAfter(deadline: .now() + timeout) { connection.cancel() }
        read(connection, session, Data())
    }

    nonisolated private static func read(_ connection: NWConnection, _ session: Session, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequest) { @Sendable data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)), end.lowerBound <= maxRequest {
                route(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection, session)
            } else if complete || error != nil || buffer.count > maxRequest {
                connection.cancel()
            } else {
                read(connection, session, buffer)
            }
        }
    }

    /// What a request gets, from its first line.
    nonisolated static func answer(to head: String, _ session: Session) -> Answer {
        // "\r\n" is one Character in Swift, so lines are split on any line break.
        let line = (head.split(whereSeparator: \.isNewline).first ?? "").split(separator: " ")
        guard line.count == 3, line[2].hasPrefix("HTTP/1."), line[1].hasPrefix("/") else { return .code(400) }
        guard line[0] == "GET" else { return .code(405) }
        let target = line[1].prefix { $0 != "?" && $0 != "#" }.dropFirst()
        let parts = target.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let secret = parts.first, !secret.isEmpty else { return .code(404) }
        guard session.matches(secret) else { return .code(403) }
        guard parts.count == 2 else { return .moved("/\(session.token)/") }
        switch parts[1] {
        case "": return .page
        case "status.json": return .json
        default: return .code(404)
        }
    }

    enum Answer: Equatable, Sendable {
        case page, json, moved(String), code(Int)
    }

    nonisolated private static func route(_ head: String, _ connection: NWConnection, _ session: Session) {
        let reply = answer(to: head, session)
        switch reply {
        case .code(let code):
            send(connection, code, type: "text/plain; charset=utf-8", Data(reason(code).utf8))
        case .moved(let path):
            send(connection, 301, type: "text/plain; charset=utf-8", Data(), extra: ["Location": path])
        case .page, .json:
            let wantsPage = reply == .page
            Task { @MainActor in
                // Turned off (or on again, with a new secret) since: nothing.
                guard session.isOpen, OffloadPhone.shared.session === session else { return connection.cancel() }
                if wantsPage {
                    send(connection, 200, type: "text/html; charset=utf-8", OffloadPhone.page())
                } else {
                    let body = (try? JSONEncoder().encode(OffloadPhone.status())) ?? Data("{}".utf8)
                    send(connection, 200, type: "application/json", body)
                }
            }
        }
    }

    nonisolated private static func reason(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 301: "Moved Permanently"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    nonisolated private static func send(_ connection: NWConnection, _ code: Int, type: String, _ body: Data,
                                         extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(code) \(reason(code))\r\n"
        var fields = [
            "Content-Type": type,
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-store",
            "Connection": "close",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Robots-Tag": "noindex",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        ]
        if code == 405 { fields["Allow"] = "GET" }
        fields.merge(extra) { _, new in new }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { @Sendable _ in
            connection.cancel()
        })
    }

    // MARK: - What it shows

    struct Status: Codable, Sendable {
        struct Drive: Codable, Sendable {
            var name: String
            /// MB/s: now while copying, the run's average after.
            var speed: Double
        }

        struct Job: Codable, Sendable {
            var name: String
            var person: String?
            /// copying, queued, waiting, paused, done or stopped.
            var state: String
            var progress: Double
            var drives: [Drive]
            var problems: Int
            var finished: Bool

            enum CodingKeys: String, CodingKey {
                case name, person = "operator", state, progress, drives, problems, finished
            }
        }

        struct Today: Codable, Sendable {
            var cards = 0
            var bytes: Int64 = 0
            var hours: Double = 0
            var problems = 0
        }

        var project: String?
        var jobs: [Job]
        var today: Today
    }

    /// The offloads still under way and today's, newest first, and today's totals for the
    /// project cards go into (or for every card today, without one).
    static func status(now: Date = .now) -> Status {
        let center = OffloadCenter.shared, projects = OffloadProjects.shared
        let day = OffloadWrap.range(of: now)
        let shown = center.jobs.filter { $0.finished == nil || day.contains($0.started) || $0.finished.map(day.contains) == true }
        let jobs = shown.prefix(30).map { job -> Status.Job in
            let state = center.state(job)
            let done = center.live[job.id]?.bytes ?? job.workDone
            let progress = job.work > 0 ? min(1, max(0, Double(done) / Double(job.work))) : (job.finished != nil ? 1 : 0)
            let names = job.speedNames.drives
            let live = state == .copying ? center.speedLive[job.id] : nil
            let drives = names.enumerated().compactMap { index, name -> Status.Drive? in
                let speed = live.map { index < $0.drives.count ? $0.drives[index].last ?? 0 : 0 } ?? job.speeds?[name] ?? 0
                return speed > 0 ? Status.Drive(name: name, speed: speed) : nil
            }
            let person = projects.project(job.project)?.operators.first { $0.id == job.operatorID }?.name
            return Status.Job(name: job.displayName, person: person, state: Self.word(state), progress: progress,
                              drives: drives, problems: job.problems.count, finished: job.finished != nil)
        }
        var today = Status.Today()
        if let project = projects.current {
            let stats = OffloadWrap.stats(project: project, jobs: center.jobs, days: day)
            today = Status.Today(cards: stats.cards, bytes: stats.bytes, hours: stats.duration / 3600, problems: stats.problems)
        } else {
            for job in center.jobs where day.contains(job.started) {
                today.cards += 1
                today.bytes += job.totalBytes
                today.problems += job.problems.count
                today.hours += (center.details(for: job.id)?.reduce(0) { $0 + ($1.duration ?? 0) } ?? 0) / 3600
            }
        }
        return Status(project: projects.current?.name, jobs: Array(jobs), today: today)
    }

    private static func word(_ state: OffloadCenter.State) -> String {
        switch state {
        case .copying: "copying"
        case .queued: "queued"
        case .waiting: "waiting"
        case .paused: "paused"
        case .done: "done"
        case .stopped: "stopped"
        }
    }

    /// The page: one file, its words in the Mac's language, nothing loaded from elsewhere.
    static func page() -> Data {
        let words: [String: String] = [
            "title": String(localized: "Offload"),
            "cards": String(localized: "Cards"),
            "size": String(localized: "Size"),
            "footage": String(localized: "Footage"),
            "problems": String(localized: "Problems"),
            "none": String(localized: "Nothing to show yet."),
            "lost": String(localized: "Can’t reach Pluck. Is the phone page still on?"),
            "copying": String(localized: "Copying"),
            "queued": String(localized: "Waiting"),
            "waiting": String(localized: "Waiting for a drive"),
            "paused": String(localized: "Paused"),
            "done": String(localized: "Done"),
            "stopped": String(localized: "Stopped"),
        ]
        let json = (try? JSONEncoder().encode(words)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let html = pageTemplate
            .replacingOccurrences(of: "{{lang}}", with: language.filter { $0.isLetter || $0 == "-" })
            .replacingOccurrences(of: "{{words}}", with: json.replacingOccurrences(of: "<", with: "\\u003c"))
        return Data(html.utf8)
    }

    private static let pageTemplate = #"""
    <!doctype html>
    <html lang="{{lang}}"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="referrer" content="no-referrer"><meta name="robots" content="noindex">
    <meta name="color-scheme" content="light dark">
    <title>Pluck</title>
    <style>
    :root{--bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--dim:#6e6e73;--track:#e5e5ea;--fill:#8f54f5;--good:#2f9e5f;--bad:#e5484d}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f2f2f7;--dim:#98989f;--track:#38383a;--fill:#a77bff;--good:#3dbd73;--bad:#ff6369}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:16px/1.35 -apple-system,system-ui,sans-serif;-webkit-text-size-adjust:100%;
      padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) 32px max(16px,env(safe-area-inset-left))}
    h1{font-size:24px;margin:8px 0 14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .today{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-bottom:18px}
    @media (min-width:520px){.today{grid-template-columns:repeat(4,1fr)}}
    .stat{background:var(--card);border-radius:12px;padding:10px 12px}
    .stat b{display:block;font-size:20px;font-variant-numeric:tabular-nums}
    .stat span{color:var(--dim);font-size:13px}
    .stat.bad b{color:var(--bad)}
    .job{background:var(--card);border-radius:16px;padding:14px;margin:0 0 10px}
    .top{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
    .name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .pct{font-variant-numeric:tabular-nums;color:var(--dim)}
    .meta{color:var(--dim);font-size:14px;margin-top:2px}
    .bar{height:8px;background:var(--track);border-radius:4px;overflow:hidden;margin:10px 0 8px}
    .bar i{display:block;height:100%;background:var(--fill);transition:width .4s}
    .done .bar i{background:var(--good)}
    .drives{display:flex;flex-wrap:wrap;gap:4px 14px;color:var(--dim);font-size:14px;font-variant-numeric:tabular-nums}
    .bad{color:var(--bad);font-weight:600}
    .problem{margin-top:6px}
    .note{color:var(--dim);text-align:center}
    </style></head><body>
    <h1 id="title"></h1>
    <div class="today" id="today"></div>
    <div id="jobs"></div>
    <p class="note" id="note"></p>
    <script id="words" type="application/json">{{words}}</script>
    <script>
    const W=JSON.parse(document.getElementById('words').textContent);
    function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
    function size(b){const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1000&&i<u.length-1){b/=1000;i++}return (i?b.toFixed(b<10?1:0):b)+' '+u[i]}
    function stat(value,label,bad){const d=el('div','stat'+(bad?' bad':''));d.append(el('b',null,value),el('span',null,label));return d}
    function draw(s){
      document.getElementById('title').textContent=s.project||W.title;
      const t=s.today;
      document.getElementById('today').replaceChildren(stat(String(t.cards),W.cards),stat(size(t.bytes),W.size),
        stat(t.hours.toFixed(1)+' h',W.footage),stat(String(t.problems),W.problems,t.problems>0));
      const list=document.getElementById('jobs');list.replaceChildren();
      if(!s.jobs.length)list.append(el('p','note',W.none));
      for(const j of s.jobs){
        const card=el('div','job'+(j.finished&&!j.problems?' done':''));
        const top=el('div','top');top.append(el('div','name',j.name),el('div','pct',Math.round(j.progress*100)+'%'));
        card.append(top,el('div','meta',[j.operator,W[j.state]||j.state].filter(Boolean).join(' · ')));
        const bar=el('div','bar'),fill=el('i');fill.style.width=(j.progress*100).toFixed(1)+'%';bar.append(fill);card.append(bar);
        if(j.drives.length){const d=el('div','drives');for(const x of j.drives)d.append(el('span',null,x.name+'  '+Math.round(x.speed)+' MB/s'));card.append(d)}
        if(j.problems)card.append(el('div','bad problem',W.problems+': '+j.problems));
        list.append(card);
      }
    }
    async function tick(){
      try{const r=await fetch('status.json',{cache:'no-store'});if(!r.ok)throw r.status;draw(await r.json());document.getElementById('note').textContent=''}
      catch(e){document.getElementById('note').textContent=W.lost}
    }
    tick();setInterval(tick,2000);
    </script></body></html>
    """#
}

// MARK: - On the Mac

/// "Show on My Phone": the switch, and while it's on the QR code and the link.
struct OffloadPhoneView: View {
    @State private var phone = OffloadPhone.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Toggle("Show on My Phone", isOn: Binding(get: { phone.on }, set: { phone.on = $0 }))
                .toggleStyle(.switch)
                .font(.headline)
            if let problem = phone.problem {
                ProblemLabel(text: problem)
            }
            if phone.on {
                if let link = phone.link, let qr = LibrarySharingView.qrCode(link.absoluteString) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(.white, in: .rect(cornerRadius: Design.Radius.box))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code for the phone page")
                    HStack(spacing: 6) {
                        Text(link.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy Link")
                    }
                } else if phone.port != nil {
                    Label("Connect this Mac to Wi-Fi or Ethernet.", systemImage: "wifi.slash").noteStyle()
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            Label("View only, on this network. A new link each time it’s turned on.", systemImage: "lock.shield")
                .noteStyle()
        }
        .padding(Design.Spacing.inset)
        .frame(width: 260)
    }
}
