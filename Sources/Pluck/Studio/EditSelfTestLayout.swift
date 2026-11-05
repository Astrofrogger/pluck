import AppKit

/// Checks for the Edit page's layout: where the media panel sits, how big the viewer gets, the
/// inspector's tabs, the project's own media and the libraries.
extension EditSelfTest {
    static func layout() async {
        viewerFit()
        inspectorTabs()
        await projectMedia()
        await libraries()
        check("keys: panel actions exist", ShortcutAction.allCases.contains(.editPanelPosition) && ShortcutAction.allCases.contains(.editLibraryNext))
    }

    /// The viewer stays 16:9 and as large as fits; a small window hides the library panel first.
    private static func viewerFit() {
        let page = CGSize(width: 1440, height: 860)
        let a = EditLayout.fit(page: page, position: .bottom, panelWidth: 300, inspectorWidth: 320, timelineHeight: 300,
                               panelShown: true, inspectorShown: true)
        check("layout: bottom keeps 16:9", near(a.viewer.width / a.viewer.height, 16.0 / 9, 0.01), "\(a.viewer)")
        check("layout: bottom viewer spans the top row less the inspector",
              near(a.viewer.width, min(1440 - 320, (860 - 300) * 16 / 9), 1), "\(a.viewer)")
        let b = EditLayout.fit(page: page, position: .fullHeight, panelWidth: 300, inspectorWidth: 320, timelineHeight: 300,
                               panelShown: true, inspectorShown: true)
        check("layout: full height narrows the viewer",
              b.viewer.width < a.viewer.width && near(b.viewer.width / b.viewer.height, 16.0 / 9, 0.01), "\(b.viewer)")
        let small = EditLayout.fit(page: CGSize(width: 1120, height: 680), position: .fullHeight, panelWidth: 420,
                                   inspectorWidth: 560, timelineHeight: 360, panelShown: true, inspectorShown: true)
        check("layout: small window hides the library panel first", !small.panelShown, "\(small)")
        check("layout: viewer keeps 40% of the height", small.viewer.height >= 680 * EditLayout.minimumViewerShare - 1, "\(small.viewer)")
        let tall = EditLayout.fit(page: CGSize(width: 1440, height: 700), position: .bottom, panelWidth: 300, inspectorWidth: 320,
                                  timelineHeight: 450, panelShown: true, inspectorShown: true)
        check("layout: inspector stays when hiding it wouldn't grow the picture", tall.inspectorShown, "\(tall)")
        check("layout: the timeline gives up height to keep 40%",
              near(tall.timeline, 420, 1) && tall.viewer.height >= 700 * EditLayout.minimumViewerShare - 1, "\(tall)")
        let pinned = EditLayout.fit(page: CGSize(width: 1120, height: 680), position: .fullHeight, panelWidth: 420, inspectorWidth: 560,
                                    timelineHeight: 360, panelShown: true, inspectorShown: true, keepInspector: true)
        check("layout: an inspector just asked for stays", pinned.inspectorShown && !pinned.panelShown, "\(pinned)")
        check("layout: positions cycle",
              EditPanelPosition.bottom.next == .top && EditPanelPosition.top.next == .fullHeight && EditPanelPosition.fullHeight.next == .bottom)
    }

    /// The inspector's six tabs, and what 3.8.0 saved mapped onto them.
    private static func inspectorTabs() {
        typealias Tab = ProjectInspector.Tab
        check("tabs: legacy values map", Tab.saved("transcript") == .text && Tab.saved("subtitles") == .text
              && Tab.saved("titles") == .text && Tab.saved("story") == .ai && Tab.saved("marks") == .clip
              && Tab.saved("nonsense") == .clip && Tab.saved("export") == .export)
        check("tabs: six in order", Tab.allCases.map(\.rawValue) == ["clip", "colour", "audio", "text", "ai", "export"],
              "\(Tab.allCases.map(\.rawValue))")
    }

    /// A project's own media: files brought in without touching the timeline, once each; songs on their own.
    private static func projectMedia() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: media), includingPropertiesForKeys: nil)) ?? []
        guard let video = files.first(where: { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }),
              let song = files.first(where: { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }) else {
            return check("media: test files present", false, "need a video and a song in \(media)")
        }
        let model = ProjectModel(project: Project(name: "Self Test"))
        let added = await model.importMedia([video, song, video, URL(fileURLWithPath: "/nonexistent.txt")])
        check("media: import adds once, not to the timeline", added == 2 && model.project.files.count == 2 && model.project.clips.isEmpty,
              "\(added) \(model.project.files)")
        check("media: music lists songs only", model.mediaFiles(audioOnly: true) == [song.path], "\(model.mediaFiles(audioOnly: true))")
        ProjectMediaList.choose(video.path)
        check("media: a click chooses the file for the assembly keys (E , . P R)", MediaSelection.shared.source == MediaSource(path: video.path, span: nil))
        MediaSelection.shared.source = nil
        model.undo()
        check("media: import is one undo step", model.project.files.isEmpty, "\(model.project.files)")
    }

    /// Library items applied where they're dropped: a transition on the nearest cut, a look for five seconds.
    private static func libraries() async {
        let m = await project(["a.mp4", "b.mp4"])
        guard m.project.clips.count == 2 else { return check("library: two clips", false, "got \(m.project.clips.count)") }
        let cut = m.offsets[1]
        var ok = await m.apply(.transition(.dissolve), at: cut + 0.4)
        check("library: transition lands on the nearest cut", ok && m.transition(into: 1)?.kind == .dissolve, "\(ok) \(String(describing: m.transition(into: 1)))")
        ok = await m.apply(.transition(.dipBlack), at: cut + 5)
        check("library: transition far from a cut does nothing", !ok && m.transition(into: 1)?.kind == .dissolve)
        let one = await project(["a.mp4"])
        let lone = await one.apply(.transition(.dissolve), at: 1)
        check("library: one clip, no transition", !lone)
        ok = await m.apply(.adjustment, at: 2)
        check("library: adjustment covers five seconds", ok && near((m.project.adjustments ?? []).last.map { $0.end - $0.start } ?? 0, 5),
              "\(m.project.adjustments ?? [])")
        if let template = MotionTemplate.all.first(where: { $0.category == .lowerThird }) {
            let before = (m.project.tracks ?? []).filter { $0.kind == .video }.flatMap(\.items).count
            ok = await m.apply(.title(templateID: template.id), at: 3)
            let items = (m.project.tracks ?? []).filter { $0.kind == .video }.flatMap(\.items)
            // Its video is rendered in the background (at the edit's size, known once it's built).
            let rendered = { items.last.flatMap { m.titleFile($0)?.path } ?? "" }
            for _ in 0..<120 where !FileManager.default.fileExists(atPath: rendered()) { try? await Task.sleep(for: .milliseconds(250)) }
            check("library: a title template lands on an overlay track at the drop point",
                  ok && items.count == before + 1 && near(items.last?.at ?? -1, 3) && FileManager.default.fileExists(atPath: rendered()),
                  "\(ok) \(m.libraryProblem ?? "") \(items.map(\.at))")
            if let item = items.last {
                m.removeItems([item.id])
                m.pruneTitleRenders()
                let file = m.titleFile(item)?.path ?? ""
                check("library: a title taken off the timeline leaves no file behind once tidied",
                      !file.isEmpty && !FileManager.default.fileExists(atPath: file), file)
                check("library: title renders are kept with Pluck's data, not in Caches", !file.contains("/Caches/"), file)
            }
        }
        check("library: payload round trip", EditLibraryItem(payload: EditLibraryItem.title(templateID: "slab").payload) == .title(templateID: "slab"))
    }
}
