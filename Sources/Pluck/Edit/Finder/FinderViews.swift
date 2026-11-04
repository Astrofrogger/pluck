import AppKit
import SwiftUI

/// The Library's own Finder: panes tiled as a tiling window manager does them, each a Finder
/// view (icons, list or columns) of a folder, playing clips in place.
///
/// Keys (as i3 and Sway, with ⌥⌘ for their Mod key):
/// ⌘\ splits the pane in front to the right, ⇧⌘\ below; ⌥⌘W closes it;
/// ⌥⌘ + arrows moves between panes; ⇧⌥⌘ + arrows swaps them;
/// ⌥⌘1, ⌥⌘2, ⌥⌘3: icons, list, columns; ⌥⌘T turns a split (side by side, one above the other);
/// ⇧⌘N: a new folder in the pane in front; ⌥⌘V moves what was copied into it.
struct FinderWorkspaceView: View {
    @State private var workspace = FinderWorkspace.shared

    var body: some View {
        TileView(tile: workspace.root)
            .coordinateSpace(name: "finder")
            .background { shortcuts }
            // The window's back and forward (and the mouse's side buttons): the pane in front's.
            .onChange(of: navigationKey, initial: true) { claimNavigation() }
            .onDisappear {
                StudioNavigator.shared.toolBack = nil
                StudioNavigator.shared.toolForward = nil
            }
    }

    private var navigationKey: String {
        let pane = workspace.focused
        return "\(pane.id)|\(pane.url.path)|\(pane.canGoBack)|\(pane.canGoForward)|\(pane.playing?.path ?? "")|\(pane.viewing?.path ?? "")"
    }

    private func claimNavigation() {
        let pane = workspace.focused
        StudioNavigator.shared.toolBack = pane.canGoBack ? (pane.title, { pane.goBack() }) : nil
        StudioNavigator.shared.toolForward = pane.canGoForward ? { pane.goForward() } : nil
    }

    /// The tiling keys, anywhere in the Library (hidden buttons hold them).
    private var shortcuts: some View {
        ZStack {
            Button("Split Right") { workspace.split(.horizontal) }.keyboardShortcut("\\", modifiers: .command)
            Button("Split Below") { workspace.split(.vertical) }.keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Close Pane") { workspace.close() }.keyboardShortcut("w", modifiers: [.command, .option])
            Button("Left") { workspace.move(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Right") { workspace.move(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Up") { workspace.move(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Down") { workspace.move(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Swap Left") { workspace.swap(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Swap Right") { workspace.swap(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            Button("Swap Up") { workspace.swap(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            Button("Swap Down") { workspace.swap(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            Button("Icons") { workspace.focused.mode = .icons }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("List") { workspace.focused.mode = .list }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Columns") { workspace.focused.mode = .columns }.keyboardShortcut("3", modifiers: [.command, .option])
            Button("New Folder") { if workspace.focused.list == nil { workspace.focused.naming = .newFolder } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Move Here") { workspace.focused.paste(move: true) }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Turn Split") { workspace.turn() }.keyboardShortcut("t", modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A tile: a pane, or two tiles split side by side or one over the other.
private struct TileView: View {
    let tile: FinderWorkspace.Tile

    var body: some View {
        if let pane = tile.pane {
            FinderPaneView(pane: pane)
        } else if tile.children.count == 2 {
            FinderSplit(tile: tile)
        }
    }
}

/// Two tiles and the bar between them: easy to see, dragged to share the room, double-clicked
/// to share it evenly.
private struct FinderSplit: View {
    @Bindable var tile: FinderWorkspace.Tile
    @State private var dragStart: CGFloat?
    /// The resize cursor is pushed (popped when the pointer leaves, or the split closes under it).
    @State private var cursorPushed = false
    /// The bar's width; its line in the middle.
    private static let bar: CGFloat = 9
    private static let minimum: CGSize = CGSize(width: 280, height: 220)

    var body: some View {
        GeometryReader { geometry in
            let across = tile.axis == .horizontal
            let total = (across ? geometry.size.width : geometry.size.height) - Self.bar
            let least = across ? Self.minimum.width : Self.minimum.height
            let first = Self.clamp(tile.fraction * total, total: total, least: least)
            let layout = across ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                TileView(tile: tile.children[0])
                    .frame(width: across ? first : nil, height: across ? nil : first)
                handle(across: across, total: total, least: least)
                TileView(tile: tile.children[1])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handle(across: Bool, total: CGFloat, least: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.10))
            // A line along each edge, so where one pane ends is plain.
            let edges = across ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            edges {
                Rectangle().fill(Color.primary.opacity(0.30)).frame(width: across ? 1 : nil, height: across ? nil : 1)
                Spacer(minLength: 0)
                Rectangle().fill(Color.primary.opacity(0.30)).frame(width: across ? 1 : nil, height: across ? nil : 1)
            }
            Capsule().fill(Color.primary.opacity(0.45))
                .frame(width: across ? 3 : 36, height: across ? 36 : 3)
        }
        .frame(width: across ? Self.bar : nil, height: across ? nil : Self.bar)
        .contentShape(.rect)
        .onHover { inside in
            if inside, !cursorPushed { (across ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push(); cursorPushed = true }
            else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? tile.fraction * total
                if dragStart == nil { dragStart = start }
                let moved = across ? drag.translation.width : drag.translation.height
                tile.fraction = Self.clamp(start + moved, total: total, least: least) / max(total, 1)
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { withAnimation(.snappy) { tile.fraction = 0.5 } }
        .help("Drag to resize the panes, double-click to share evenly")
    }

    private static func clamp(_ first: CGFloat, total: CGFloat, least: CGFloat) -> CGFloat {
        guard total > least * 2 else { return total / 2 }
        return min(max(first, least), total - least)
    }
}

/// One pane: its bar (back and forward, the folder, how it's shown), the folder, and the path
/// at the foot.
struct FinderPaneView: View {
    @Bindable var pane: FinderPane
    @State private var workspace = FinderWorkspace.shared
    @FocusState private var focused: Bool
    @State private var dropping = false

    private var isFront: Bool { workspace.focusedID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            if pane.viewing == nil {
                header
                Divider()
            }
            Group {
                if let clip = pane.playing {
                    RawPlayerView(close: { pane.playing = nil }, openClip: { pane.playing = $0; pane.selection = [$0] },
                                  playlist: pane.clips, source: .clip(clip))
                        .id(clip)
                } else if let photo = pane.viewing {
                    FinderPhotoView(pane: pane, url: photo)
                } else {
                    content
                        .focusable()
                        .focused($focused)
                        .focusEffectDisabled()
                        .modifier(FinderKeys(pane: pane))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if pane.playing == nil && pane.viewing == nil {
                Divider()
                FinderPathBar(pane: pane)
            }
        }
        .frame(minWidth: 280, minHeight: 220)
        .background(.background)
        // The pane in front: a line along its top when there are several.
        .overlay(alignment: .top) {
            if workspace.panes.count > 1 {
                Rectangle().fill(isFront ? Color.accentColor : Color.clear).frame(height: 2)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(Color.accentColor, lineWidth: 3).padding(3).allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(pane) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("finder")) } action: { workspace.frames[pane.id] = $0 }
        .onChange(of: isFront, initial: true) { _, front in if front { focused = true } }
        .onChange(of: focused) { _, now in if now { workspace.focus(pane) } }
        .onChange(of: pane.selection) { FinderQuickLook.shared.follow(pane) }
        // Dropped here (from another pane, or Finder): copied into this folder, checked.
        .dropDestination(for: URL.self) { urls, _ in
            guard pane.list == nil, !urls.isEmpty else { return false }
            LibraryPanes.shared.drop(urls, into: pane.url)
            return true
        } isTargeted: { dropping = $0 }
        .modifier(FinderNaming(pane: pane))
    }

    /// This pane's split is one above the other.
    private var splitTurned: Bool { workspace.axis(of: pane) == .vertical }

    private var header: some View {
        HStack(spacing: 6) {
            Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!pane.canGoBack)
                .help("Back")
            Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!pane.canGoForward)
                .help("Forward")
            // (One pane: the window's title names its folder.)
            if workspace.panes.count > 1 {
                Text(pane.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            if pane.playing == nil {
                Picker("View", selection: $pane.mode) {
                    ForEach(FinderViewMode.allCases) { mode in
                        Image(systemName: mode.symbol).help(Text(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Icons, list or columns (⌥⌘1, ⌥⌘2, ⌥⌘3)")
                Menu {
                    Picker("Sort By", selection: $pane.sort) {
                        Text("Name").tag(FinderPane.Sort.name)
                        Text("Date Modified").tag(FinderPane.Sort.modified)
                        Text("Size").tag(FinderPane.Sort.size)
                        Text("Kind").tag(FinderPane.Sort.kind)
                    }
                    Toggle("Ascending", isOn: $pane.ascending)
                    Divider()
                    if pane.list == nil {
                        Button("New Folder", systemImage: "folder.badge.plus") { pane.naming = .newFolder }
                    }
                    if pane.list == nil, FootageFolders.shared.folder(containing: pane.url.path) == nil {
                        Button("Add to Library", systemImage: "plus.rectangle.on.folder") { FootageFolders.shared.add(pane.url) }
                    }
                    if Resolve.isInstalled, !pane.clips.isEmpty {
                        Button("Send Clips to DaVinci", systemImage: "arrow.up.forward.app") {
                            let chosen = pane.clips.filter { pane.selection.contains($0) }
                            Resolve.sendClipsAndShow(chosen.isEmpty ? pane.clips : chosen)
                        }
                    }
                    Divider()
                    Button("Split Right", systemImage: "square.split.2x1") { workspace.focus(pane); workspace.split(.horizontal) }
                        .disabled(workspace.panes.count >= FinderWorkspace.maxPanes)
                    Button("Split Below", systemImage: "square.split.1x2") { workspace.focus(pane); workspace.split(.vertical) }
                        .disabled(workspace.panes.count >= FinderWorkspace.maxPanes)
                    if workspace.panes.count > 1 {
                        Button(splitTurned ? "Put Side by Side" : "Put One Above the Other",
                               systemImage: splitTurned ? "square.split.2x1" : "square.split.1x2") { workspace.focus(pane); workspace.turn() }
                        Button("Close Pane", systemImage: "xmark.square") { workspace.focus(pane); workspace.close() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort, new folder, add to the Library, split")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        // (In columns, an empty folder is an empty column: the folders before it stay.)
        if pane.items.isEmpty, !pane.loading, pane.mode != .columns {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            switch pane.mode {
            case .icons: FinderIconsView(pane: pane)
            case .list: FinderListView(pane: pane)
            case .columns: FinderColumnsView(pane: pane)
            }
        }
    }
}

/// The keys within a pane, as in Finder: arrows, Return or ⌘↓ to open, ⌘↑ to go up, Space for
/// Quick Look, ⌘[ and ⌘] for back and forward, ⌘A, ⌘C, ⌘V (⌥⌘V to move), ⌘⌫, ⇧⌘N.
private struct FinderKeys: ViewModifier {
    let pane: FinderPane
    @AppStorage("finderIconSize") private var iconSize = 170.0

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                if press.modifiers.contains(.command) {
                    if press.key == .upArrow { pane.goUp(); return .handled }
                    if press.key == .downArrow { pane.openSelection(); return .handled }
                    return .ignored
                }
                guard pane.mode != .list else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                // Columns, as Finder: left to the folder before, right into the one chosen.
                if pane.mode == .columns, press.key == .leftArrow || press.key == .rightArrow {
                    if press.key == .leftArrow {
                        if pane.trail.count > 1 { pane.goUp() }
                    } else if let chosen = pane.shown.first(where: { pane.selection.contains($0.url) && $0.isFolder }) {
                        pane.go(to: chosen.url)
                        pane.selectFirst()
                    }
                    return .handled
                }
                switch press.key {
                case .leftArrow: pane.move(by: -1, extend: extend)
                case .rightArrow: pane.move(by: 1, extend: extend)
                case .upArrow: pane.move(by: pane.mode == .icons ? -columns : -1, extend: extend)
                default: pane.move(by: pane.mode == .icons ? columns : 1, extend: extend)
                }
                return .handled
            }
            .onKeyPress(.return) { pane.openSelection(); return .handled }
            // Space: Quick Look, as in Finder.
            .onKeyPress(.space) { FinderQuickLook.shared.toggle(pane); return .handled }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                pane.trashSelection()
                return .handled
            }
            .onKeyPress(keys: ["a", "c", "v", "[", "]"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "a": pane.selectAll()
                case "c": pane.copySelection()
                case "v": if !press.modifiers.contains(.option) { pane.paste() }
                case "[": pane.goBack()
                default: pane.goForward()
                }
                return .handled
            }
    }

    private var columns: Int { FinderPane.iconColumns(pane) }
}

// MARK: - Icons

/// Folders and files as tiles, as Finder's Icons view: clips with their picture (skim it by
/// moving the pointer across), folders and documents with their icons.
private struct FinderIconsView: View {
    let pane: FinderPane
    @AppStorage("finderIconSize") private var iconSize = 170.0

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize * 1.25), spacing: 14)], spacing: 18) {
                    ForEach(pane.shown) { item in
                        FinderIconTile(item: item, pane: pane, width: iconSize).id(item.url)
                    }
                }
                .padding(16)
            }
            .onChange(of: pane.anchor) { _, url in if let url { withAnimation { scroller.scrollTo(url) } } }
            // Clicking the space between: nothing selected.
            .background(Color.clear.contentShape(.rect).onTapGesture { pane.selection = [] }.contextMenu { FinderFolderMenu(pane: pane) })
        }
        .overlay(alignment: .bottomTrailing) {
            Slider(value: $iconSize, in: 110...320)
                .controlSize(.mini)
                .frame(width: 90)
                .padding(8)
                .help("Icon size")
        }
    }
}

private struct FinderIconTile: View {
    let item: FinderItem
    let pane: FinderPane
    let width: Double
    @State private var thumbs = FinderThumbnails.shared
    @State private var skimming = false
    @State private var targeted = false

    private var selected: Bool { pane.selection.contains(item.url) }

    var body: some View {
        VStack(spacing: 6) {
            picture
                .frame(width: width, height: width * 0.6)
                .background(selected || targeted ? Color.primary.opacity(0.12) : Color.clear, in: .rect(cornerRadius: Design.Radius.thumbnail))
            Text(item.name)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 4))
            if item.isClip, let summary = thumbs.summaries[item.url] {
                Text(Self.caption(summary)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(.rect)
        .onTapGesture(count: 2) { pane.open(item) }
        .simultaneousGesture(TapGesture().onEnded { pane.click(item, modifiers: Self.modifiers) })
        .fileDrag { FinderDrag.urls(item.url, in: pane) }
        .modifier(FolderDrop(item: item, targeted: $targeted))
        .contextMenu { FinderItemMenu(item: item, pane: pane) }
        .help(item.url.path)
        .onAppear { if item.isClip { thumbs.want(item.url) } else if item.isPhoto { thumbs.wantPicture(item.url) } }
        .onDisappear { if item.isClip { thumbs.forget(item.url) } else if item.isPhoto { thumbs.forgetPicture(item.url) } }
    }

    @ViewBuilder private var picture: some View {
        if item.isClip, let poster = thumbs.posters[item.url] {
            let skim = skimming ? thumbs.skimmed.flatMap { $0.url == item.url ? $0.image : nil } : nil
            Image(decorative: skim ?? poster, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
                .padding(4)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        skimming = true
                        thumbs.skim(item.url, at: point.x / max(width - 8, 1))
                    case .ended:
                        skimming = false
                        thumbs.endSkim(item.url)
                    }
                }
        } else if item.isPhoto, let picture = thumbs.pictures[item.url] {
            Image(decorative: picture, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
                .padding(4)
        } else {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(width * 0.08)
        }
    }

    static var modifiers: EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    static func caption(_ summary: RawClipSummary) -> String {
        let seconds = Int(Double(summary.frames) / max(summary.fps, 1))
        let rate = summary.fps.rounded() == summary.fps ? "\(Int(summary.fps))" : String(format: "%.2f", summary.fps)
        return String(format: "%d:%02d", seconds / 60, seconds % 60) + " · \(summary.width)×\(summary.height) · \(rate) fps"
    }
}

/// A folder takes what's dropped onto it (copied in, checked).
private struct FolderDrop: ViewModifier {
    let item: FinderItem
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                LibraryPanes.shared.drop(urls, into: item.url)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// A right-click between the files: what's for the folder itself.
private struct FinderFolderMenu: View {
    let pane: FinderPane

    var body: some View {
        if pane.list == nil {
            Button("New Folder") { pane.naming = .newFolder }
            Button("Paste") { pane.paste() }
            Button("Move Here") { pane.paste(move: true) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pane.url]) }
        }
    }
}

/// Asks for a name: a new folder's, or a file's new one (as Finder's New Folder and Rename).
private struct FinderNaming: ViewModifier {
    let pane: FinderPane
    @State private var name = ""
    @State private var problem: String?
    /// Asked again after it couldn't be done: the name typed and why stay.
    @State private var again = false

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { pane.naming != nil }, set: { if !$0 { pane.naming = nil } })) {
                TextField("Name", text: $name)
                Button(pane.naming == .newFolder ? "Create" : "Rename") { finish() }
                Button("Cancel", role: .cancel) { pane.naming = nil }
            } message: {
                if let problem { Text(problem) }
            }
            .onChange(of: pane.naming, initial: true) { _, naming in
                guard naming != nil else { return }
                if again { again = false; return }
                problem = nil
                switch naming {
                case .rename(let url): name = url.lastPathComponent
                default: name = pane.freeFolderName
                }
            }
    }

    private var title: String {
        if case .rename(let url) = pane.naming { return String(localized: "Rename “\(url.lastPathComponent)”") }
        return String(localized: "New Folder")
    }

    private func finish() {
        guard let naming = pane.naming else { return }
        let failed: String?
        switch naming {
        case .newFolder: failed = pane.newFolder(named: name)
        case .rename(let url): failed = pane.rename(url, to: name)
        }
        // (Asked again, with why, when it couldn't be done.)
        pane.naming = nil
        if let failed {
            problem = failed
            again = true
            Task { @MainActor in pane.naming = naming }
        }
    }
}

/// What a right-click on a file or folder offers.
private struct FinderItemMenu: View {
    let item: FinderItem
    let pane: FinderPane

    var body: some View {
        Button(item.isClip ? "Play" : "Open") { pane.open(item) }
        Button("Quick Look") {
            if !pane.selection.contains(item.url) { pane.selection = [item.url]; pane.anchor = item.url }
            FinderQuickLook.shared.toggle(pane)
        }
        if item.isPhoto { Button(FinderPhotoView.openTitle(item.url)) { NSWorkspace.shared.open(item.url) } }
        if item.isFolder {
            Button("Open in a Pane to the Right") {
                FinderWorkspace.shared.focus(pane)
                FinderWorkspace.shared.split(.horizontal)
                FinderWorkspace.shared.focused.go(to: item.url)
            }
            .disabled(FinderWorkspace.shared.panes.count >= FinderWorkspace.maxPanes)
            if FootageFolders.shared.folder(containing: item.url.path) == nil {
                Button("Add to Library") { FootageFolders.shared.add(item.url) }
            }
        }
        if item.isClip {
            Button("Edit") { StudioNavigator.shared.open(EditorTarget(path: item.url.path)) }
            if Resolve.isInstalled { Button("Send to DaVinci") { Resolve.sendClipsAndShow([item.url]) } }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if pane.list == nil { Button("Rename…") { pane.naming = .rename(item.url) } }
        Button("Copy") {
            if !pane.selection.contains(item.url) { pane.selection = [item.url] }
            pane.copySelection()
        }
        if let other = FinderWorkspace.shared.panes.first(where: { $0.id != pane.id && $0.list == nil }), pane.list == nil {
            Button("Copy to \(other.title)") {
                let chosen = pane.selection.contains(item.url) ? Array(pane.selection) : [item.url]
                LibraryPanes.shared.copy(chosen, into: other.url)
            }
            Button("Move to \(other.title)") {
                let chosen = pane.selection.contains(item.url) ? Array(pane.selection) : [item.url]
                LibraryPanes.shared.copy(chosen, into: other.url, move: true)
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if !pane.selection.contains(item.url) { pane.selection = [item.url] }
            pane.trashSelection()
        }
    }
}

// MARK: - List

/// Everything as rows, as Finder's List view, with what a clip is in columns of its own.
private struct FinderListView: View {
    @Bindable var pane: FinderPane
    @State private var thumbs = FinderThumbnails.shared
    @State private var order = [KeyPathComparator(\FinderRow.name)]

    var body: some View {
        Table(rows, selection: $pane.selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    if row.item.isPhoto, let picture = thumbs.pictures[row.item.url] {
                        Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    } else {
                        Image(nsImage: row.item.icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .fileDrag { FinderDrag.urls(row.item.url, in: pane) }
                .onAppear { if row.item.isClip { thumbs.want(row.item.url) } else if row.item.isPhoto { thumbs.wantPicture(row.item.url) } }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size", value: \.size) { row in
                Text(row.item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Length", value: \.length) { row in
                Text(row.length > 0 ? Format.duration(row.length) : "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn("Frame", value: \.pixels) { row in
                Text(row.summary.map { "\($0.width)×\($0.height)" } ?? "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Rate", value: \.fps) { row in
                Text(row.fps > 0 ? String(format: row.fps.rounded() == row.fps ? "%.0f" : "%.2f", row.fps) : "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 40, ideal: 50)
            TableColumn("Kind", value: \.kind) { row in Text(row.kind).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first, let item = pane.shown.first(where: { $0.url == url }) { FinderItemMenu(item: item, pane: pane) }
        } primaryAction: { urls in
            pane.selection = urls
            pane.openSelection()
        }
    }

    private var rows: [FinderRow] {
        let made = pane.shown.map { FinderRow(item: $0, summary: thumbs.summaries[$0.url]) }
        // Folders first, then in the order of the column clicked.
        return made.sorted { a, b in
            if a.item.isFolder != b.item.isFolder { return a.item.isFolder }
            return order.compare(a, b) == .orderedAscending
        }
    }
}

/// A list row's values, for sorting by any column.
private struct FinderRow: Identifiable {
    let item: FinderItem
    let summary: RawClipSummary?
    var id: URL { item.url }
    var name: String { item.name }
    var modified: Date { item.modified ?? .distantPast }
    var size: Int64 { item.size ?? -1 }
    var kind: String { item.kind }
    var length: Double { summary.map { Double($0.frames) / max($0.fps, 1) } ?? 0 }
    var pixels: Int { summary.map { $0.width * $0.height } ?? 0 }
    var fps: Double { summary?.fps ?? 0 }
}

// MARK: - Columns

/// Folders side by side, as Finder's (and ranger's) column view: each folder chosen opens the
/// next column; a clip chosen shows its picture at the end.
private struct FinderColumnsView: View {
    let pane: FinderPane

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pane.trail.enumerated()), id: \.element) { index, folder in
                        let last = index == pane.trail.count - 1
                        FinderColumn(folder: folder, pane: pane, current: last,
                                     chosen: last ? nil : pane.trail[index + 1])
                            .frame(width: 230)
                        Divider()
                    }
                    if let chosen = pane.shown.first(where: { pane.selection.contains($0.url) && !$0.isFolder }) {
                        FinderPreview(item: chosen, pane: pane).frame(width: 300).id("preview")
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
            .onChange(of: pane.url) { withAnimation { scroller.scrollTo("end") } }
            .onAppear { scroller.scrollTo("end") }
        }
    }
}

private struct FinderColumn: View {
    let folder: URL
    let pane: FinderPane
    /// The folder the pane is on (its items, live), or one above it.
    let current: Bool
    /// The folder in this one that's open to the right.
    let chosen: URL?
    @State private var items: [FinderItem] = []

    var body: some View {
        let list = current ? pane.shown : items
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(list) { item in
                    // (By path: a folder's URL may end in a slash or not.)
                    let on = item.url.standardizedFileURL.path == chosen?.standardizedFileURL.path || (current && pane.selection.contains(item.url))
                    HStack(spacing: 6) {
                        Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if item.isFolder { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 4))
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { if item.isFolder || current { pane.open(item) } else { pane.open(item, in: folder) } }
                    .simultaneousGesture(TapGesture().onEnded {
                        if item.isFolder { pane.go(to: item.url) } else {
                            if !current { pane.go(to: folder) }
                            pane.selection = [item.url]
                            pane.anchor = item.url
                        }
                    })
                    .fileDrag { FinderDrag.urls(item.url, in: pane, selected: current) }
                    .contextMenu { FinderItemMenu(item: item, pane: pane) }
                }
            }
            .padding(4)
        }
        // (Again when it stops being the live column: it then shows its own copy.)
        .task(id: "\(folder.path)|\(current)") {
            guard !current else { return }
            let url = folder
            let read = await Task.detached(priority: .userInitiated) {
                ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    .map { ($0, FinderItem.read($0)) }
            }.value
            items = read.map { FinderItem(url: $0.0, isFolder: $0.1.isFolder, isClip: $0.1.isClip, size: $0.1.size, modified: $0.1.modified, kind: $0.1.kind) }
                .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
    }
}

/// The column view's end: the chosen file's picture and what it is.
private struct FinderPreview: View {
    let item: FinderItem
    let pane: FinderPane
    @State private var thumbs = FinderThumbnails.shared

    var body: some View {
        VStack(spacing: 10) {
            if item.isClip, let poster = thumbs.posters[item.url] {
                Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit).clipShape(.rect(cornerRadius: 6))
            } else if item.isPhoto, let picture = thumbs.pictures[item.url] {
                Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit).clipShape(.rect(cornerRadius: 6))
            } else {
                Image(nsImage: item.icon).resizable().aspectRatio(contentMode: .fit).frame(width: 96, height: 96)
            }
            Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            if let summary = thumbs.summaries[item.url] {
                Text(FinderIconTile.caption(summary)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text([item.kind, item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Button(item.isClip ? "Play" : "Open") { pane.open(item) }
                .buttonStyle(GlassCapsuleButtonStyle())
            Spacer()
        }
        .padding(14)
        .onAppear { if item.isClip { thumbs.want(item.url) } else if item.isPhoto { thumbs.wantPicture(item.url) } }
    }
}

// MARK: - The foot

/// Finder's path bar (each folder up to here, to go back to) and how many items there are.
private struct FinderPathBar: View {
    let pane: FinderPane

    var body: some View {
        HStack(spacing: 2) {
            // (Scrolled to its end: where the pane is.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.pathComponents.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button { pane.go(to: url) } label: {
                            HStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 13, height: 13)
                                Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pane.list != nil)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            Spacer(minLength: 8)
            Text(status).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var status: String {
        let count = String(AttributedString(localized: "^[\(pane.shown.count) item](inflect: true)").characters)
        let picked = pane.selection.count > 1 ? String(localized: "\(pane.selection.count) selected") + ", " : ""
        guard pane.list == nil, let free = OffloadCenter.freeSpace(pane.url) else { return picked + count }
        return picked + count + ", " + String(localized: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available")
    }
}
