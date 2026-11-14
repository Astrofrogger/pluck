import AppKit
import SwiftUI

// The Library's Finder parts shared by its folders and its collections: file actions that keep
// the Library in step, type-to-jump, rubber-band selection, the gallery, renaming in place and
// the details of a file in a folder.

/// Why a file action couldn't be done, in words for an alert.
struct FileProblem: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Renaming, duplicating, moving and trashing files as Finder does; the Library's entries follow.
@MainActor
enum FinderFiles {
    /// Renamed in its folder; the new place.
    static func rename(_ item: URL, to name: String) throws -> URL {
        if let problem = FinderPane.nameProblem(name) { throw FileProblem(problem) }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name != item.lastPathComponent else { return item }
        // (A folder's URL ends in a slash, as the folder's listing has it.)
        let target = item.deletingLastPathComponent().appendingPathComponent(name, isDirectory: item.hasDirectoryPath)
        // (Only the case changed: the same file on most Mac drives.)
        if FileManager.default.fileExists(atPath: target.path), name.lowercased() != item.lastPathComponent.lowercased() {
            throw FileProblem(String(localized: "\(name) is already in \(item.deletingLastPathComponent().lastPathComponent)."))
        }
        try FileUndo.shared.perform(String(localized: "Rename"), [.move(item, target)])
        return target
    }

    /// Finder's name for a copy beside it: "name copy.ext", then "name copy 2.ext"…
    nonisolated static func copyName(for url: URL, skipping taken: Set<String> = []) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.hasDirectoryPath ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let copy = String(localized: "copy", comment: "Added to a duplicated file's name, as Finder does")
        var number = 1
        while true {
            let name = stem + " " + copy + (number > 1 ? " \(number)" : "")
            let candidate = folder.appendingPathComponent(ext.isEmpty ? name : name + "." + ext, isDirectory: url.hasDirectoryPath)
            if !taken.contains(candidate.path), !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// A copy beside it (a Library item's copy is in the Library too); the copy. A small file is
    /// copied at once; a big one or a folder is a checked copy in the background (its bar is at
    /// the Library's foot, its undo and its Library entry follow when it's done).
    static func duplicate(_ url: URL) async throws -> URL {
        // A name a copy still on its way already has (a second ⌘D before the first is written).
        let target = copyName(for: url, skipping: reserved)
        reserved.insert(target.path)
        if url.hasDirectoryPath {
            // A folder: Finder's full copy (links, empty folders, permissions), off the main thread.
            defer { reserved.remove(target.path) }
            try await Task.detached { try FileManager.default.copyItem(at: url, to: target) }.value
            return recordCopy(of: url, at: target)
        }
        if isBig(url) { return try await duplicateInBackground(url, to: target) }
        defer { reserved.remove(target.path) }
        return try duplicateNow(url, to: target)
    }

    /// Names given to copies this session that may not be on disk yet (a background copy keeps its name).
    private static var reserved: Set<String> = []

    static func isBig(_ url: URL) -> Bool {
        !url.hasDirectoryPath && ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 50_000_000
    }

    static func duplicateNow(_ url: URL, to target: URL) throws -> URL {
        try FileManager.default.copyItem(at: url, to: target)
        return recordCopy(of: url, at: target)
    }

    private static func recordCopy(of url: URL, at target: URL) -> URL {
        addLibraryCopy(of: url, at: target)
        FileUndo.shared.record(String(localized: "Duplicate"), undo: [.trash(target)])
        return target
    }

    static func duplicateInBackground(_ url: URL, to target: URL) async throws -> URL {
        if let problem = await OffloadCenter.shared.copy([url], into: target.deletingLastPathComponent(), names: [url.standardizedFileURL: target.lastPathComponent]) {
            reserved.remove(target.path)
            throw FileProblem(problem)
        }
        return target
    }

    /// The Library's entry for a file, copied for its duplicate.
    static func addLibraryCopy(of url: URL, at target: URL) {
        let library = LibraryStore.shared
        guard var copy = library.entries.first(where: { $0.path == url.path }) else { return }
        copy.path = target.path
        copy.title += " " + String(localized: "copy", comment: "Added to a duplicated file's name, as Finder does")
        copy.added = .now
        library.insert(copy)
    }

    /// Whether two places are on the same drive (a move there is instant, as in Finder).
    nonisolated static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = (try? a.resourceValues(forKeys: [key]))?.volumeIdentifier as AnyObject?,
              let y = (try? b.resourceValues(forKeys: [key]))?.volumeIdentifier as AnyObject? else { return false }
        return x.isEqual(y)
    }

    /// Moved into a folder on the same drive (`names`: new names for some, kept beside one
    /// already there), one undo. Nil when all went; else why some didn't.
    @discardableResult
    static func move(_ urls: [URL], into folder: URL, names: [URL: String] = [:]) -> String? {
        var problems: [String] = []
        let folderName = FileManager.default.displayName(atPath: folder.path)
        FileUndo.shared.grouped(String(localized: "Move")) {
            for url in urls {
                // Already there: nothing to do.
                if url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path { continue }
                if FinderPane.isInside(folder, url) {
                    problems.append(String(localized: "\(url.lastPathComponent) can’t go into itself."))
                    continue
                }
                let target = folder.appendingPathComponent(names[url] ?? url.lastPathComponent, isDirectory: url.hasDirectoryPath)
                if FileManager.default.fileExists(atPath: target.path) {
                    problems.append(String(localized: "\(url.lastPathComponent) is already in \(folderName)."))
                    continue
                }
                do {
                    try FileUndo.shared.perform(String(localized: "Move"), [.move(url, target)])
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// To the Trash (never deleted for good), one undo; the Library's entries wait with them
    /// there. `done` gets where each went; nil when all went, else why some didn't.
    @discardableResult
    static func trash(_ urls: [URL], done: @escaping @MainActor ([URL: URL]) -> Void = { _ in }) -> String? {
        guard !urls.isEmpty else { return nil }
        var moved: [URL: URL] = [:], problems: [String] = []
        FileUndo.shared.grouped(String(localized: "Move to Trash")) {
            for url in urls {
                do {
                    if case .move(let place, _)? = try FileUndo.shared.perform(String(localized: "Move to Trash"), [.trash(url)]).first { moved[url] = place }
                } catch {
                    // (A drive without a Trash, such as a server: the file stays, and the user is told.)
                    problems.append(String(localized: "\(url.lastPathComponent) couldn’t go to the Trash: \(error.localizedDescription)"))
                }
            }
        }
        done(moved)
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// File URLs on the pasteboard (⌘C), for Finder and other apps to paste.
    static func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }
}

/// Type-to-jump, as in Finder: letters typed in quick succession pick the first name starting with them.
struct TypeSelect {
    private var typed = ""
    private var last = Date.distantPast

    /// What's been typed so far (a pause of a second starts again).
    mutating func add(_ characters: String, now: Date = .now) -> String {
        if now.timeIntervalSince(last) > 1 { typed = "" }
        last = now
        typed += characters
        return typed
    }

    /// The first name starting with what's typed (ignoring case and accents).
    static func match<Names: Collection<String>>(_ prefix: String, in names: Names) -> Names.Index? {
        guard !prefix.isEmpty else { return nil }
        return names.firstIndex { $0.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
    }

    /// Whether a key press is typing a name (letters or digits, no ⌘, ⌃ or ⌥).
    static func isTyping(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.command, .control, .option])
            && press.characters.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) }
            && !press.characters.isEmpty
    }
}

extension EventModifiers {
    /// ⌘ and ⇧ held now (for a click's way of selecting).
    @MainActor static var held: EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

// MARK: - Rubber band

/// Where each tile is, for the rubber band.
struct RubberBandFrames: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] { [:] }
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// A tile the rubber band can take.
    func rubberBandItem(_ id: AnyHashable) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: RubberBandFrames.self, value: [id: geometry.frame(in: .named(RubberBandSpace.name))])
        })
    }
}

enum RubberBandSpace { static let name = "rubberBand" }

/// Dragging in the space between tiles selects every tile the box touches (⌘ or ⇧ adds them to
/// what's selected); a click there selects nothing.
struct RubberBand<ID: Hashable>: ViewModifier {
    @Binding var selection: Set<ID>
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var box: CGRect?
    @State private var base: Set<ID> = []

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { selection = [] }
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(RubberBandSpace.name))
                        .onChanged { drag in
                            if box == nil { base = EventModifiers.held.isEmpty ? [] : selection }
                            let rect = CGRect(x: min(drag.startLocation.x, drag.location.x), y: min(drag.startLocation.y, drag.location.y),
                                              width: abs(drag.location.x - drag.startLocation.x), height: abs(drag.location.y - drag.startLocation.y))
                            box = rect
                            let hit = frames.filter { $0.value.intersects(rect) }.compactMap { $0.key.base as? ID }
                            selection = base.union(hit)
                        }
                        .onEnded { _ in box = nil })
            }
            .overlay(alignment: .topLeading) {
                if let box {
                    Rectangle()
                        .fill(Design.Brand.deep.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Design.Brand.deep.opacity(0.7), lineWidth: 1))
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: RubberBandSpace.name)
            .onPreferenceChange(RubberBandFrames.self) { frames = $0 }
    }
}

// MARK: - Gallery

/// Finder's Gallery view: the item chosen large, every item in a filmstrip below.
struct StudioGallery<Item: Identifiable, Big: View, Thumb: View>: View {
    let items: [Item]
    let current: Item.ID?
    let choose: (Item) -> Void
    let open: (Item) -> Void
    @ViewBuilder let big: (Item) -> Big
    @ViewBuilder let thumb: (Item) -> Thumb

    var body: some View {
        let shown = items.first { $0.id == current } ?? items.first
        VStack(spacing: 0) {
            Group {
                if let shown { big(shown) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .contentShape(.rect)
            .onTapGesture(count: 2) { if let shown { open(shown) } }
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            thumb(item)
                                .frame(width: 76, height: 48)
                                .clipShape(.rect(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    if item.id == shown?.id {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Design.Brand.gradient, lineWidth: 2).padding(-3)
                                    }
                                }
                                .contentShape(.rect)
                                .onTapGesture(count: 2) { open(item) }
                                .simultaneousGesture(TapGesture().onEnded { choose(item) })
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(height: 68)
                .onChange(of: shown?.id) { _, id in if let id { withAnimation(.smooth(duration: 0.2)) { scroller.scrollTo(id, anchor: .center) } } }
            }
        }
    }
}

// MARK: - Renaming in place

/// A name typed over the old one, as Finder: Return or clicking away keeps it, Esc keeps the old one.
struct InlineNameField: View {
    let initial: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(Design.Studio.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .background(Design.Studio.raised, in: .rect(cornerRadius: 4, style: .continuous))
            .focused($focused)
            .focusEffectDisabled()
            .onAppear {
                text = initial
                // (A moment later: taken at once, the list it's in kept the focus and the typing.)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    focused = true
                }
            }
            .onSubmit { finish() }
            .onExitCommand {
                done = true
                cancel()
            }
            .onChange(of: focused) { was, now in if was, !now { finish() } }
    }

    private func finish() {
        guard !done else { return }
        done = true
        commit(text)
    }
}

// MARK: - A file's details

/// The Library's right panel for a file or folder in a folder: its picture, what it is, and
/// what to do with it (⌘I shows or hides it).
struct FinderDetails: View {
    let item: FinderItem
    let pane: FinderPane
    @State private var thumbs = FinderThumbnails.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            if !item.isFolder, !item.isClip, FilePreview.showsContents(item.url) {
                // A document, text, PDF…: what's in it, to look at before moving or opening it.
                // (All the panel's height the details leave: a page to read, not a stamp.)
                FilePreview(url: item.url)
                    .frame(minHeight: 300, maxHeight: .infinity)
                    .layoutPriority(1)
                    .background(Design.Studio.raised)
                    .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            } else {
            Rectangle()
                .fill(Design.Studio.raised)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let picture = item.isClip ? thumbs.posters[item.url] : thumbs.pictures[item.url] {
                        Image(decorative: picture, scale: 1).resizable().scaledToFit()
                    } else {
                        Image(nsImage: item.icon).resizable().scaledToFit().padding(20)
                    }
                }
                .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                .modifier(FinderWantsPicture(item: item))
            }
            Text(item.name).font(Design.Studio.sectionTitle).lineLimit(2).truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                row("Kind", item.kind)
                if let summary = thumbs.summaries[item.url] {
                    row("Length", Format.duration(Double(summary.frames) / max(summary.fps, 1)))
                    row("Frame", "\(summary.width)×\(summary.height)")
                }
                if let size = item.size { row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let modified = item.modified { row("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
                row("Where", FileManager.default.displayName(atPath: item.url.deletingLastPathComponent().path))
            }
            .font(Design.Studio.body)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button { pane.open(item) } label: {
                    Text(item.isClip ? "Play" : "Open").frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(.white)
                        .background(Design.Brand.deep, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Text("Show in Finder").frame(maxWidth: .infinity, minHeight: 32)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .font(Design.Studio.body)
        }
        .padding(Design.Studio.panelInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .help(item.url.path)
    }

    private func row(_ name: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(Design.Studio.textQuiet).frame(width: 72, alignment: .leading)
            Text(verbatim: value).lineLimit(1).truncationMode(.middle)
        }
    }
}
