import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Feedback deadlines (§13.9): a link's own, else its project's. From then on the link answers `deadline` (the
/// server's clock); the owner reopens it with a new deadline or none. Reminders here at T−3 d, T−1 d and at close,
/// each once per link, checked every 15 minutes and on wake.
@MainActor
final class DeliverDeadlines {
    static let shared = DeliverDeadlines(store: .shared, server: .shared)

    let store: DeliverStore
    let server: DeliverServer
    /// Tests: the reminder text instead of a notification.
    var posted: ((String) -> Void)?
    private var timer: Task<Void, Never>?

    init(store: DeliverStore, server: DeliverServer) {
        self.store = store
        self.server = server
    }

    static func effective(_ link: Deliver.ShareLink, store: DeliverStore) -> Date? {
        // (`distantFuture`: reopened with none while the project's own has passed.)
        let deadline = link.deadline ?? store.project(link.project)?.deadline
        return deadline == .distantFuture ? nil : deadline
    }

    func start() {
        guard timer == nil, ScreenshotMode.scene == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                // (Every 30 s: live browsers past a deadline are told; reminders every 15 minutes.)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Browsers past a deadline are closed; reminders that are due go out once.
    func check(now: Date? = nil) {
        let now = now ?? server.clock()
        server.deadlinesChanged()
        for link in store.links where link.isLive {
            guard let deadline = Self.effective(link, store: store) else { continue }
            var reminded = Set(link.reminded ?? [])
            // A link made after its deadline had passed reminds of nothing.
            if link.created >= deadline {
                if reminded.count < 3 { store.updateLink(link.id) { $0.reminded = ["3d", "1d", "closed"] } }
                continue
            }
            let due: String? = now >= deadline ? "closed" : now >= deadline.addingTimeInterval(-86400) ? "1d"
                : now >= deadline.addingTimeInterval(-3 * 86400) ? "3d" : nil
            guard let due, !reminded.contains(due) else { continue }
            let order = ["3d", "1d", "closed"]
            reminded.formUnion(order.prefix(through: order.firstIndex(of: due)!))
            store.updateLink(link.id) { $0.reminded = order.filter(reminded.contains) }
            remind(link, due)
        }
    }

    /// "Spring – cuts: feedback due in 3 days (4 open comments, not approved)", or at close the totals.
    func text(_ link: Deliver.ShareLink, _ due: String) -> String {
        let assets = store.content(link.project).assets.filter { server.inScope($0, link) }
        let comments = assets.flatMap { store.comments($0.id) }.filter { !$0.isInternal }
        let open = comments.filter { !$0.completed }.count
        let approved = assets.filter { $0.status == .approved }
        let state: String = assets.count == 1
            ? (approved.isEmpty ? String(localized: "not approved") : String(localized: "v\(approved[0].current.number) approved"))
            : String(localized: "\(approved.count) of \(assets.count) approved")
        switch due {
        case "closed": return String(localized: "\(link.title) closed: \(comments.count) comments, \(state)")
        case "1d": return String(localized: "\(link.title): feedback due tomorrow (\(open) open comments, \(state))")
        default: return String(localized: "\(link.title): feedback due in 3 days (\(open) open comments, \(state))")
        }
    }

    private func remind(_ link: Deliver.ShareLink, _ due: String) {
        let text = text(link, due)
        if let posted { return posted(text) }
        guard ScreenshotMode.scene == nil, link.muted != true else { return }
        let content = UNMutableNotificationContent()
        content.title = text
        content.categoryIdentifier = Notifications.deadlineCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-deadline-\(link.id.uuidString)-\(due)", content: content, trigger: nil))
    }

    /// "Reopen…": a new deadline (or none); its rev goes up, so it's saved and synced, and reminders start again.
    func reopen(_ link: UUID, deadline: Date?) {
        store.updateLink(link) { $0.deadline = deadline; $0.reminded = nil }
        if let project = store.link(link)?.project, let projectDeadline = store.project(project)?.deadline, projectDeadline <= server.clock(), deadline == nil {
            // (Without its own, the project's passed deadline would close it again.)
            store.updateLink(link) { $0.deadline = .distantFuture }
        }
        server.deadlinesChanged()
    }

    func isClosed(_ link: Deliver.ShareLink) -> Bool {
        Self.effective(link, store: store).map { $0 <= server.clock() } ?? false
    }
}

/// "Reopen…" / a deadline's picker: a date and time, or none.
struct DeliverDeadlineSheet: View {
    let title: LocalizedStringKey
    let initial: Date?
    let save: (Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var on = true
    @State private var date = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(7 * 86400)).addingTimeInterval(17 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            StudioSwitchRow(title: "Feedback deadline", isOn: $on)
            if on {
                DatePicker("", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden().fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Save") { save(on ? date : nil); dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 360)
        .background(Design.Studio.panel)
        .onAppear { if let initial, initial > .now, initial != .distantFuture { date = initial } }
    }
}
