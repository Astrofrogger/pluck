import SwiftUI

/// Setting up an offload project: its name, drives, the people filming and how folders are named,
/// with the path a card would get.
struct OffloadProjectSheet: View {
    @State var project: OffloadProject
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StudioTile(symbol: "person.2.crop.square.stack", size: 32)
                Text(isNew ? "New Project" : "Project").font(Design.Studio.sectionTitle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(nil) { field("Name", text: $project.name) }
                    section("Drives") { folders($project.drives, add: "Add a Drive…") }
                    section("Backups") { folders($project.backups, add: "Add a Backup Drive…") }
                    section("Who’s Filming") {
                        ForEach($project.operators) { $person in
                            HStack(spacing: 8) {
                                field("Letter", text: $person.letter)
                                    .frame(width: 52)
                                    .onChange(of: person.letter) { _, letter in
                                        let cleaned = String(letter.uppercased().filter(\.isLetter).prefix(2))
                                        if cleaned != letter { person.letter = cleaned }
                                    }
                                field("Name", text: $person.name)
                                removeButton { project.operators.removeAll { $0.id == person.id } }
                            }
                        }
                        StudioDashedButton(title: "Add Someone", height: 32) {
                            let letter = project.freeLetter
                            project.operators.append(.init(name: String(localized: "Operator \(letter)"), letter: letter))
                        }
                    }
                    section("Folders") {
                        HStack(spacing: 10) {
                            Toggle("Day folder", isOn: $project.dayFolder.on).toggleStyle(StudioSwitchStyle())
                            field("Day folder", text: $project.dayFolder.template).disabled(!project.dayFolder.on)
                        }
                        HStack(spacing: 10) {
                            Color.clear.frame(width: 28, height: 1)
                            field("Person’s folder", text: $project.operatorFolder)
                        }
                        HStack(spacing: 10) {
                            Toggle("Card folder", isOn: $project.cardFolder.on).toggleStyle(StudioSwitchStyle())
                            field("Card folder", text: $project.cardFolder.template).disabled(!project.cardFolder.on)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview).font(Design.Studio.body.monospaced()).foregroundStyle(Design.Studio.text).textSelection(.enabled)
                            Text(FolderTemplate.tokens.joined(separator: " ")).font(Design.Studio.hint)
                                .foregroundStyle(Design.Studio.textQuiet).textSelection(.enabled)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(minHeight: 460)

            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete Project", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(StudioFlatButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Done") {
                    let store = OffloadProjects.shared
                    store.save(cleaned)
                    if isNew { store.active = project.id }
                    dismiss()
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(cleaned.name.isEmpty || cleaned.drives.isEmpty || cleaned.operators.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Design.Studio.panel)
        .preferredColorScheme(.dark)
        .tint(Design.Brand.pink)
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) {
                OffloadProjects.shared.remove(project.id)
                dismiss()
            }
        } message: {
            Text("The copies stay where they are.")
        }
    }

    /// A part of the sheet: a quiet title over a dark box.
    private func section<Content: View>(_ title: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioBox()
        }
    }

    /// A dark Studio text field with its name as the hint.
    private func field(_ hint: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(hint, text: text, prompt: Text(hint).foregroundStyle(Design.Studio.textFaint))
            .textFieldStyle(.plain)
            .font(Design.Studio.body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Remove")
        .accessibilityLabel("Remove")
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
                HStack(spacing: 10) {
                    Image(systemName: path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive")
                        .font(.system(size: 14)).foregroundStyle(Design.Studio.textQuiet)
                    Text(verbatim: OffloadCenter.volumeName(URL(fileURLWithPath: path))).font(Design.Studio.body)
                        .help(path)
                    if path == project.drives.first, paths.wrappedValue == project.drives, project.drives.count > 1 {
                        Text("Main").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    Spacer()
                    removeButton { paths.wrappedValue.removeAll { $0 == path } }
                }
                .frame(minHeight: 28)
            }
            StudioDashedButton(title: title, height: 32) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = String(localized: "Choose")
                if panel.runModal() == .OK, let url = panel.url, !paths.wrappedValue.contains(url.path) { paths.wrappedValue.append(url.path) }
            }
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
        VStack(alignment: .leading, spacing: 12) {
            OffloadBoxHeader(symbol: "person.crop.circle.badge.questionmark", tint: Design.Studio.warn, title: Text("Whose camera is this?"),
                             subtitle: Text("\(OffloadCenter.volumeName(question.volume)) · \(question.camera.name)")) {
                OffloadIconButton(symbol: "xmark", label: "Not Now") { center.dismiss(question.id) }
            }
            HStack(spacing: 8) {
                ForEach(project?.operators ?? []) { person in
                    let chosen = person.id == question.preselected
                    Button { answer(person.id) } label: {
                        Text("\(person.letter) · \(person.name)")
                    }
                    .buttonStyle(StudioFlatButtonStyle(prominent: chosen))
                    .modifier(DefaultIf(on: chosen))
                }
            }
            if let problem { OffloadNote(symbol: "exclamationmark.triangle", text: Text(problem), colour: Design.Studio.warn) }
        }
        .padding(16)
        .studioBox()
    }

    private func answer(_ person: UUID) {
        Task { problem = await center.answer(question.id, operator: person) }
    }

    /// Return picks the one suggested.
    private struct DefaultIf: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.keyboardShortcut(.defaultAction) } else { content }
        }
    }
}
