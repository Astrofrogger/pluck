import AppKit

/// Tests for the Photo page (screenshot mode "phototest"), with its own catalogue
/// (-PluckScreenshotCatalog <file>): each check is a line in -PluckScreenshotLog <file>,
/// "PASS name" or "FAIL name: detail", then "done". Photos come from -PluckScreenshotPhotos <folder>.
@MainActor
enum PhotoSelfTest {
    private static var lines: [String] = []
    private static var log = ""
    static var photos = ""

    static func run(defaults: UserDefaults) async {
        guard let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        log = logPath
        photos = defaults.string(forKey: "PluckScreenshotPhotos") ?? ""
        lines = []
        await catalogRoundtrip()
        paste()
        sync()
        speedEdit()
        await lightroom()
        await metadata()
        await copies()
        await exportPresets()
        await beforeAfter()
        hdr()
        lines.append("done")
        write()
        NSApp.terminate(nil)
    }

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        lines.append(ok ? "PASS \(name)" : "FAIL \(name): \(detail())")
        write()
    }

    private static func write() { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }

    // MARK: - Checks

    /// An edit is saved to the catalogue's file and reads back the same.
    private static func catalogRoundtrip() async {
        let path = "/tmp/pluck-selftest/photo.jpg"
        PhotoCatalog.shared.update([path]) { $0.adjust.exposure = 1.25; $0.rating = 4 }
        PhotoCatalog.shared.saveNow()
        let saved = PhotoCatalog.readFile()?[path]
        check("catalog roundtrip", saved?.adjust.exposure == 1.25 && saved?.rating == 4,
              "exposure 1.25, rating 4; got \(String(describing: saved?.adjust.exposure)), \(String(describing: saved?.rating))")
    }

    /// Edit all selected: with sync on a change reaches every selected photo, off only the one shown.
    private static func sync() {
        let paths = (1...3).map { "/tmp/pluck-selftest/sync-\($0).jpg" }
        let catalog = PhotoCatalog.shared, editing = PhotoEditing.shared
        let before = editing.syncAll
        defer { editing.syncAll = before }
        editing.syncAll = false
        editing.edit(paths, shown: paths[1]) { $0.adjust.exposure = 0.75 }
        let off = paths.map { catalog.record($0).adjust.exposure }
        check("sync off edits one", off[0] == 0 && off[1] == 0.75 && off[2] == 0, "0, 0.75, 0; got \(off)")
        editing.syncAll = true
        editing.edit(paths, shown: paths[1]) { $0.adjust.exposure = -0.5 }
        let on = paths.map { catalog.record($0).adjust.exposure }
        check("sync on edits all", on.allSatisfy { $0 == -0.5 }, "-0.5 x3; got \(on)")
    }

    /// Speed Edit: the step per scroll point, the limits, ⌥ finer, one undo step per gesture, and sync.
    private static func speedEdit() {
        guard let exposure = SpeedEdit.targets[.photoSpeedExposure] else { check("speed edit step", false, "no target"); return }
        let step = SpeedEdit.value(0, scrollDelta: 10, precise: false, target: exposure)
        check("speed edit step", abs(step - 0.25) < 0.0001, "0.25; got \(step)")
        let top = SpeedEdit.value(4.9, scrollDelta: 1000, precise: false, target: exposure)
        let bottom = SpeedEdit.value(-4.9, scrollDelta: -1000, precise: false, target: exposure)
        check("speed edit clamps", top <= 5 && bottom >= -5, "within -5…5; got \(bottom), \(top)")
        let fine = SpeedEdit.value(0, scrollDelta: 10, precise: true, target: exposure)
        check("speed edit precise", abs(fine - 0.05) < 0.0001, "0.05; got \(fine)")

        let catalog = PhotoCatalog.shared, editing = PhotoEditing.shared
        let before = editing.syncAll
        defer { editing.syncAll = before }
        let one = "/tmp/pluck-selftest/speed-1.jpg"
        catalog.endStep()
        catalog.update([one]) { $0.adjust.exposure = 0.5 }
        catalog.endStep()
        editing.syncAll = true
        for _ in 0..<5 { SpeedEdit.scroll(.photoSpeedExposure, delta: 4, precise: false, paths: [one], shown: one) }
        let moved = catalog.record(one).adjust.exposure
        catalog.undo()
        let back = catalog.record(one).adjust.exposure
        check("speed gesture one undo", abs(moved - 1.0) < 0.0001 && abs(back - 0.5) < 0.0001, "1.0 then 0.5; got \(moved), \(back)")

        let paths = (2...3).map { "/tmp/pluck-selftest/speed-\($0).jpg" }
        editing.syncAll = false
        catalog.endStep()
        SpeedEdit.scroll(.photoSpeedContrast, delta: 10, precise: false, paths: paths, shown: paths[0])
        let off = paths.map { catalog.record($0).adjust.contrast }
        editing.syncAll = true
        catalog.endStep()
        SpeedEdit.scroll(.photoSpeedContrast, delta: 10, precise: false, paths: paths, shown: paths[0])
        let on = paths.map { catalog.record($0).adjust.contrast }
        check("speed edit honours sync", off[0] == 5 && off[1] == 0 && on.allSatisfy { $0 == 10 }, "off 5,0 / on 10,10; got \(off) / \(on)")
    }

    /// Paste: the chosen groups leave crop and masks out, Previous pastes the last photo's, one undo step.
    private static func paste() {
        let a = "/tmp/pluck-selftest/paste-a.jpg", b = "/tmp/pluck-selftest/paste-b.jpg", c = "/tmp/pluck-selftest/paste-c.jpg"
        let catalog = PhotoCatalog.shared
        catalog.update([a]) {
            $0.adjust.exposure = 1; $0.adjust.crop = .square; $0.adjust.masks = [PhotoMask(kind: .subject)]
        }
        PhotoPasteboard.copy(a)
        PhotoPasteboard.paste(PasteGroup.chosen, to: [b])
        let rb = catalog.record(b)
        check("paste default leaves crop and masks", rb.adjust.exposure == 1 && rb.adjust.crop == .original && rb.adjust.masks.isEmpty,
              "exposure 1, original, no masks; got \(rb.adjust.exposure), \(rb.adjust.crop), \(rb.adjust.masks.count)")

        PhotoPasteboard.lastViewed = nil
        PhotoPasteboard.focusMoved(from: nil, to: a)
        PhotoPasteboard.focusMoved(from: a, to: c)
        PhotoPasteboard.pastePrevious(to: [c])
        check("paste previous", catalog.record(c).adjust.exposure == 1, "exposure 1; got \(catalog.record(c).adjust.exposure)")

        catalog.update([b]) { $0.adjust.exposure = 0.5 }
        PhotoPasteboard.paste(PasteGroup.chosen, to: [b])
        catalog.undo()
        check("paste is one undo step", catalog.record(b).adjust.exposure == 0.5, "exposure 0.5; got \(catalog.record(b).adjust.exposure)")
    }
}
