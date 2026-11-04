import AppKit
import SwiftUI

/// Dragging files out as Finder does: the whole selection, each file an item of its own, so
/// Finder, the Desktop, the Dock, Mail or an editing app gets every one. (AppKit's own drag:
/// SwiftUI's multi-item drag needs macOS 26 and can't keep a drop on Finder from moving.)
@MainActor
final class FinderDrag: NSObject, NSDraggingSource {
    static let shared = FinderDrag()
    private var dragging = false

    /// What's dragged from this item: the selection when it's in it (as Finder), else only it.
    static func urls(_ url: URL, in pane: FinderPane, selected: Bool = true) -> [URL] {
        selected && pane.selection.contains(url) ? pane.selection.sorted { $0.path < $1.path } : [url]
    }

    /// One item per file (a folder, an RDC take: the folder itself), as a file URL.
    static func items(_ urls: [URL]) -> [NSDraggingItem] {
        urls.map { NSDraggingItem(pasteboardWriter: $0 as NSURL) }
    }

    /// Outside Pluck only a copy: a plain drag onto Finder never moves a card's files. Inside,
    /// the panes' own drop decides (⌘ moves); generic so ⌘ held still drops there.
    static func operations(_ context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .generic]
    }

    func start(_ urls: [URL]) {
        guard !dragging, !urls.isEmpty, let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let items = Self.items(urls)
        for (n, item) in items.enumerated() {
            let shift = CGFloat(min(n, 4)) * 4
            item.setDraggingFrame(NSRect(x: point.x - 32 + shift, y: point.y - 32 + shift, width: 64, height: 64),
                                  contents: NSWorkspace.shared.icon(forFile: urls[n].path))
        }
        dragging = true
        // (AppKit badges the count when there are several.)
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operations(context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
    }
}

extension View {
    /// Dragged out: these files (worked out when the drag starts).
    func fileDrag(_ urls: @escaping () -> [URL]) -> some View {
        gesture(DragGesture(minimumDistance: 4).onChanged { _ in FinderDrag.shared.start(urls()) })
    }
}
