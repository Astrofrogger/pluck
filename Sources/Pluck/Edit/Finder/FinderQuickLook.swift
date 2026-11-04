import AppKit
import QuickLookUI

/// Space, as in Finder: macOS's Quick Look panel on what's selected (photos, clips, documents,
/// folders), following the selection; the arrows move it, Space or Esc close the panel.
@MainActor
final class FinderQuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FinderQuickLook()

    /// The pane it previews from.
    private weak var pane: FinderPane?
    /// What the panel goes through: several selected, or the one selected.
    private var urls: [URL] = []

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Space in a pane: the panel opens on its selection, or closes.
    func toggle(_ pane: FinderPane) {
        if isOpen { QLPreviewPanel.shared().orderOut(nil); return }
        guard !pane.selection.isEmpty else { return }
        self.pane = pane
        update()
        // (The panel asks the key window's chain who controls it: this, at its end.)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            var last: NSResponder = window
            while let next = last.nextResponder, next !== self { last = next }
            if last.nextResponder !== self { last.nextResponder = self }
        }
        let panel = QLPreviewPanel.shared()!
        panel.updateController()
        // (Not asked, as when Pluck isn't in front: shown from here all the same.)
        if panel.dataSource == nil { beginPreviewPanelControl(panel) }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The pane's selection changed (clicked, or moved with the arrows): the panel shows it.
    func follow(_ pane: FinderPane) {
        guard isOpen, self.pane === pane else { return }
        update()
        QLPreviewPanel.shared().reloadData()
        if let shown = shownIndex { QLPreviewPanel.shared().currentPreviewItemIndex = shown }
    }

    private func update() {
        guard let pane else { urls = []; return }
        urls = pane.shown.map(\.url).filter { pane.selection.contains($0) }
    }

    private var shownIndex: Int? {
        guard let anchor = pane?.anchor else { return urls.isEmpty ? nil : 0 }
        return urls.firstIndex(of: anchor) ?? (urls.isEmpty ? nil : 0)
    }

    // MARK: The panel

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        if let shown = shownIndex { panel.currentPreviewItemIndex = shown }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { () -> (any QLPreviewItem)? in urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    /// The arrows move the pane's selection (one selected: the panel follows it); Space closes.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, let pane else { return false }
            if event.keyCode == 49 { panel.orderOut(nil); return true }
            // (Several selected: the panel's own arrows go through them.)
            guard urls.count <= 1 else { return false }
            let step: Int
            switch event.keyCode {
            case 123: step = -1
            case 124: step = 1
            case 126: step = pane.mode == .icons ? -FinderPane.iconColumns(pane) : -1
            case 125: step = pane.mode == .icons ? FinderPane.iconColumns(pane) : 1
            default: return false
            }
            pane.move(by: step)
            follow(pane)
            return true
        }
    }
}
