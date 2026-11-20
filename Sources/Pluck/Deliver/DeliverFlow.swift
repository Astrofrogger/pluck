import SwiftUI
import UserNotifications

// Deliver workflow (plan 2026-11-20-deliver-workflow-nle): assignments and the overdue badge, "As arranged" link order,
// saved views, custom statuses and custom fields. All Mac-side; the wire only gains optional fields.

extension Notification.Name {
    /// An asset's due date arrived or passed (userInfo: "asset" UUID, "assignee" String, "overdue" Bool). For other
    /// channels (email or push to the assignee, notifications plan); posted for every assignee, not only the owner.
    static let deliverAssignmentDue = Notification.Name("deliverAssignmentDue")
}

extension Deliver {
    /// Today as `Fields.due` writes it (yyyy-MM-dd, this Mac's calendar).
    static func day(_ date: Date = .now, plus days: Int = 0) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Due before today and not approved.
    static func isOverdue(_ asset: Asset, today: String = day()) -> Bool {
        guard let due = asset.fields?.due, asset.status != .approved else { return false }
        return due < today
    }

    static func isAssigned(_ asset: Asset, to name: String) -> Bool {
        guard let assignee = asset.fields?.assignee?.trimmingCharacters(in: .whitespaces), !assignee.isEmpty else { return false }
        return assignee.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// "As arranged": the order's ids first, the rest after by name (new uploads never vanish).
    static func arranged(_ assets: [Asset], order: [UUID]?) -> [Asset] {
        let index = Dictionary((order ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return assets.sorted { a, b in
            switch (index[a.id], index[b.id]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: Saved views

    /// The built-ins, shipped as views with fixed ids (never stored).
    static let builtinViews: [SavedView] = [
        SavedView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!, name: String(localized: "Assigned to Me"), assignee: "me"),
        SavedView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F002")!, name: String(localized: "Overdue"), due: "overdue"),
        SavedView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F003")!, name: String(localized: "Needs Changes"), statuses: [Status.needsChanges.rawValue]),
    ]
    static let mineView = builtinViews[0].id, overdueView = builtinViews[1].id

    /// One asset against a view; `openComments` is asked only when the view needs it.
    static func matches(_ view: SavedView, _ asset: Asset, project: UUID, me: String, today: String = day(), openComments: () -> Bool) -> Bool {
        if let projects = view.projects, !projects.contains(project) { return false }
        if let statuses = view.statuses, !statuses.isEmpty, !statuses.contains(asset.status.rawValue) { return false }
        if let assignee = view.assignee, !assignee.isEmpty, !isAssigned(asset, to: assignee == "me" ? me : assignee) { return false }
        switch view.due {
        case "overdue": if !isOverdue(asset, today: today) { return false }
        case "week":
            guard let due = asset.fields?.due, asset.status != .approved, due <= Self.dayAfter(today, 7) else { return false }
        default: break
        }
        if let tag = view.tag?.lowercased(), !tag.isEmpty, !(asset.fields?.keywords ?? []).contains(where: { $0.lowercased() == tag }) { return false }
        if let rule = view.field {
            let value = asset.customFields?[rule.id] ?? ""
            switch rule.op {
            case "set": if value.isEmpty { return false }
            case "contains": if !value.localizedCaseInsensitiveContains(rule.value) { return false }
            default: if value.caseInsensitiveCompare(rule.value) != .orderedSame { return false }
            }
        }
        if view.openComments == true, !openComments() { return false }
        return true
    }

    static func dayAfter(_ day: String, _ days: Int) -> String {
        guard let date = try? Date(day, strategy: .iso8601.year().month().day()) else { return day }
        // (Parsed as UTC midnight; noon keeps the local calendar on the same day.)
        return Self.day(date.addingTimeInterval(12 * 3600), plus: days)
    }
}

extension Deliver.FieldDef {
    /// A value for this field as stored (nil = cleared), checked by kind.
    @MainActor func clean(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull { return nil }
        if kind == "checkbox" {
            let on = value as? Bool ?? ((value as? String).map { $0 == "1" || $0 == "true" } ?? false)
            return on ? "1" : nil
        }
        let text = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
        let clean = Deliver.clean(text, limit: DeliverStore.textLimit)
        if clean.isEmpty { return nil }
        switch kind {
        case "number": guard Double(clean) != nil else { throw Deliver.Failure("invalid") }
        case "date": guard clean.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { throw Deliver.Failure("invalid") }
        case "select": guard (options ?? []).contains(clean) else { throw Deliver.Failure("invalid") }
        case "person": return Deliver.clean(clean, limit: DeliverStore.authorLimit)
        default: break
        }
        return clean
    }
}

extension DeliverStore {
    /// The built-in statuses, then the custom ones.
    var statusList: [Deliver.Status] { Deliver.Status.allCases + (library.statuses ?? []).map { Deliver.Status(rawValue: $0.id) } }
    func statusDef(_ status: Deliver.Status) -> Deliver.StatusDef? { library.statuses?.first { $0.id == status.rawValue } }
    var fieldDefs: [Deliver.FieldDef] { library.fields ?? [] }
    var views: [Deliver.SavedView] { Deliver.builtinViews + (library.views ?? []) }

    /// A custom field (`cf:<id>`) set or cleared.
    func setCustomField(_ field: String, _ value: Any?, of asset: UUID, by author: String) throws {
        guard let def = fieldDefs.first(where: { $0.wireName == field }), find(asset) != nil else { throw Deliver.Failure("invalid") }
        let clean = try def.clean(value)
        update(asset: asset) { asset in
            var values = asset.customFields ?? [:]
            values[def.id] = clean
            asset.customFields = values.isEmpty ? nil : values
        }
        tell(.field(asset, field, author))
    }

    /// Every asset a view finds, across projects.
    func assets(in view: Deliver.SavedView, me: String? = nil, today: String = Deliver.day()) -> [(project: UUID, asset: Deliver.Asset)] {
        let me = me ?? DeliverSettings.author
        return projects.filter { $0.hidden != true }.flatMap { project in
            content(project.id).assets.filter { asset in
                Deliver.matches(view, asset, project: project.id, me: me, today: today) { comments(asset.id).contains { !$0.completed } }
            }.map { (project.id, $0) }
        }
    }

    /// A short id for a new custom status or field.
    static func shortID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }
}

extension DeliverDeadlines {
    static let dueKey = "deliverDueReminded"

    /// Assignments (workflow plan 2): on the morning a due date arrives (from 9:00) and once it's overdue, each once.
    func checkAssignments(now: Date) {
        let today = Deliver.day(now), hour = Calendar.current.component(.hour, from: now)
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.dueKey) ?? [])
        let before = done.count
        for project in store.projects {
            for asset in store.content(project.id).assets {
                guard let due = asset.fields?.due, let assignee = asset.fields?.assignee, asset.status != .approved else { continue }
                let overdue = due < today
                guard overdue || (due == today && hour >= 9) else { continue }
                let key = "\(asset.id.uuidString)|\(due)|\(overdue ? "late" : "today")"
                guard done.insert(key).inserted else { continue }
                remind(asset, assignee: assignee, overdue: overdue)
            }
        }
        if done.count != before { UserDefaults.standard.set(Array(done.suffix(5000)), forKey: Self.dueKey) }
    }

    /// "Hero 30s is due today" / "Hero 30s is overdue (due 2026-11-18)".
    static func dueText(_ asset: Deliver.Asset, overdue: Bool) -> String {
        overdue ? String(localized: "\(asset.name) is overdue (due \(asset.fields?.due ?? ""))") : String(localized: "\(asset.name) is due today")
    }

    /// The reminder hook: a local notification when the assignee is this Mac's owner, and `.deliverAssignmentDue` for
    /// every assignee (the notifications plan's email or push to a team member listens there, or calls this).
    func remind(_ asset: Deliver.Asset, assignee: String, overdue: Bool) {
        NotificationCenter.default.post(name: .deliverAssignmentDue, object: nil, userInfo: ["asset": asset.id, "assignee": assignee, "overdue": overdue])
        // A teammate with an email: the main host mails them (it dedupes per asset and day, so every Mac may ask).
        if DeliverMail.shared.active, let person = DeliverMail.teammate(assignee, in: DeliverPeople.shared.people.people ?? []) {
            Task { _ = await DeliverMail.shared.ask(["op": "mail-remind", "asset": asset.id.uuidString, "person": person, "overdue": overdue]) }
        }
        guard Deliver.isAssigned(asset, to: DeliverSettings.author) else { return }
        let text = Self.dueText(asset, overdue: overdue)
        if let posted { return posted(text) }
        guard ScreenshotMode.scene == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = text
        content.categoryIdentifier = Notifications.deadlineCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-due-\(asset.id.uuidString)-\(overdue)", content: content, trigger: nil))
    }
}

// MARK: - Views

/// The status's name and colour (built-in or custom).
extension DeliverStatusPill {
    static func custom(_ status: Deliver.Status) -> Deliver.StatusDef? { DeliverStore.shared.statusDef(status) }
    static func colour(token: String) -> Color {
        switch token {
        case "good": Design.Studio.good
        case "bad": Design.Studio.bad
        case "warn": Design.Studio.warn
        case "pink": Design.Brand.pink
        case "violet": Design.Brand.violet
        default: Design.Studio.textQuiet
        }
    }
}

/// The small red "Overdue" chip.
struct DeliverOverdueChip: View {
    let asset: Deliver.Asset
    var body: some View {
        if Deliver.isOverdue(asset) { StudioChip(text: Text("Overdue"), colour: Design.Studio.bad, tinted: true).help(Text(verbatim: asset.fields?.due ?? "")) }
    }
}

/// A saved view's results: the matching assets from every project, in the asset grid.
struct DeliverViewResults: View {
    @Bindable var nav: StudioNavigator
    let view: UUID
    @State private var store = DeliverStore.shared
    @State private var editing = false

    var body: some View {
        let found = store.views.first { $0.id == view }
        let results = found.map { store.assets(in: $0) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: found?.name ?? "").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                Spacer()
                if found.map({ v in !Deliver.builtinViews.contains { $0.id == v.id } }) == true {
                    Button("Edit View…") { editing = true }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            .padding(20)
            ScrollView {
                if results.isEmpty {
                    StudioEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Nothing here").frame(minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 230), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(results, id: \.asset.id) { item in
                            DeliverAssetCard(asset: item.asset) {
                                Button("Open") { nav.deliver = .asset(item.asset.id, version: nil, comment: nil) }
                                Button("Show in Project") { nav.deliver = .project(item.project, folder: item.asset.folder) }
                            }
                            .onTapGesture { nav.deliver = .asset(item.asset.id, version: nil, comment: nil) }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $editing) { if let found { DeliverViewEditor(view: found) } }
    }
}

/// A saved view's filter: name, statuses, assignee, due, keyword, open comments, a custom field, this project or all.
struct DeliverViewEditor: View {
    @State var view: Deliver.SavedView
    var project: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeliverStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            VStack(alignment: .leading, spacing: 2) {
                StudioField(label: "Name") { TextField("Mine this week", text: $view.name).settingField(width: 240) }
                StudioField(label: "Status") {
                    Menu {
                        ForEach(store.statusList, id: \.self) { status in
                            Toggle(isOn: Binding(get: { view.statuses?.contains(status.rawValue) == true }, set: { on in
                                var list = (view.statuses ?? []).filter { $0 != status.rawValue }
                                if on { list.append(status.rawValue) }
                                view.statuses = list.isEmpty ? nil : list
                            })) { Text(DeliverStatusPill.title(status)) }
                        }
                    } label: { StudioMenuLabel(title: view.statuses.map { String(localized: "\($0.count) chosen") } ?? String(localized: "Any")) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                StudioField(label: "Assignee") {
                    TextField("Anyone", text: Binding(get: { view.assignee == "me" ? "" : view.assignee ?? "" }, set: { view.assignee = $0.isEmpty ? nil : $0 }))
                        .settingField(width: 160).disabled(view.assignee == "me")
                    Toggle("Me", isOn: Binding(get: { view.assignee == "me" }, set: { view.assignee = $0 ? "me" : nil })).toggleStyle(.checkbox)
                }
                StudioField(label: "Due") {
                    Picker(selection: Binding(get: { view.due ?? "" }, set: { view.due = $0.isEmpty ? nil : $0 })) {
                        Text("Any").tag("")
                        Text("Overdue").tag("overdue")
                        Text("Within a week").tag("week")
                    } label: { EmptyView() }.fixedSize()
                }
                StudioField(label: "Keyword") {
                    TextField("hero", text: Binding(get: { view.tag ?? "" }, set: { view.tag = $0.isEmpty ? nil : $0 })).settingField(width: 160)
                }
                if !store.fieldDefs.isEmpty {
                    StudioField(label: "Field") {
                        Picker(selection: Binding(get: { view.field?.id ?? "" }, set: { id in
                            view.field = id.isEmpty ? nil : .init(id: id, op: view.field?.op ?? "set", value: view.field?.value ?? "")
                        })) {
                            Text("Any").tag("")
                            ForEach(store.fieldDefs) { Text(verbatim: $0.name).tag($0.id) }
                        } label: { EmptyView() }.fixedSize()
                        if view.field != nil {
                            Picker(selection: Binding(get: { view.field?.op ?? "set" }, set: { view.field?.op = $0 })) {
                                Text("Is set").tag("set")
                                Text("Is").tag("is")
                                Text("Contains").tag("contains")
                            } label: { EmptyView() }.fixedSize()
                            if view.field?.op != "set" {
                                TextField("", text: Binding(get: { view.field?.value ?? "" }, set: { view.field?.value = $0 })).settingField(width: 100)
                            }
                        }
                    }
                }
                StudioSwitchRow(title: "Has open comments", isOn: Binding(get: { view.openComments == true }, set: { view.openComments = $0 ? true : nil }))
                if let project {
                    StudioSwitchRow(title: "This project only", isOn: Binding(get: { view.projects != nil }, set: { view.projects = $0 ? [project] : nil }))
                }
            }
            HStack {
                if store.library.views?.contains(where: { $0.id == view.id }) == true {
                    Button("Delete View", role: .destructive) {
                        store.editLibrary { $0.views?.removeAll { $0.id == view.id } }
                        dismiss()
                    }.buttonStyle(StudioFlatButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                Button("Save") {
                    view.name = Deliver.clean(view.name, limit: DeliverStore.nameLimit)
                    store.editLibrary { library in
                        var views = library.views ?? []
                        if let index = views.firstIndex(where: { $0.id == view.id }) { views[index] = view } else { views.append(view) }
                        library.views = views
                    }
                    dismiss()
                }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(view.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 440)
        .background(Design.Studio.panel)
    }
}

/// Settings › Review › Statuses and Fields: the custom statuses (name, colour) and fields (name, kind, choices).
struct DeliverLibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeliverStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statuses").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            ForEach(Deliver.Status.allCases.dropFirst(), id: \.self) { status in
                HStack { DeliverStatusPill(status: status); Spacer() }
            }
            ForEach(store.library.statuses ?? []) { def in
                HStack(spacing: 8) {
                    TextField("Name", text: Binding(get: { def.name }, set: { name in editStatus(def.id) { $0.name = Deliver.clean(name, limit: 40) } })).settingField(width: 180)
                    Picker(selection: Binding(get: { def.colour }, set: { colour in editStatus(def.id) { $0.colour = colour } })) {
                        ForEach(Deliver.StatusDef.colours, id: \.self) { token in
                            Label { Text(verbatim: token) } icon: { Image(systemName: "circle.fill").foregroundStyle(DeliverStatusPill.colour(token: token)) }.tag(token)
                        }
                    } label: { EmptyView() }.fixedSize()
                    Spacer()
                    Button { store.editLibrary { $0.statuses?.removeAll { $0.id == def.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Remove")
                }
            }
            Button("Add Status") {
                store.editLibrary { $0.statuses = ($0.statuses ?? []) + [.init(id: "c:" + DeliverStore.shortID(), name: String(localized: "New Status"), colour: "violet")] }
            }.buttonStyle(StudioFlatButtonStyle())
            Text("Old review pages show a custom status as “—”. Turn them on per link.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)

            Rectangle().fill(Design.Studio.line).frame(height: 1)
            Text("Fields").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            ForEach(store.fieldDefs) { def in
                HStack(spacing: 8) {
                    TextField("Name", text: Binding(get: { def.name }, set: { name in editField(def.id) { $0.name = Deliver.clean(name, limit: 40) } })).settingField(width: 140)
                    Picker(selection: Binding(get: { def.kind }, set: { kind in editField(def.id) { $0.kind = kind } })) {
                        Text("Text").tag("text")
                        Text("Number").tag("number")
                        Text("Date").tag("date")
                        Text("Choice").tag("select")
                        Text("Person").tag("person")
                        Text("Checkbox").tag("checkbox")
                    } label: { EmptyView() }.fixedSize()
                    if def.kind == "select" {
                        TextField("A, B, C", text: Binding(get: { (def.options ?? []).joined(separator: ", ") }, set: { text in
                            editField(def.id) { $0.options = text.split(separator: ",").map { Deliver.clean(String($0), limit: 40) }.filter { !$0.isEmpty } }
                        })).settingField(width: 140)
                    }
                    Spacer()
                    Button { store.editLibrary { $0.fields?.removeAll { $0.id == def.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Remove")
                }
            }
            Button("Add Field") {
                store.editLibrary { $0.fields = ($0.fields ?? []) + [.init(id: DeliverStore.shortID(), name: String(localized: "New Field"), kind: "text")] }
            }.buttonStyle(StudioFlatButtonStyle())
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true)) }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .background(Design.Studio.panel)
    }

    private func editStatus(_ id: String, _ change: (inout Deliver.StatusDef) -> Void) {
        store.editLibrary { library in if let i = library.statuses?.firstIndex(where: { $0.id == id }) { change(&library.statuses![i]) } }
    }

    private func editField(_ id: String, _ change: (inout Deliver.FieldDef) -> Void) {
        store.editLibrary { library in if let i = library.fields?.firstIndex(where: { $0.id == id }) { change(&library.fields![i]) } }
    }
}

/// One custom field's control on an asset (Info…).
struct DeliverCustomFieldRow: View {
    let def: Deliver.FieldDef
    @Binding var value: String

    var body: some View {
        StudioField(label: "\(def.name)") { // the user's own name, shown as typed
            switch def.kind {
            case "checkbox": Toggle("", isOn: Binding(get: { value == "1" }, set: { value = $0 ? "1" : "" })).labelsHidden().toggleStyle(.checkbox)
            case "select":
                Picker(selection: $value) {
                    Text("None").tag("")
                    ForEach(def.options ?? [], id: \.self) { Text(verbatim: $0).tag($0) }
                } label: { EmptyView() }.fixedSize()
            case "date":
                if let date = try? Date(value, strategy: .iso8601.year().month().day()) {
                    DatePicker("", selection: Binding(get: { date }, set: { value = $0.formatted(.iso8601.year().month().day()) }), displayedComponents: .date).labelsHidden().fixedSize()
                    Button("None") { value = "" }.settingButton()
                } else {
                    Button("Set Date") { value = Date.now.formatted(.iso8601.year().month().day()) }.settingButton()
                }
            default: TextField(def.kind == "number" ? "0" : "", text: $value).settingField(width: 240)
            }
        }
    }
}
