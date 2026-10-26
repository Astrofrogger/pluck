import SwiftUI

/// Setting up an offload project: its name, drives, the people filming and how folders are named,
/// with the path a card would get.
struct OffloadProjectSheet: View {
    @State var project: OffloadProject
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "person.2.crop.square.stack", title: Text(isNew ? "New Project" : "Project"))

            Form {
                Section {
                    TextField("Name", text: $project.name)
                }
                Section("Drives") {
                    folders($project.drives, add: "Add a Drive…")
                }
                Section {
                    folders($project.backups, add: "Add a Backup Drive…")
                } header: {
                    Text("Backups")
                }
                Section("Who’s Filming") {
                    ForEach($project.operators) { $person in
                        HStack(spacing: Design.Spacing.controls) {
                            TextField("Letter", text: $person.letter)
                                .frame(width: 44)
                                .onChange(of: person.letter) { _, letter in
                                    let cleaned = String(letter.uppercased().filter(\.isLetter).prefix(2))
                                    if cleaned != letter { person.letter = cleaned }
                                }
                            TextField("Name", text: $person.name)
                            Button("Remove", systemImage: "minus.circle") { project.operators.removeAll { $0.id == person.id } }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        .labelsHidden()
                    }
                    Button("Add Someone", systemImage: "plus") {
                        let letter = project.freeLetter
                        project.operators.append(.init(name: String(localized: "Operator \(letter)"), letter: letter))
                    }
                    .buttonStyle(.borderless)
                }
                Section {
                    Toggle(isOn: $project.dayFolder.on) {
                        TextField("Day folder", text: $project.dayFolder.template).disabled(!project.dayFolder.on)
                    }
                    TextField("Person’s folder", text: $project.operatorFolder)
                    Toggle(isOn: $project.cardFolder.on) {
                        TextField("Card folder", text: $project.cardFolder.template).disabled(!project.cardFolder.on)
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview).font(.callout.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                        Text(FolderTemplate.tokens.joined(separator: " ")).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 460)

            HStack {
                if !isNew {
                    Button("Delete Project", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Done") {
                    let store = OffloadProjects.shared
                    store.save(cleaned)
                    if isNew { store.active = project.id }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(cleaned.name.isEmpty || cleaned.drives.isEmpty || cleaned.operators.isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) {
                OffloadProjects.shared.remove(project.id)
                dismiss()
            }
        } message: {
            Text("The copies stay where they are.")
        }
    }

    /// The project as kept: a name, and everyone with a letter.
    private var cleaned: OffloadProject {
        var kept = project
        kept.name = FolderTemplate.safe(kept.name)
        kept.operators = kept.operators.filter { !$0.letter.isEmpty && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        return kept
    }

    /// Where a first card would go, for the first person.
    private var preview: String {
        let person = project.operators.first ?? .init(name: String(localized: "Operator A"), letter: "A")
        var shown = project
        shown.drives = []
        let plan = OffloadProjectPlanner.plan(card: URL(fileURLWithPath: "/"), files: [], project: shown, operator: person, date: .now,
                                                firstOffload: project.firstOffload(in: OffloadCenter.shared.jobs))
        return plan.folder + "/"
    }

    private func folders(_ paths: Binding<[String]>, add title: LocalizedStringKey) -> some View {
        Group {
            ForEach(paths.wrappedValue, id: \.self) { path in
                HStack {
                    Label(OffloadCenter.volumeName(URL(fileURLWithPath: path)), systemImage: path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive")
                        .help(path)
                    if path == project.drives.first, paths.wrappedValue == project.drives, project.drives.count > 1 {
                        Text("Main").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { paths.wrappedValue.removeAll { $0 == path } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Button(title, systemImage: "plus") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = String(localized: "Choose")
                if panel.runModal() == .OK, let url = panel.url, !paths.wrappedValue.contains(url.path) { paths.wrappedValue.append(url.path) }
            }
            .buttonStyle(.borderless)
        }
    }
}

/// "Whose camera is this?": a card in a project whose camera isn't known (or doesn't say), with
/// the people filming as buttons.
struct OffloadQuestionCard: View {
    let question: OffloadCenter.Question
    @State private var center = OffloadCenter.shared
    @State private var problem: String?

    var body: some View {
        let project = OffloadProjects.shared.project(question.project)
        Card {
            CardHeader(symbol: "person.crop.circle.badge.questionmark", title: Text("Whose camera is this?"),
                       subtitle: Text("\(OffloadCenter.volumeName(question.volume)) · \(question.camera.name)")) {
                Button("Not Now", systemImage: "xmark") { center.dismiss(question.id) }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            HStack(spacing: Design.Spacing.controls) {
                ForEach(project?.operators ?? []) { person in
                    let chosen = person.id == question.preselected
                    Button { answer(person.id) } label: {
                        Text("\(person.letter) · \(person.name)")
                    }
                    .buttonStyle(.bordered)
                    .tint(chosen ? .accentColor : nil)
                    .modifier(DefaultIf(on: chosen))
                }
            }
            if let problem { ProblemLabel(text: problem) }
        }
    }

    private func answer(_ person: UUID) {
        Task { problem = await center.answer(question.id, operator: person) }
    }

    /// Return picks the one suggested.
    private struct DefaultIf: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } else { content }
        }
    }
}
