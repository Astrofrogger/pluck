import Foundation

/// Bringing an edit back from DaVinci Resolve (Task 10), from timelines written by hand.
extension EditSelfTest {
    static func resolveRead() async {
        // Three clips of a.mp4 (25 fps), 4 s each; the second with a look and lower volume.
        let model = await project(["a.mp4", "a.mp4", "a.mp4"])
        let ids = model.project.clips.map(\.id)
        guard ids.count == 3 else { return check("resolve fixture", false, "3 clips; got \(ids.count)") }
        for (index, id) in ids.enumerated() { model.trim(id, start: Double(index) * 5, end: Double(index) * 5 + 4, record: true) }
        model.set(ids[1]) { clip in
            var look = ClipLook()
            look.zoom = 2
            clip.look = look
            clip.volume = 0.5
        }
        let a = model.project.clips[0].path
        let other = URL(fileURLWithPath: a).deletingLastPathComponent().appendingPathComponent("b.mp4").path
        let kept = ProjectMarker(time: 2, title: "Keep me", color: .yellow)
        model.setUp { $0.markers = [kept] }

        // As it was sent: back to back, 100 frames each.
        func sent(_ id: UUID, _ start: Int, _ source: Double) -> ResolveLink.Sent {
            ResolveLink.Sent(id: id, track: 1, lane: nil, path: a, start: start, end: start + 100, sourceStart: source, sourceEnd: source + 100, fps: 25)
        }
        let link = ResolveLink(project: "Self Test", timeline: "Self Test", rate: 25,
                               sent: [sent(ids[0], 0, 0), sent(ids[1], 100, 125), sent(ids[2], 200, 250)])
        let start = 86_400
        func item(_ path: String, _ from: Int, _ to: Int, _ source: Double, _ sourceEnd: Double, track: Int = 1) -> String {
            #"{"track":\#(track),"path":"\#(path)","start":\#(start + from),"end":\#(start + to),"sourceStart":\#(source),"sourceEnd":\#(sourceEnd),"fps":25}"#
        }
        func read(_ json: String) -> ResolveTimelineRead? { try? JSONDecoder().decode(ResolveTimelineRead.self, from: Data(json.utf8)) }

        // Nothing changed there: nothing changes here.
        let same = read("""
        {"start":\(start),"rate":25,"items":[\(item(a, 0, 100, 0, 100)),\(item(a, 100, 200, 125, 225)),\(item(a, 200, 300, 250, 350))],
         "markers":[{"frame":50,"color":"Yellow","name":"Keep me","duration":1,"customData":"pluck-marker:\(kept.id.uuidString)"}]}
        """)
        if let same {
            let (back, said) = ProjectResolveRead.merge(same, into: model.project, link: link)
            check("unchanged round trip changes nothing", back.clips == model.project.clips && said.trimmed == 0 && said.moved == 0
                  && said.added == 0 && said.removed == 0 && back.markers?.first?.id == kept.id,
                  "same clips, 0/0/0/0, marker id kept; got \(said)")
        } else {
            check("unchanged round trip changes nothing", false, "didn't decode")
        }

        // In Resolve: the third clip first, the second trimmed a second later at its start, b.mp4
        // added at the end, three markers (and one of Pluck's own, which stays out).
        guard let changed = read("""
        {"timeline":"Self Test","start":\(start),"rate":25,
         "items":[\(item(a, 0, 100, 250, 350)),\(item(a, 100, 200, 0, 100)),\(item(a, 200, 275, 150, 225)),\(item(other, 275, 325, 0, 50))],
         "sounds":[{"track":1,"start":\(start),"end":\(start + 100)},{"track":1,"start":\(start + 100),"end":\(start + 200)},
                   {"track":1,"start":\(start + 200),"end":\(start + 275)},{"track":1,"start":\(start + 275),"end":\(start + 325)}],
         "markers":[{"frame":25,"color":"Rose","name":"Fix this","note":"","duration":1,"customData":""},
                    {"frame":50,"color":"Mint","name":"Good take","note":"","duration":50,"customData":""},
                    {"frame":100,"color":"Blue","name":"","note":"","duration":1,"customData":""},
                    {"frame":0,"color":"Purple","name":"A title","note":"","duration":25,"customData":"pluck"}]}
        """) else { return check("resolve timeline decodes", false) }
        let before = model.project
        let summary = model.apply(changed, link: link)
        let clips = model.project.clips
        let markers = model.project.markers ?? []
        check("markers come back", markers.count == 3 && markers.map(\.title) == ["Fix this", "Good take", ""]
              && markers.map(\.color) == [.red, .green, .blue] && near(markers[1].length ?? 0, 2) && near(markers[0].time, 1),
              "3 markers, red/green/blue, the second 2 s; got \(markers.map { "\($0.title) \($0.color) \($0.time)" })")
        check("reorder comes back", clips.count == 4 && Array(clips.prefix(3).map(\.id)) == [ids[2], ids[0], ids[1]] && summary.moved == 1,
              "third, first, second, moved 1; got \(summary.moved)")
        let second = clips.first { $0.id == ids[1] }
        check("trim comes back", near(second?.start ?? 0, 6) && near(second?.end ?? 0, 9) && second?.look?.zoom == 2 && second?.volume == 0.5
              && summary.trimmed == 1, "6–9 s, look and volume kept; got \(second?.start ?? -1)–\(second?.end ?? -1), trimmed \(summary.trimmed)")
        check("unknown file added", summary.added == 1 && clips.last?.path == other && near(clips.last?.length ?? 0, 2) && summary.removed == 0,
              "b.mp4 added, 2 s; got added \(summary.added), removed \(summary.removed)")
        check("nothing skipped when only the edit changed", summary.skipped.isEmpty, "none; got \(summary.skipped)")
        model.undo()
        check("merge is one undo step", model.project.clips.map(\.id) == before.clips.map(\.id) && model.project.markers == before.markers)

        // A second update with nothing new there changes nothing (it measures from the first).
        model.setUp { $0.resolveTimeline = link }
        let firstUpdate = model.apply(changed, link: model.project.resolveTimeline ?? link)
        let afterFirst = model.project.clips
        let secondUpdate = model.apply(changed, link: model.project.resolveTimeline ?? link)
        check("second update changes nothing", firstUpdate.trimmed == 1 && secondUpdate.trimmed == 0 && secondUpdate.added == 0 && secondUpdate.moved == 0
              && secondUpdate.removed == 0 && model.project.clips == afterFirst,
              "first 1 trim, second none; got \(firstUpdate.trimmed), then \(secondUpdate)")
        model.undo()
        model.undo()

        // A clip's sound taken off follows a trim there; a clip added here since stays.
        model.detachAudio([ids[1]])
        await model.add([URL(fileURLWithPath: other)])
        let added = model.project.clips.last?.id
        let trimmedOnly = read("""
        {"start":\(start),"rate":25,"items":[\(item(a, 0, 100, 0, 100)),\(item(a, 100, 175, 150, 225)),\(item(a, 175, 275, 250, 350))],"markers":[]}
        """)
        if let trimmedOnly {
            let (back, _) = ProjectResolveRead.merge(trimmedOnly, into: model.project, link: link)
            let sound = (back.tracks ?? []).filter { $0.kind == .audio }.flatMap(\.items).first
            check("detached sound follows a trim", near(sound?.start ?? 0, 6) && near(sound?.end ?? 0, 9),
                  "6–9 s; got \(sound?.start ?? -1)–\(sound?.end ?? -1)")
            check("clips not sent stay", back.clips.last?.id == added && back.clips.count == 4, "the clip added since, last; got \(back.clips.count)")
        }

        // A speed change and a sound edit there are said, not silently lost.
        if let other = read("""
        {"start":0,"rate":25,"items":[{"track":1,"path":"\(a)","start":0,"end":100,"sourceStart":0,"sourceEnd":200,"fps":25}],
         "sounds":[{"track":2,"start":0,"end":40}],"markers":[]}
        """) {
            let (_, said) = ProjectResolveRead.merge(other, into: before, link: link)
            check("speed and sound edits are said", said.skipped.count == 2, "2 phrases; got \(said.skipped)")
        } else {
            check("speed and sound edits are said", false, "didn't decode")
        }
    }
}
