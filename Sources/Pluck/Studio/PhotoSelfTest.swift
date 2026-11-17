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
        // (Tests: only the film's speed and route, to measure quickly.)
        if let only = defaults.string(forKey: "PluckScreenshotOnly"), ["film", "advanced", "tone", "real", "prophoto", "colour", "profiles", "furdump", "furtests", "lrgap", "lrtests", "grade", "gradetests", "filmnr", "reference", "revamp3", "revamp4a", "revamp4b", "thumbnails", "profiledump", "heal", "perspective", "tags", "depth", "negative", "facemasks", "lens", "remove", "sliders", "clickmask", "describe", "matchbrush", "retouch", "liquify", "merge", "cull", "upscale", "lensprofiles", "tether", "timing", "history", "eyes", "edges", "softproof", "smartalbums", "map", "people", "adaptive", "finder", "finderfiles", "finderbig", "finderextras", "safety", "previewstamp", "remoteedit", "remoteshares", "remotepull", "remotereview", "remotedrive", "remoteresolve", "resolveuses", "remoteiroh", "remotelink", "officegroup", "musicfit", "deliverycheck", "brandcheck", "assets", "brandpack", "archive", "syncCameras", "thumbnails2", "cutdowns", "review", "reviewpeople", "truenase2e"].contains(only) {
            if only == "film" { await filmInstant() } else if only == "tone" { tone() } else if only == "real" { await realFile() } else if only == "furdump" { await furDump() } else if only == "furtests" { await furShadows() } else if only == "lrgap" { await lrGapDump() } else if only == "lrtests" { await lrGapFixes() } else if only == "grade" { await gradeDump() } else if only == "gradetests" { await gradeChecks() } else if only == "filmnr" { await filmNR() } else if only == "reference" { await oldEditsUnchanged() } else if only == "revamp3" { await revamp3() } else if only == "revamp4a" { await revamp4a() } else if only == "revamp4b" { await revamp4b() } else if only == "thumbnails" { await thumbnailsAtOnce() } else if only == "profiledump" { await profileDump() } else if only == "heal" { await heal() } else if only == "perspective" { await perspective() } else if only == "tags" { await tags() } else if only == "depth" { await depth() } else if only == "negative" { await negative() } else if only == "facemasks" { await faceMasks() } else if only == "lens" { await lens() } else if only == "remove" { await removeTest() } else if only == "sliders" { await sliders() } else if only == "clickmask" { await clickMask() } else if only == "describe" { await describe() } else if only == "matchbrush" { await matchBrush() } else if only == "retouch" { await retouch() } else if only == "liquify" { await liquifyTest() } else if only == "merge" { await mergeTest() } else if only == "cull" { await cullTest() } else if only == "upscale" { await upscaleTest() } else if only == "lensprofiles" { await lensProfiles() } else if only == "tether" { await tetherTest() } else if only == "timing" { await timing() } else if only == "history" { await historyTest() } else if only == "eyes" { await eyesTest() } else if only == "edges" { await edgesTest() } else if only == "softproof" { await softProof() } else if only == "smartalbums" { await smartAlbums() } else if only == "map" { await map() } else if only == "people" { await people() } else if only == "adaptive" { await adaptiveTest() } else if only == "finder" { await finderTest() } else if only == "finderfiles" { await finderFilesTest() } else if only == "finderbig" { await finderBigTest() } else if only == "finderextras" { await finderExtrasTest() } else if only == "safety" { await safetyTest() } else if only == "previewstamp" { previewStamp() } else if only == "remoteedit" { await remoteEditTest() } else if only == "remoteshares" { await remoteSharesTest() } else if only == "remotepull" { await remotePullTest() } else if only == "remotereview" { await remoteReviewTest() } else if only == "remotedrive" { await remoteDriveTest() } else if only == "remoteresolve" { await remoteResolveTest() } else if only == "resolveuses" { await resolveUsesDump() } else if only == "remoteiroh" { await remoteIrohTest() } else if only == "remotelink" { await remoteLinkTest() } else if only == "officegroup" { await officeGroupTest() } else if only == "musicfit" { await musicFitTest() } else if only == "deliverycheck" { await deliveryCheckTest() } else if only == "brandcheck" { await brandCheckTest() } else if only == "assets" { await assetsTest() } else if only == "brandpack" { await brandPackTest() } else if only == "archive" { await archiveTest() } else if only == "syncCameras" { await syncCamerasTest() } else if only == "thumbnails2" { await thumbnails2Test() } else if only == "cutdowns" { await cutdownsTest() } else if only == "review" { await reviewTest() } else if only == "reviewpeople" { await reviewPeopleTest() } else if only == "truenase2e" { await trueNASE2ETest() }
            else if only == "colour" { colourNoise() } else if only == "profiles" { await profiles() }
            else if only == "prophoto" { await proPhoto() } else { await filmAdvanced() }
            lines.append("done")
            write()
            NSApp.terminate(nil)
            return
        }
        await catalogRoundtrip()
        paste()
        sync()
        speedEdit()
        await lightroom()
        await metadata()
        await copies()
        await exportPresets()
        await beforeAfter()
        await filmRefresh()
        await panelColumn()
        hdr()
        signals()
        moments()
        ranking()
        catalogReader()
        await styles()
        usualLook()
        await levelExposure()
        await film()
        tone()
        calibration()
        couplerEdges()
        lightroomExtras()
        lightroomProfiles()
        await denoise()
        colourNoise()
        await proPhoto()
        await profiles()
        await oldEditsUnchanged()
        await process4()
        await furShadows()
        await lrGapFixes()
        await gradeChecks()
        await filmNR()
        await revamp1()
        await revamp2()
        await revamp3()
        await revamp4a()
        await revamp4b()
        await thumbnailsAtOnce()
        await softProof()
        await smartAlbums()
        await map()
        await people()
        lines.append("done")
        write()
        NSApp.terminate(nil)
    }

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        lines.append(ok ? "PASS \(name)" : "FAIL \(name): \(detail())")
        write()
    }

    /// A measurement worth keeping beside the checks (not counted).
    static func note(_ text: String) {
        lines.append("NOTE \(text)")
        write()
    }

    /// A check that can't run here (neither passed nor failed), and why.
    static func skip(_ name: String, _ why: String) {
        lines.append("SKIP \(name): \(why)")
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
