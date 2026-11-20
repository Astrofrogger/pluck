import SwiftUI

/// Settings › Review › a host's Email section (4.1.0): shown only for a main host whose hello said `mail: 1`. The SMTP
/// password is typed here, kept in this Mac's Keychain and pushed with `mail-set`; the host sends the mail.
struct DeliverMailSection: View {
    let host: Deliver.Host
    @State private var mail = DeliverMail.shared
    @State private var store = DeliverStore.shared
    @State private var draft = DeliverMail.Settings()
    @State private var password = ""
    @State private var testTo = ""
    @State private var note: String?
    @State private var busy = false
    @State private var hookDrafts: [UUID: String] = [:]

    private var admin: Bool { DeliverPeople.isAdmin(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            VStack(spacing: 2) {
                SettingSwitch("Send email updates", isOn: $draft.enabled)
                SettingRow("Server") { TextField("smtp.example.com", text: $draft.server).settingField(width: 220) }
                SettingRow("Port") {
                    Picker(selection: $draft.port) { Text(verbatim: "465").tag(465); Text(verbatim: "587").tag(587) } label: { EmptyView() }.fixedSize()
                }
                SettingRow("Security") {
                    Picker(selection: $draft.security) { Text("TLS").tag("tls"); Text("STARTTLS").tag("starttls") } label: { EmptyView() }.fixedSize()
                }
                SettingRow("User") { TextField("", text: $draft.user).settingField(width: 220) }
                SettingRow("Password") { SecureField(mail.hasPassword ? "Saved" : "", text: $password).settingField(width: 220) }
                SettingRow("From") { TextField("updates@example.com", text: $draft.from).settingField(width: 220) }
                SettingRow("Reply to") { TextField("", text: $draft.replyTo).settingField(width: 220) }
                SettingRow("Daily summary at") {
                    Picker(selection: $draft.digestHour) { ForEach(0..<24, id: \.self) { Text(verbatim: String(format: "%02d:00", $0)).tag($0) } } label: { EmptyView() }.fixedSize()
                }
                SettingRow("Send a test to") {
                    HStack(spacing: 6) {
                        TextField(draft.from, text: $testTo).settingField(width: 160)
                        Button("Send Test") { Task { await test() } }.settingButton().disabled(busy)
                    }
                }
                HStack {
                    Button("Save") { Task { await save() } }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                if let note { Text(verbatim: note).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 14) }
                if let error = mail.lastError { Text(verbatim: error).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad).textSelection(.enabled).padding(.horizontal, 14) }
                if mail.queued > 0 { Text("\(mail.queued) emails waiting to go out").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.horizontal, 14) }
            }
            .studioBox()
            .disabled(!admin)
            Text("Subscribers").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            VStack(spacing: 0) {
                ForEach(mail.subscribers) { row in
                    SettingRow(text: Text(verbatim: row.name.isEmpty ? row.email : row.name),
                               detail: row.pending ? Text(row.name.isEmpty ? "Not confirmed yet" : "\(row.email) · not confirmed yet") : row.name.isEmpty ? nil : Text(verbatim: row.email)) {
                        Picker(selection: Binding(get: { row.mode }, set: { mode in Task { await setMode(row, mode) } })) {
                            Text("Instant").tag("instant"); Text("Daily").tag("daily"); Text("Off").tag("off")
                        } label: { EmptyView() }.fixedSize()
                        Button { Task { await remove(row) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
                if mail.subscribers.isEmpty { Text("None yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10) }
            }
            .studioBox()
            .disabled(!admin)
            if !store.projects.isEmpty {
                Text("Webhook").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                VStack(spacing: 0) {
                    ForEach(store.projects) { project in
                        SettingRow(text: Text(verbatim: project.name)) {
                            TextField("https://", text: Binding(get: { hookDrafts[project.id] ?? mail.hooks[project.id.uuidString] ?? "" }, set: { hookDrafts[project.id] = $0 }))
                                .settingField(width: 260).onSubmit { Task { await setHook(project.id) } }
                        }
                    }
                    Text("Comment text is sent to this address.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(10)
                }
                .studioBox()
                .disabled(!admin)
            }
        }
        .task { await mail.refresh(); draft = mail.settings }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let typed = password.isEmpty ? nil : password
        if let typed { DeliverMail.savePassword(typed, for: host.id) }
        note = await mail.push(draft, password: typed) ?? String(localized: "Saved.")
        if note == String(localized: "Saved.") { password = "" }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        let to = testTo.trimmingCharacters(in: .whitespaces).isEmpty ? draft.from : testTo
        let answer = await mail.ask(["op": "mail-test", "to": to])
        note = DeliverMail.errorText(answer) ?? String(localized: "Test sent.")
        await mail.refresh()
    }

    private func setMode(_ row: DeliverMail.Subscriber, _ mode: String) async {
        _ = await mail.ask(["op": "subscriber-set", "id": row.id, "kind": row.kind, "email": row.email, "mode": mode])
        await mail.refresh()
    }

    private func remove(_ row: DeliverMail.Subscriber) async {
        _ = await mail.ask(["op": "subscriber-remove", "id": row.id])
        await mail.refresh()
    }

    private func setHook(_ project: UUID) async {
        let url = (hookDrafts[project] ?? "").trimmingCharacters(in: .whitespaces)
        guard url.isEmpty || url.lowercased().hasPrefix("https://") else { note = String(localized: "A webhook needs an https address."); return }
        _ = await mail.ask(["op": "hook-set", "project": project.uuidString, "url": url.isEmpty ? NSNull() : url, "internal": false])
        hookDrafts[project] = nil
        await mail.refresh()
    }
}
