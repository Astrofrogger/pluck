import AppKit
import SwiftUI

// The Library's Finder extras: renaming several at once, Open With, Compress and Uncompress,
// and a Markdown file read large (Space).

// MARK: - Renaming several

/// How several files are renamed at once, as Finder's Rename: text replaced, text added, or a
/// name with a counter ("Shoot-001"). Extensions are kept.
struct BatchRename: Equatable {
    enum Mode: String, CaseIterable, Hashable { case replace, add, format }
    var mode: Mode = .replace
    var find = ""
    var replacement = ""
    var added = ""
    var addAfter = true
    var base = ""
    var start = 1
    var digits = 3

    /// Each name's new one (in the order given; `index` counts from 0).
    func name(for old: String, index: Int) -> String {
        let ext = (old as NSString).pathExtension
        let stem = ext.isEmpty ? old : (old as NSString).deletingPathExtension
        let new: String
        switch mode {
        case .replace: new = find.isEmpty ? stem : stem.replacingOccurrences(of: find, with: replacement)
        case .add: new = addAfter ? stem + added : added + stem
        case .format:
            let number = String(start + index)
            new = base + String(repeating: "0", count: max(digits - number.count, 0)) + number
        }
        return ext.isEmpty ? new : new + "." + ext
    }

    /// The new names, and which can't be used (empty, a slash, two the same, or one already there
    /// that isn't being renamed itself).
    static func plan(_ urls: [URL], rule: BatchRename, listed: [String: Set<String>] = [:]) -> (names: [String], clashes: Set<Int>) {
        let names = urls.enumerated().map { rule.name(for: $0.element.lastPathComponent, index: $0.offset) }
        var clashes = Set<Int>()
        var folders = listed
        var claimed: [String: Int] = [:]
        for (index, url) in urls.enumerated() {
            let folder = url.deletingLastPathComponent().path
            if folders[folder] == nil {
                folders[folder] = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { $0.lowercased() })
            }
            let new = names[index].lowercased(), old = url.lastPathComponent.lowercased()
            if FinderPane.nameProblem(names[index]) != nil { clashes.insert(index) }
            // (Its own name, or a case change of it, is fine; another's isn't, even one being renamed.)
            if new != old, folders[folder]!.contains(new) { clashes.insert(index) }
            let key = folder + "/" + new
            if let other = claimed[key] { clashes.formUnion([index, other]) } else { claimed[key] = index }
        }
        return (names, clashes)
    }

    /// Renamed, one undo. Nil when done; else why not.
    @MainActor static func apply(_ urls: [URL], rule: BatchRename) -> String? {
        let (names, clashes) = plan(urls, rule: rule)
        guard clashes.isEmpty else { return String(localized: "Some new names are taken.") }
        let steps = zip(urls, names).filter { $0.0.lastPathComponent != $0.1 }.map { url, name in
            FileStep.move(url, url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath))
        }
        do { try FileUndo.shared.perform(String(localized: "Rename"), steps) } catch { return error.localizedDescription }
        return nil
    }
}

/// Rename… with several selected: the rule, and every old name beside its new one.
struct BatchRenameSheet: View {
    let urls: [URL]
    let done: (String?) -> Void
    @State private var rule = BatchRename()
    /// The folders' names, read once (not at every key typed); Rename checks them again.
    @State private var listed: [String: Set<String>] = [:]

    var body: some View {
        let (names, clashes) = BatchRename.plan(urls, rule: rule, listed: listed)
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            Text("Rename \(urls.count) Items").font(Design.Studio.sectionTitle)
            StudioSegmented(options: [(BatchRename.Mode.replace, "Replace Text"), (.add, "Add Text"), (.format, "Format")],
                            selection: $rule.mode, fill: true)
            Group {
                switch rule.mode {
                case .replace:
                    StudioField(label: "Find") { field("Text to find", $rule.find) }
                    StudioField(label: "Replace with") { field("New text", $rule.replacement) }
                case .add:
                    StudioField(label: "Add") { field("Text", $rule.added) }
                    StudioField(label: "Where") {
                        StudioSegmented(options: [(false, "Before Name"), (true, "After Name")], selection: $rule.addAfter)
                    }
                case .format:
                    StudioField(label: "Name") { field("Shoot-", $rule.base) }
                    StudioField(label: "Start at") {
                        TextField("1", value: $rule.start, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                    }
                    StudioField(label: "Digits") {
                        Stepper(value: $rule.digits, in: 1...6) { Text(verbatim: "\(rule.digits)").monospacedDigit() }
                    }
                }
            }
            .font(Design.Studio.body)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 8) {
                            Text(verbatim: url.lastPathComponent).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(Design.Studio.textQuiet)
                            Text(verbatim: names[index]).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(clashes.contains(index) ? Color.red : Design.Studio.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(Design.Studio.hint)
                        .help(clashes.contains(index) ? String(localized: "This name is taken or can’t be used.") : "")
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            HStack {
                if !clashes.isEmpty {
                    Text("\(clashes.count) names are taken or can’t be used.").font(Design.Studio.hint).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(StudioFlatButtonStyle())
                Button("Rename") { done(BatchRename.apply(urls, rule: rule)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .disabled(!clashes.isEmpty || zip(urls, names).allSatisfy { $0.0.lastPathComponent == $0.1 })
            }
        }
        .padding(Design.Studio.panelInset)
        .frame(width: 520)
        .background(Design.Studio.panel)
        .onAppear {
            // (The name they share, as a start for Format.)
            rule.base = String(localized: "Untitled") + "-"
            for folder in Set(urls.map { $0.deletingLastPathComponent().path }) {
                listed[folder] = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { $0.lowercased() })
            }
        }
    }

    private func field(_ prompt: LocalizedStringKey, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: 260)
    }
}

// MARK: - Open With

/// Open With ▸ the apps that can open it, its usual one first, as in Finder.
struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        if let first = urls.first {
            let usual = NSWorkspace.shared.urlForApplication(toOpen: first)
            let others = NSWorkspace.shared.urlsForApplications(toOpen: first).filter { $0 != usual }
                .sorted { FileManager.default.displayName(atPath: $0.path).localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending }
            Menu("Open With") {
                if let usual {
                    app(usual, suffix: String(localized: " (default)"))
                    if !others.isEmpty { Divider() }
                }
                ForEach(others, id: \.self) { app($0) }
            }
            .disabled(usual == nil && others.isEmpty)
        }
    }

    private func app(_ app: URL, suffix: String = "") -> some View {
        Button {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Label { Text(verbatim: FileManager.default.displayName(atPath: app.path) + suffix) } icon: {
                Image(nsImage: Self.icon(app))
            }
        }
    }

    private static func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Compress and Uncompress

/// Zip archives as Finder makes them (ditto): "name.zip" for one, "Archive.zip" for several;
/// opened beside the archive, never over anything there. Each is one undo.
@MainActor
enum FinderArchive {
    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// The archive made, or why not.
    static func compress(_ urls: [URL]) async -> Result<URL, FileProblem> {
        guard let first = urls.first else { return .failure(FileProblem("")) }
        let folder = first.deletingLastPathComponent()
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let wanted = urls.count == 1 ? first.lastPathComponent + ".zip" : String(localized: "Archive") + ".zip"
        let target = folder.appendingPathComponent(taken.contains(wanted.lowercased()) ? FileClash.freeName(wanted, taken: taken) : wanted)
        let made = await Task.detached(priority: .userInitiated) { () -> String? in
            // (A folder goes in by its name; a file by itself.)
            if urls.count == 1 { return run(["-c", "-k", "--sequesterRsrc"] + (first.hasDirectoryPath ? ["--keepParent"] : []) + [first.path, target.path]) }
            // Several: copies (instant clones on the same drive) in a folder of Pluck's own, zipped together.
            guard let scratch = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) else {
                return String(localized: "There’s no room to make the archive.")
            }
            defer { try? FileManager.default.removeItem(at: scratch) }
            for url in urls {
                do { try FileManager.default.copyItem(at: url, to: scratch.appendingPathComponent(url.lastPathComponent)) } catch { return error.localizedDescription }
            }
            return run(["-c", "-k", "--sequesterRsrc", scratch.path, target.path])
        }.value
        if let made {
            // (What ditto left of the archive it couldn't finish: Pluck's own, to the Trash.)
            if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            return .failure(FileProblem(made))
        }
        FileUndo.shared.record(String(localized: "Compress"), undo: [.trash(target)])
        return .success(target)
    }

    /// What was in the archive, beside it (a name already there: "name 2"), or why not.
    static func uncompress(_ zip: URL) async -> Result<[URL], FileProblem> {
        let folder = zip.deletingLastPathComponent()
        let opened = await Task.detached(priority: .userInitiated) { () -> (placed: [URL], problem: FileProblem?) in
            let fm = FileManager.default
            // (Opened in a folder of Pluck's own first: nothing there is written over.)
            guard let scratch = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) else {
                return ([], FileProblem(String(localized: "There’s no room to open the archive.")))
            }
            defer { try? fm.removeItem(at: scratch) }
            if let problem = run(["-x", "-k", zip.path, scratch.path]) { return ([], FileProblem(problem)) }
            var taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            var placed: [URL] = []
            for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] where name != "__MACOSX" {
                let free = taken.contains(name.lowercased()) ? FileClash.freeName(name, taken: taken) : name
                taken.insert(free.lowercased())
                let target = folder.appendingPathComponent(free)
                // (Those already placed stay part of the undo.)
                do { try fm.moveItem(at: scratch.appendingPathComponent(name), to: target) } catch { return (placed, FileProblem(error.localizedDescription)) }
                placed.append(target)
            }
            return (placed, nil)
        }.value
        FileUndo.shared.record(String(localized: "Uncompress"), undo: opened.placed.map { .trash($0) })
        return opened.problem.map { .failure($0) } ?? .success(opened.placed)
    }

    /// ditto, waited for; nil, or what went wrong.
    nonisolated private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? String(localized: "The archive couldn’t be made or opened.") : said
    }
}

// MARK: - Markdown, large

/// Space on a Markdown file: the page drawn large (other files keep the system's Quick Look).
struct MarkdownReader: View {
    let url: URL
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: url.lastPathComponent).font(Design.Studio.sectionTitle).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url); close() }.buttonStyle(StudioFlatButtonStyle())
                Button("Done") { close() }.keyboardShortcut(.cancelAction).buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
            .padding(.horizontal, Design.Studio.panelInset)
            .frame(height: 48)
            Divider()
            MarkdownPreview(url: url)
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 480, idealHeight: 720)
        .background(Design.Studio.panel)
    }
}
