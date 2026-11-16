import AppKit
import SwiftUI

/// The Library's own Finder: panes tiled as a tiling window manager does them, each a Finder
/// view (icons, list or columns) of a folder, playing clips in place.
///
/// Keys (as i3 and Sway, with ⌥⌘ for their Mod key):
/// ⌘\ splits the pane in front to the right, ⇧⌘\ below; ⌘W closes it (with one pane, the window);
/// ⌥⌘ + arrows moves between panes; ⇧⌥⌘ + arrows swaps them;
/// ⌘1 to ⌘4 (icons, list, columns, gallery: held by the Library); ⌥⌘T turns a split (side by
/// side, one above the other); ⇧⌘N: a new folder in the pane in front; ⌥⌘V moves what was copied into it.
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
            // (Only while there are several: with one, ⌘W is the menu's Close, for the window.)
            if workspace.panes.count > 1 {
                Button("Close Pane") { workspace.close() }.keyboardShortcut("w", modifiers: .command)
            }
            Button("Left") { workspace.move(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Right") { workspace.move(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Up") { workspace.move(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Down") { workspace.move(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Swap Left") { workspace.swap(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Swap Right") { workspace.swap(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            Button("Swap Up") { workspace.swap(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            Button("Swap Down") { workspace.swap(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            Button("New Folder") { workspace.focused.newFolderInPlace() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Move Here") { workspace.focused.paste(move: true) }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Turn Split") { workspace.turn() }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Show Hidden Files") { FinderPane.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
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
            // (A pane just closed makes this tile a pane: it's read once more before it goes.)
            if tile.children.count == 2 {
                layout {
                    TileView(tile: tile.children[0])
                        .frame(width: across ? first : nil, height: across ? nil : first)
                    handle(across: across, total: total, least: least)
                    TileView(tile: tile.children[1])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

// MARK: - Widths dragged

/// Widths the pointer drags, as Finder's sidebar, columns and preview, kept in UserDefaults per place.
enum FinderWidth {
    /// The browser a pane is in, for its keys: by where its files come from (another Mac, a NAS), else this Mac's.
    @MainActor static func place(of pane: FinderPane) -> String { pane.source.map { String(describing: type(of: $0)) } ?? "local" }

    /// A stored width (nil: none yet) as used: `initial`, kept in `range`.
    static func clamp(_ value: Double?, initial: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value.map { CGFloat($0) } ?? initial, range.lowerBound), range.upperBound)
    }

    static func stored(_ key: String, initial: CGFloat, range: ClosedRange<CGFloat>, in defaults: UserDefaults = .standard) -> CGFloat {
        clamp(defaults.object(forKey: key) as? Double, initial: initial, range: range)
    }
}

/// The view at its stored width, with a hairline-thin grip at `edge` to drag it (double-click: back to `initial`).
private struct FinderResizable: ViewModifier {
    let initial: CGFloat
    let range: ClosedRange<CGFloat>
    let edge: HorizontalEdge
    @AppStorage private var width: Double
    @State private var start: CGFloat?
    @State private var cursorPushed = false

    init(key: String, initial: CGFloat, range: ClosedRange<CGFloat>, edge: HorizontalEdge) {
        self.initial = initial
        self.range = range
        self.edge = edge
        _width = AppStorage(wrappedValue: Double(initial), key)
    }

    func body(content: Content) -> some View {
        let shown = FinderWidth.clamp(width, initial: initial, range: range), sign: CGFloat = edge == .trailing ? 1 : -1
        content
            .frame(width: shown)
            .overlay(alignment: edge == .trailing ? .trailing : .leading) {
                // (Over the divider beside it: the grip straddles the line, as in Finder.)
                Color.clear.frame(width: 8).contentShape(.rect).offset(x: 4 * sign)
                    .onHover { inside in
                        if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                        else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let from = start ?? shown
                            if start == nil { start = from }
                            width = Double(FinderWidth.clamp(Double(from + drag.translation.width * sign), initial: initial, range: range))
                        }
                        .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { width = Double(initial) }
                    .accessibilityHidden(true)
            }
            .zIndex(1)
    }
}

extension View {
    /// Its width dragged at `edge` and kept under `key` (Finder's sidebar, columns, preview).
    func finderResizable(_ key: String, width: CGFloat, range: ClosedRange<CGFloat>, edge: HorizontalEdge = .trailing) -> some View {
        modifier(FinderResizable(key: key, initial: width, range: range, edge: edge))
    }
}

/// One pane: its bar (back and forward, the folder, how it's shown), the folder, and the path
/// at the foot.
struct FinderPaneView: View {
    @Bindable var pane: FinderPane
    @State private var workspace = FinderWorkspace.shared
    @FocusState private var focused: Bool
    @State private var dropping = false
    @State private var hovering = false

    private var isFront: Bool { workspace.focusedID == pane.id }
    /// One of the Library's tiled panes (not one shown by itself elsewhere, as another Mac's files).
    private var tiled: Bool { workspace.panes.count > 1 && workspace.panes.contains { $0 === pane } }

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
        // Studio: the same grey as the panel around it, not the Mac's window grey.
        .background(Edition.isStudio ? AnyShapeStyle(Design.Studio.panel) : AnyShapeStyle(.background))
        // The pane in front: a line along its top when there are several.
        .overlay(alignment: .top) {
            if tiled {
                Rectangle().fill(isFront ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear)).frame(height: 2)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Design.Radius.box).strokeBorder(.tint, lineWidth: 3).padding(3).allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(pane) })
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("finder")) } action: { workspace.frames[pane.id] = $0 }
        .onChange(of: isFront, initial: true) { _, front in if front { focused = true } }
        .onChange(of: focused) { _, now in if now { workspace.focus(pane) } }
        .onChange(of: pane.selection) { FinderQuickLook.shared.follow(pane) }
        // A name typed in place, done: the keys are the folder's again.
        .onChange(of: pane.naming) { _, naming in if naming == nil, isFront { focused = true } }
        // Dropped here (from another pane, or Finder): copied into this folder, checked.
        .dropDestination(for: URL.self) { urls, _ in
            guard pane.list == nil, pane.source == nil, !urls.isEmpty else { return false }
            LibraryPanes.shared.drop(urls, into: pane.url)
            return true
        } isTargeted: { dropping = $0 }
        .modifier(FinderNaming(pane: pane))
    }

    /// This pane's split is one above the other.
    private var splitTurned: Bool { workspace.axis(of: pane) == .vertical }

    private var header: some View {
        HStack(spacing: 6) {
            // Closing it, as a Finder tab: on the pane in front, or the one under the pointer.
            if tiled {
                Button { workspace.focus(pane); workspace.close() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 16, height: 16).contentShape(.rect)
                }
                .foregroundStyle(.secondary)
                .opacity(isFront || hovering ? 1 : 0)
                .help("Close Pane (⌘W)")
                .accessibilityLabel("Close Pane")
            }
            // Back and forward as Finder has them: one box, two halves.
            HStack(spacing: 0) {
                Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!pane.canGoBack)
                    .help("Back (⌘[)")
                    .accessibilityLabel("Back")
                Rectangle().fill(Design.Studio.line).frame(width: 1, height: 14)
                Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!pane.canGoForward)
                    .help("Forward (⌘])")
                    .accessibilityLabel("Forward")
            }
            .buttonStyle(FinderToolButtonStyle(raised: false))
            .background(Design.Studio.raised)
            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            if let title = shownTitle {
                Text(verbatim: title)
                    .font(Design.Studio.sectionTitle)
                    .foregroundStyle(Design.Studio.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            if pane.searching { ProgressView().controlSize(.small).help("Searching this folder and the folders in it") }
            if let tag = pane.tagFilter {
                Button { pane.tagFilter = nil } label: {
                    HStack(spacing: 4) {
                        Circle().fill(FinderTags.swatch(tag)).frame(width: 9, height: 9)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                }
                .help("Showing only \(FinderTags.name(tag)): click to show everything")
            }
            if pane.playing == nil {
                StudioSegmented(ground: Design.Studio.raised, options: FinderViewMode.allCases.map { ($0, $0.title) },
                                selection: $pane.mode, symbols: FinderViewMode.allCases.map(\.symbol))
                    .fixedSize()
                Menu {
                    Picker("Sort By", selection: $pane.sort) {
                        Text("Name").tag(FinderPane.Sort.name)
                        Text("Date Modified").tag(FinderPane.Sort.modified)
                        Text("Size").tag(FinderPane.Sort.size)
                        Text("Kind").tag(FinderPane.Sort.kind)
                    }
                    Toggle("Ascending", isOn: $pane.ascending)
                    Picker("Show Tag", selection: $pane.tagFilter) {
                        Text("Everything").tag(Int?.none)
                        ForEach(FinderTags.colors, id: \.self) { color in
                            Label { Text(FinderTags.name(color)) } icon: { Image(nsImage: FinderTags.dot(color)) }.tag(Int?.some(color))
                        }
                    }
                    // (⇧⌘. is held by the workspace's keys.)
                    Toggle("Show Hidden Files", isOn: Binding(get: { FinderPane.showsHidden }, set: { _ in FinderPane.toggleHidden() }))
                    if pane.source == nil {
                    Divider()
                    if pane.list == nil {
                        Button("New Folder", systemImage: "folder.badge.plus") { pane.newFolderInPlace() }
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
                    }
                    if tiled {
                        Button(splitTurned ? "Put Side by Side" : "Put One Above the Other",
                               systemImage: splitTurned ? "square.split.2x1" : "square.split.1x2") { workspace.focus(pane); workspace.turn() }
                        Button("Close Pane", systemImage: "xmark.square") { workspace.focus(pane); workspace.close() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(FinderToolButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort, new folder, add to the Library, split")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: Self.toolbarHeight)
    }

    /// The bar's height (FinderSidebar centres its first heading on it).
    static let toolbarHeight: CGFloat = 38

    /// The folder's name, as Finder's window title; none at a server's top folder, which the page
    /// above already names (Deliver's "Studio NAS"): there, only the folders inside get one.
    private var shownTitle: String? {
        if let source = pane.source, source.rootName != nil, pane.url.standardizedFileURL == source.root.standardizedFileURL { return nil }
        return pane.title
    }

    @ViewBuilder private var content: some View {
        // (In columns, an empty folder is an empty column: the folders before it stay.)
        if pane.shown.isEmpty, !pane.loading, !pane.searching, pane.mode != .columns {
            if !pane.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "No Results", line: "Nothing here or in the folders in it has that name or text.")
            } else if pane.tagFilter != nil, !pane.items.isEmpty {
                StudioEmptyState(symbol: "tag", title: "Nothing With That Tag")
            } else {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        } else {
            switch pane.mode {
            case .icons: FinderIconsView(pane: pane)
            case .list: FinderListView(pane: pane)
            case .columns: FinderColumnsView(pane: pane)
            case .gallery: FinderGalleryView(pane: pane)
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
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in if pane.naming != nil { return .ignored };
                if press.modifiers.contains(.command) {
                    if press.key == .upArrow { pane.goUp(); return .handled }
                    if press.key == .downArrow { pane.openSelection(); return .handled }
                    return .ignored
                }
                guard pane.mode != .list else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                // Gallery: one along the filmstrip either way.
                if pane.mode == .gallery {
                    pane.move(by: press.key == .leftArrow || press.key == .upArrow ? -1 : 1, extend: extend)
                    return .handled
                }
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
            // Return renames, as in Finder (⌘O, ⌘↓ or a double-click opens).
            .onKeyPress(.return) { if pane.naming != nil { return .ignored }; if pane.list == nil, pane.source == nil { pane.beginRename() } else { pane.openSelection() }; return .handled }
            .onKeyPress(.escape) { if pane.naming != nil { return .ignored };
                guard !pane.selection.isEmpty else { return .ignored }
                pane.selection = []
                return .handled
            }
            .onKeyPress(phases: .down) { press in if pane.naming != nil { return .ignored };
                guard TypeSelect.isTyping(press), press.key != .space else { return .ignored }
                pane.jump(press.characters)
                return .handled
            }
            // Space: Quick Look, as in Finder.
            .onKeyPress(.space) { if pane.naming != nil { return .ignored }; pane.quickLook(); return .handled }
            .onKeyPress(.delete, phases: .down) { press in if pane.naming != nil { return .ignored };
                guard press.modifiers.contains(.command) else { return .ignored }
                pane.trashSelection()
                return .handled
            }
            .onKeyPress(keys: ["a", "c", "v", "[", "]"]) { press in if pane.naming != nil { return .ignored };
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

    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize * 1.25), spacing: 14)], spacing: 18) {
                    ForEach(pane.shown) { item in
                        FinderIconTile(item: item, pane: pane, width: iconSize).id(item.url).rubberBandItem(item.url)
                    }
                }
                .padding(16)
                // (The whole height: a rubber band can start under the last row.)
                .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
                // Clicking the space between: nothing selected; dragging there: a rubber band.
                .modifier(RubberBand(selection: Bindable(pane).selection))
                .contextMenu { FinderFolderMenu(pane: pane) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .onChange(of: pane.anchor) { _, url in if let url { withAnimation { scroller.scrollTo(url) } } }
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
            if pane.naming == .rename(item.url) {
                FinderNameField(item: item, pane: pane)
            } else {
                HStack(spacing: 4) {
                    FinderTagDots(tags: item.tags)
                    Text(item.name)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 4))
                }
            }
            if item.isClip, let summary = thumbs.summaries[item.url] {
                Text(Self.caption(summary)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(.rect)
        .onTapGesture(count: 2) { pane.open(item) }
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            // A click on the name of the one already selected: renamed in place, as in Finder.
            let rename = Self.modifiers.isEmpty && pane.selection == [item.url] && tap.location.y > width * 0.6
            pane.click(item, modifiers: Self.modifiers)
            if rename { pane.renameSoon(item.url) }
        })
        .fileDrag { FinderDrag.urls(item.url, in: pane) }
        .modifier(FolderDrop(item: item, targeted: $targeted, enabled: pane.source == nil))
        .contextMenu { FinderItemMenu(item: item, pane: pane) }
        .help(item.url.path)
        .modifier(FinderWantsPicture(item: item))
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
    var enabled = true

    func body(content: Content) -> some View {
        if item.isFolder, enabled {
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
        if pane.list == nil, pane.source == nil {
            Button("New Folder") { pane.newFolderInPlace() }
            Button("Paste") { pane.paste() }
            Button("Move Here") { pane.paste(move: true) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pane.url]) }
        }
    }
}

/// Why a rename or a new folder couldn't be done, and asking before files go to the Trash.
private struct FinderNaming: ViewModifier {
    @Bindable var pane: FinderPane

    func body(content: Content) -> some View {
        content
            .alert("Can’t Do That", isPresented: Binding(get: { pane.problem != nil }, set: { if !$0 { pane.problem = nil } })) {
                Button("OK") { pane.problem = nil }
            } message: {
                Text(pane.problem ?? "")
            }
            .confirmationDialog(pane.trashing.count == 1 ? String(localized: "Move “\(pane.trashing[0].lastPathComponent)” to the Trash?")
                                    : String(localized: "Move \(pane.trashing.count) items to the Trash?"),
                                isPresented: Binding(get: { !pane.trashing.isEmpty }, set: { if !$0 { pane.trashing = [] } })) {
                Button("Move to Trash", role: .destructive) { pane.trash(pane.trashing) }
            } message: {
                Text("You can put it back from the Trash in Finder.")
            }
            .sheet(isPresented: Binding(get: { !pane.renamingMany.isEmpty }, set: { if !$0 { pane.renamingMany = [] } })) {
                BatchRenameSheet(urls: pane.renamingMany) { failed in
                    pane.renamingMany = []
                    pane.problem = failed
                }
            }
            .sheet(isPresented: Binding(get: { pane.reading != nil }, set: { if !$0 { pane.reading = nil } })) {
                if let url = pane.reading { MarkdownReader(url: url) { pane.reading = nil } }
            }
    }
}

/// A file's or folder's name typed over in place (Return, or a click on the selected one's name).
struct FinderNameField: View {
    let item: FinderItem
    let pane: FinderPane

    var body: some View {
        InlineNameField(initial: item.url.lastPathComponent) { name in
            pane.naming = nil
            if let failed = pane.rename(item.url, to: name) { pane.problem = failed }
        } cancel: {
            pane.naming = nil
        }
    }
}

/// What a right-click on a file or folder offers.
private struct FinderItemMenu: View {
    let item: FinderItem
    let pane: FinderPane

    /// The selection when it's in it, else this one.
    private var chosen: [URL] { pane.selection.contains(item.url) ? pane.chosen : [item.url] }

    var body: some View {
        if let source = pane.source { source.menu(chosen) } else { local }
    }

    @ViewBuilder private var local: some View {
        Button(item.isClip ? "Play" : "Open") { pane.open(item) }
        OpenWithMenu(urls: chosen)
        Button("Quick Look") {
            if !pane.selection.contains(item.url) { pane.selection = [item.url]; pane.anchor = item.url }
            pane.quickLook()
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
        if pane.list == nil {
            if chosen.count > 1 {
                Button("Rename \(chosen.count) Items…") { pane.renamingMany = chosen }
            } else {
                Button("Rename") { pane.selection = [item.url]; pane.anchor = item.url; pane.naming = .rename(item.url) }
            }
            Button("Duplicate") {
                if !pane.selection.contains(item.url) { pane.selection = [item.url] }
                pane.duplicateSelection()
            }
        }
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
        if pane.list == nil {
            Button(chosen.count == 1 ? String(localized: "Compress “\(item.name)”") : String(localized: "Compress \(chosen.count) Items")) { pane.compress(chosen) }
            if chosen.count == 1, FinderArchive.isZip(item.url) { Button("Uncompress") { pane.uncompress(item.url) } }
        }
        FinderTagMenu(urls: chosen, pane: pane)
        Divider()
        Button("Move to Trash…", role: .destructive) {
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
    @State private var cache = FinderRowCache()
    /// The columns' widths (and order) as dragged, kept per place.
    @AppStorage private var kept: Data
    @State private var columns = TableColumnCustomization<FinderRow>()

    init(pane: FinderPane) {
        self.pane = pane
        _kept = AppStorage(wrappedValue: Data(), "finderListColumns." + FinderWidth.place(of: pane))
    }

    var body: some View {
        Table(rows, selection: $pane.selection, sortOrder: $order, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    FinderSmallIcon(item: row.item)
                    if pane.naming == .rename(row.item.url) {
                        FinderNameField(item: row.item, pane: pane)
                    } else {
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        FinderTagDots(tags: row.item.tags)
                    }
                }
                .fileDrag { FinderDrag.urls(row.item.url, in: pane) }
            }
            .width(min: 160, ideal: 280).customizationID("name")
            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150).customizationID("modified")
            TableColumn("Size", value: \.size) { row in
                Text(row.item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80).customizationID("size")
            // (The clip's details as they arrive; the order they sort in is from when the list was made.)
            TableColumn("Length", value: \.length) { row in
                let live = FinderRow(item: row.item, summary: thumbs.summaries[row.id])
                Text(live.length > 0 ? Format.duration(live.length) : "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 70).customizationID("length")
            TableColumn("Frame", value: \.pixels) { row in
                Text(thumbs.summaries[row.id].map { "\($0.width)×\($0.height)" } ?? "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90).customizationID("frame")
            TableColumn("Rate", value: \.fps) { row in
                let fps = thumbs.summaries[row.id]?.fps ?? 0
                Text(fps > 0 ? String(format: fps.rounded() == fps ? "%.0f" : "%.2f", fps) : "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 40, ideal: 50).customizationID("rate")
            TableColumn("Kind", value: \.kind) { row in Text(row.kind).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 110).customizationID("kind")
        }
        .onAppear { columns = (try? JSONDecoder().decode(TableColumnCustomization<FinderRow>.self, from: kept)) ?? columns }
        .onChange(of: columns) { kept = (try? JSONEncoder().encode(columns)) ?? kept }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first, let item = pane.shown.first(where: { $0.url == url }) { FinderItemMenu(item: item, pane: pane) }
        } primaryAction: { urls in
            pane.selection = urls
            pane.openSelection()
        }
        // The panel's grey shows through (Studio), like the other views.
        .scrollContentBackground(Edition.isStudio ? .hidden : .automatic)
    }

    /// Made once per change of the folder or the order (not on every look: a folder can hold thousands).
    private var rows: [FinderRow] {
        if cache.version == pane.version, cache.order == order { return cache.rows }
        let summaries = thumbs.summaries
        let made = pane.shown.map { FinderRow(item: $0, summary: summaries[$0.url]) }
        // Folders first, then in the order of the column clicked (by name: already so).
        let byName = order == [KeyPathComparator(\FinderRow.name)] && pane.sort == .name && pane.ascending
        cache.rows = byName ? made : made.sorted { a, b in
            if a.item.isFolder != b.item.isFolder { return a.item.isFolder }
            return order.compare(a, b) == .orderedAscending
        }
        cache.version = pane.version
        cache.order = order
        return cache.rows
    }
}

/// The list's rows, kept between looks.
private final class FinderRowCache {
    var version = -1
    var order: [KeyPathComparator<FinderRow>] = []
    var rows: [FinderRow] = []
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

// MARK: - Gallery

/// Finder's Gallery view: the chosen file large (a clip's picture, a photo), the folder in a
/// filmstrip below; the arrows go along it.
private struct FinderGalleryView: View {
    let pane: FinderPane
    @State private var thumbs = FinderThumbnails.shared

    var body: some View {
        StudioGallery(items: pane.shown, current: pane.anchor ?? pane.selection.first,
                      choose: { pane.click($0, modifiers: EventModifiers.held) }, open: { pane.open($0) }) { item in
            VStack(spacing: 10) {
                Group {
                    // A document, text, PDF…: its contents (FilePreview); a film, song or folder: its picture.
                    if !item.isFolder, !item.isClip, pane.source == nil, FilePreview.showsContents(item.url) {
                        FilePreview(url: item.url).clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                    } else {
                        picture(item)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 6) {
                    FinderTagDots(tags: item.tags)
                    Text(item.name).font(Design.Studio.sectionTitle).lineLimit(1).truncationMode(.middle)
                }
                Text([item.kind, item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .contextMenu { FinderItemMenu(item: item, pane: pane) }
            .fileDrag { FinderDrag.urls(item.url, in: pane) }
            .modifier(FinderWantsPicture(item: item))
        } thumb: { item in
            picture(item).frame(maxWidth: .infinity, maxHeight: .infinity).background(Design.Studio.raised)
                .modifier(FinderWantsPicture(item: item))
                .contextMenu { FinderItemMenu(item: item, pane: pane) }
        }
    }

    @ViewBuilder private func picture(_ item: FinderItem) -> some View {
        if let image = item.isClip ? thumbs.posters[item.url] : thumbs.pictures[item.url] {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: item.icon).resizable().aspectRatio(contentMode: .fit).padding(6)
        }
    }
}

// MARK: - Columns

/// Folders side by side, as Finder's (and ranger's) column view: each folder chosen opens the
/// next column; a clip chosen shows its picture at the end.
private struct FinderColumnsView: View {
    let pane: FinderPane
    /// One width for every column (dragging one's edge sets them all), kept per place.
    @AppStorage private var columnWidth: Double
    private let key: String
    static let columnWidths: ClosedRange<CGFloat> = 150...520

    init(pane: FinderPane) {
        self.pane = pane
        key = "finderColumnWidth." + FinderWidth.place(of: pane)
        _columnWidth = AppStorage(wrappedValue: 230, key)
    }

    var body: some View {
        let column = FinderWidth.clamp(columnWidth, initial: 230, range: Self.columnWidths)
        GeometryReader { geo in
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pane.trail.enumerated()), id: \.element) { index, folder in
                        let last = index == pane.trail.count - 1
                        FinderColumn(folder: folder, pane: pane, current: last,
                                     chosen: last ? nil : pane.trail[index + 1])
                            .finderResizable(key, width: 230, range: Self.columnWidths)
                        Divider()
                    }
                    // (A source's files: its own preview beside the pane.)
                    if pane.source == nil, let chosen = pane.shown.first(where: { pane.selection.contains($0.url) && !$0.isFolder }) {
                        // As Finder: the file's preview in all the room the columns leave (at least a readable width).
                        FinderPreview(item: chosen, pane: pane)
                            .frame(width: max(440, geo.size.width - CGFloat(pane.trail.count) * (column + 1) - 2), height: geo.size.height)
                            .id("preview")
                    }
                    Color.clear.frame(width: 1).id("end")
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .onChange(of: pane.url) { withAnimation { scroller.scrollTo("end") } }
            .onAppear { scroller.scrollTo("end") }
        }
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
                        FinderSmallIcon(item: item)
                        if current, pane.naming == .rename(item.url) {
                            FinderNameField(item: item, pane: pane)
                        } else {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                        }
                        FinderTagDots(tags: item.tags)
                        Spacer(minLength: 4)
                        if item.isFolder { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 4))
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
            let hidden = FinderPane.showsHidden
            let read = if let source = pane.source { await source.list(url) }
                else { await Task.detached(priority: .userInitiated) { FinderItem.list(url, hidden: hidden, sort: .name, ascending: true) }.value }
            items = read.map { FinderItem(url: $0.0, info: $0.1) }
        }
    }
}

/// The column view's end: the chosen file's picture and what it is.
private struct FinderPreview: View {
    let item: FinderItem
    let pane: FinderPane
    @State private var thumbs = FinderThumbnails.shared

    var body: some View {
        if !item.isClip, !item.isPhoto, FilePreview.showsContents(item.url) {
            // A document, text, PDF…: what's in it, filling the column, its name and Open under it.
            VStack(spacing: 8) {
                FilePreview(url: item.url)
                    .background(Design.Studio.raised)
                    .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
                        Text([item.kind, item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                            .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    }
                    Spacer(minLength: 0)
                    Button("Open") { pane.open(item) }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            .padding(10)
        } else {
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
                .buttonStyle(StudioFlatButtonStyle())
            Spacer()
        }
        .padding(14)
        .modifier(FinderWantsPicture(item: item))
        }
    }
}

/// A photo's picture (or a clip's poster) asked for while it's shown, for the file shown now (a
/// list's row, or the column view's end, shows another file without appearing again), and no
/// longer made once it's gone.
struct FinderWantsPicture: ViewModifier {
    let item: FinderItem

    func body(content: Content) -> some View {
        // (Changed on disk: asked for again.)
        content.task(id: "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? -1)") {
            let thumbs = FinderThumbnails.shared, url = item.url
            if item.isClip { thumbs.want(url) } else if item.isPhoto { thumbs.wantPicture(url) } else { return }
            // (Until cancelled: scrolled away, or another file shown here.)
            try? await Task.sleep(for: .seconds(365 * 86_400))
            if item.isClip { thumbs.forget(url) } else { thumbs.forgetPicture(url) }
        }
    }
}

/// A row's icon in the list and columns: a photo's picture or a clip's, else the system's icon.
private struct FinderSmallIcon: View {
    let item: FinderItem
    @State private var thumbs = FinderThumbnails.shared

    var body: some View {
        Group {
            if let picture = item.isClip ? thumbs.posters[item.url] : thumbs.pictures[item.url] {
                Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: item.icon).resizable()
            }
        }
        .frame(width: 16, height: 16)
        .modifier(FinderWantsPicture(item: item))
    }
}

/// A toolbar button in Pluck Studio's grey: text-coloured (faint when it can't be used), lighter
/// under the pointer and while pressed; `raised` gives it its own box (else it's half of one).
private struct FinderToolButtonStyle: ButtonStyle {
    var raised = true

    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, raised: raised) }

    private struct Look: View {
        let configuration: Configuration
        let raised: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Design.Studio.body.weight(.medium))
                .foregroundStyle(enabled ? Design.Studio.text : Design.Studio.textFaint)
                .frame(width: 28, height: 28)
                .background {
                    let shape = RoundedRectangle(cornerRadius: raised ? Design.Studio.controlRadius : 0, style: .continuous)
                    ZStack {
                        if raised { shape.fill(Design.Studio.raised) }
                        shape.fill(Color.white.opacity(!enabled ? 0 : configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                    }
                }
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
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
                                Image(nsImage: pane.source == nil ? NSWorkspace.shared.icon(forFile: url.path) : NSWorkspace.shared.icon(for: .folder))
                                    .resizable().frame(width: 13, height: 13)
                                Text(name(url)).lineLimit(1)
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

    private func name(_ url: URL) -> String {
        if let source = pane.source, let rootName = source.rootName, url.standardizedFileURL == source.root.standardizedFileURL { return rootName }
        return FileManager.default.displayName(atPath: url.path)
    }

    private var status: String {
        let count = String(AttributedString(localized: "^[\(pane.shown.count) item](inflect: true)").characters)
        let picked = pane.selection.count > 1 ? String(localized: "\(pane.selection.count) selected") + ", " : ""
        guard pane.list == nil, pane.source == nil, let free = OffloadCenter.freeSpace(pane.url) else { return picked + count }
        return picked + count + ", " + String(localized: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available")
    }
}
