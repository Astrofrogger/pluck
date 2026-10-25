import Foundation

/// Keeping what's linked to a main-line clip with it (its sound taken off, pictures placed on top)
/// when the clip is cut in two, copied, or shows another part of its file.
extension Project {
    /// Cuts main-line clip `index` in two, `into` seconds (timeline) after its start. What's
    /// linked to it after the cut rides with the second half; its sound, taken off, is cut too.
    mutating func splitClip(_ index: Int, into: Double) {
        var first = clips[index], second = clips[index]
        first.end = first.start + into * first.speed
        first.fadeOut = 0
        first.dipOut = nil
        second.id = UUID()
        second.start = first.end
        second.fadeIn = 0
        second.transitionIn = nil
        second.link = nil
        if let link = first.link, tracks != nil {
            let next = UUID()
            var moved = false
            for t in tracks!.indices {
                var items: [ProjectClip] = []
                for var item in tracks![t].items {
                    let offset = item.linkOffset ?? 0
                    guard item.link == link else { items.append(item); continue }
                    if offset >= into - 0.0005 {
                        item.link = next
                        item.linkOffset = offset - into > 0.0005 ? offset - into : nil
                        moved = true
                        items.append(item)
                    } else if tracks![t].kind == .audio, offset + item.length > into + 0.0005 {
                        // The clip's sound across the cut: cut there as well.
                        var head = item, tail = item
                        head.end = item.start + (into - offset) * item.speed
                        head.fadeOut = 0
                        tail.id = UUID()
                        tail.start = head.end
                        tail.fadeIn = 0
                        tail.at = (item.at ?? 0) + (into - offset)
                        tail.link = next
                        tail.linkOffset = nil
                        moved = true
                        items += [head, tail]
                    } else {
                        items.append(item)
                    }
                }
                tracks![t].items = items
            }
            if moved { second.link = next }
        }
        clips[index] = first
        clips.insert(second, at: index + 1)
    }

    /// A copy of a main-line clip, with copies of what's linked to it (linked to the copy).
    mutating func copyWithLinks(_ clip: ProjectClip) -> ProjectClip {
        var copy = clip
        copy.id = UUID()
        guard let link = clip.link, tracks != nil else { return copy }
        let next = UUID()
        copy.link = next
        for t in tracks!.indices {
            for item in tracks![t].items where item.link == link {
                var twin = item
                twin.id = UUID()
                twin.link = next
                tracks![t].items.append(twin)
            }
        }
        return copy
    }

    /// Puts this version of a main-line clip in place of the one with its id. When it shows
    /// another part of its file, its sound on a track (if untouched since it was taken off)
    /// shows the same part, so the two stay in sync.
    mutating func setClip(_ clip: ProjectClip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let old = clips[index]
        clips[index] = clip
        guard let link = old.link, tracks != nil, old.start != clip.start || old.end != clip.end else { return }
        for t in tracks!.indices where tracks![t].kind == .audio {
            for i in tracks![t].items.indices {
                let item = tracks![t].items[i]
                guard item.link == link, item.linkOffset == nil, abs(item.start - old.start) < 0.0005, abs(item.end - old.end) < 0.0005 else { continue }
                tracks![t].items[i].start = clip.start
                tracks![t].items[i].end = clip.end
            }
        }
    }
}
