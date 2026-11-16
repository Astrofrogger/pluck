import Foundation

/// Keyframing a clip or a track item: its look changed at the playhead, keyframes moved, eased,
/// copied and pasted (all undoable).
extension ProjectModel {
    /// A clip on the main line or a track item, and where it starts on the timeline.
    func keyTarget(_ id: UUID) -> (clip: ProjectClip, start: Double)? {
        if let index = project.clips.firstIndex(where: { $0.id == id }) { return (project.clips[index], offsets[index]) }
        if let (t, i) = trackItem(id) { let item = project.tracks![t].items[i]; return (item, item.at ?? 0) }
        return nil
    }

    /// The one clip or item selected, for the keyframe lane and the curve editor.
    var keyedSelection: (clip: ProjectClip, start: Double)? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return keyTarget(id)
    }

    /// The playhead, in seconds into this clip (nil: not over it).
    func localTime(_ id: UUID) -> Double? {
        guard let (clip, start) = keyTarget(id) else { return nil }
        let t = time - start
        return t >= -0.0005 && t <= clip.length + 0.0005 ? min(max(t, 0), clip.length) : nil
    }

    /// Changes a clip's (or item's) look as shown at the playhead: keyframed settings get a keyframe there.
    func editLook(_ id: UUID, record: Bool, byHand: Bool = false, _ body: @escaping (inout ClipLook) -> Void) {
        let at = localTime(id)
        let apply: (inout ProjectClip) -> Void = { clip in
            var look = clip.look ?? ClipLook()
            look.edit(at: at, body)
            if byHand { look.reframed = nil }   // placed by hand now
            clip.look = look.isDefault ? nil : look
        }
        if project.clips.contains(where: { $0.id == id }) { set(id, record: record, apply) } else { setItem(id, record: record, apply) }
    }

    /// Changes the keyframes of one clip or item.
    func changeKeys(_ id: UUID, record: Bool = true, _ body: @escaping (inout ClipLook) -> Void) {
        let at = localTime(id) ?? 0
        let apply: (inout ProjectClip) -> Void = { clip in
            let level = clip.gain(at: at)
            var look = clip.look ?? ClipLook()
            let hadVolume = look.isKeyed(.volume)
            body(&look)
            // The last volume keyframe gone: the level it had at the playhead stays.
            if hadVolume, !look.isKeyed(.volume) { clip.volume = level }
            clip.look = look.isDefault ? nil : look
        }
        if project.clips.contains(where: { $0.id == id }) { set(id, record: record, apply) } else { setItem(id, record: record, apply) }
    }

    /// The volume (dB) diamond and slider: a keyframe at the playhead once it's keyframed.
    func setVolume(_ id: UUID, _ gain: Double, record: Bool) {
        let at = localTime(id)
        let apply: (inout ProjectClip) -> Void = { clip in
            guard let at, clip.look?.isKeyed(.volume) == true else { clip.volume = gain; return }
            var look = clip.look ?? ClipLook()
            look.setKey(.volume, 20 * log10(max(gain, 0.0001)), at: at)
            clip.look = look
        }
        if project.clips.contains(where: { $0.id == id }) { set(id, record: record, apply) } else { setItem(id, record: record, apply) }
    }

    func toggleVolumeKey(_ id: UUID) {
        guard let at = localTime(id), let (clip, _) = keyTarget(id) else { return }
        let db = 20 * log10(max(clip.gain(at: at), 0.0001))
        let apply: (inout ProjectClip) -> Void = { clip in
            var look = clip.look ?? ClipLook()
            var frames = look.keyframes(.volume)
            if let i = frames.firstIndex(where: { abs($0.time - at) <= 0.02 }) { frames.remove(at: i) } else { frames.append(Keyframe(time: at, value: db)) }
            look.setKeyframes(.volume, frames)
            // The last volume keyframe gone: the level it had stays.
            if frames.isEmpty { clip.volume = pow(10, db / 20) }
            clip.look = look.isDefault ? nil : look
        }
        if project.clips.contains(where: { $0.id == id }) { set(id, apply) } else { setItem(id, apply) }
    }

    /// The playhead to the clip's keyframe before or after it (of one setting, or any).
    func jumpToKey(_ id: UUID, _ property: KeyProperty?, forward: Bool) {
        guard let (clip, start) = keyTarget(id), let look = clip.look else { return }
        let here = time - start
        let times = (property.map { [$0] } ?? look.keyedProperties).flatMap { look.keyframes($0).map(\.time) }
        let next = forward ? times.filter { $0 > here + 0.01 }.min() : times.filter { $0 < here - 0.01 }.max()
        if let next { seek(to: start + next) }
    }

    /// Takes out the keyframes chosen on the lane; true when there were some.
    func deleteSelectedKeys() -> Bool {
        guard let (clip, _) = keyedSelection, let look = clip.look, !selectedKeys.isEmpty else { return false }
        let ids = selectedKeys
        guard look.keyedProperties.contains(where: { look.keyframes($0).contains { ids.contains($0.id) } }) else { return false }
        changeKeys(clip.id) { look in
            for property in look.keyedProperties {
                let kept = look.keyframes(property).filter { !ids.contains($0.id) }
                // The last one gone: the setting keeps the value it had there.
                if kept.isEmpty, let path = property.path, let last = look.keyframes(property).first { look[keyPath: path] = last.value }
                look.setKeyframes(property, kept)
            }
        }
        selectedKeys = []
        return true
    }

    /// Keyframes moved in time (dragged on the lane); `record` false while the drag goes on.
    func moveKeys(_ ids: Set<UUID>, of clipID: UUID, by delta: Double, from start: ClipLook, record: Bool) {
        guard let (clip, _) = keyTarget(clipID) else { return }
        let length = clip.length
        // One shift for the whole group, so the spacing between the keys stays.
        let times = start.keyedProperties.flatMap { start.keyframes($0).filter { ids.contains($0.id) }.map(\.time) }
        let delta = times.isEmpty ? delta : max(min(delta, max(0, length - times.max()!)), -times.min()!)
        let body: (inout ClipLook) -> Void = { look in
            look.keys = start.keys
            for property in look.keyedProperties {
                look.setKeyframes(property, look.keyframes(property).map { key in
                    guard ids.contains(key.id) else { return key }
                    var moved = key
                    moved.time = key.time + delta
                    return moved
                })
            }
        }
        changeKeys(clipID, record: record, body)
    }

    /// The ease of these keyframes (into the next one of each).
    func setEase(_ ease: KeyEase, keys ids: Set<UUID>, of clipID: UUID, record: Bool = true) {
        changeKeys(clipID, record: record) { look in
            for property in look.keyedProperties {
                look.setKeyframes(property, look.keyframes(property).map { key in
                    guard ids.contains(key.id) else { return key }
                    var eased = key
                    eased.ease = ease
                    return eased
                })
            }
        }
    }

    /// Copies a clip's keyframes (the chosen ones, or all of them), for pasting onto others.
    @discardableResult
    func copyKeys(_ id: UUID) -> Bool {
        guard let (clip, _) = keyTarget(id), let keys = clip.look?.keys, !keys.isEmpty else { return false }
        let chosen = selectedKeys
        var copied = keys
        if !chosen.isEmpty, keys.values.contains(where: { $0.contains { chosen.contains($0.id) } }) {
            copied = keys.mapValues { $0.filter { chosen.contains($0.id) } }.filter { !$0.value.isEmpty }
        }
        KeyClipboard.keys = (copied, clip.length)
        return true
    }

    /// Pastes the copied keyframes onto these clips and items: at the same times, or stretched to
    /// each one's length (a zoom over the whole clip stays over the whole clip). One undo step.
    func pasteKeys(into ids: Set<UUID>, stretch: Bool) {
        guard let board = KeyClipboard.keys else { return }
        change { project in
            for index in project.clips.indices where ids.contains(project.clips[index].id) {
                project.clips[index].pasteKeys(board.frames, from: board.length, stretch: stretch)
            }
            for t in (project.tracks ?? []).indices {
                for i in project.tracks![t].items.indices where ids.contains(project.tracks![t].items[i].id) {
                    project.tracks![t].items[i].pasteKeys(board.frames, from: board.length, stretch: stretch)
                }
            }
        }
    }
}
