import CoreImage
import Foundation

/// The transitions library: every transition draws, starts on A and ends on B, has a Resolve
/// transition to go to, keeps its settings through saving and undo. (The viewer against the export
/// for every one of them: `transitions` in EditSelfTestEditBugs.)
extension EditSelfTest {
    typealias Transition = ProjectTransition

    static func transitionLibrary() async {
        check("transitions: kernels build", ProjectTransitions.brokenKernels.isEmpty, "\(ProjectTransitions.brokenKernels)")
        let counts = Transition.Group.allCases.map { "\($0.label) \($0.kinds.count)" }.joined(separator: ", ")
        check("transitions: 60 or more in the library", Transition.Kind.allCases.count >= 60, "\(Transition.Kind.allCases.count): \(counts)")
        drawing()
        resolveNames()
        await resolveRoundTrip()
        await savedAndUndone()
    }

    /// Back from Resolve: a transition changed there comes back as Pluck's; one Pluck sent as its nearest stays Pluck's.
    private static func resolveRoundTrip() async {
        let model = await project(["a.mp4", "a.mp4", "a.mp4"])
        let ids = model.project.clips.map(\.id)
        guard ids.count == 3 else { return check("transitions: resolve fixture", false) }
        for (index, id) in ids.enumerated() { model.trim(id, start: Double(index) * 5 + 1, end: Double(index) * 5 + 5, record: true) }
        model.setTransition(into: 1, Transition(kind: .glitch, length: 1, intensity: 0.8))
        model.setTransition(into: 2, Transition(kind: .cube, length: 1, direction: .up))
        let a = model.project.clips[0].path, start = 86_400
        func sent(_ id: UUID, _ at: Int, _ source: Double) -> ResolveLink.Sent {
            ResolveLink.Sent(id: id, track: 1, lane: nil, path: a, start: at, end: at + 100, sourceStart: source, sourceEnd: source + 100, fps: 25)
        }
        let link = ResolveLink(project: "Self Test", timeline: "Self Test", rate: 25, sent: [sent(ids[0], 0, 25), sent(ids[1], 100, 150), sent(ids[2], 200, 275)])
        func item(_ from: Int, _ source: Double) -> String {
            #"{"track":1,"path":"\#(a)","start":\#(start + from),"end":\#(start + from + 100),"sourceStart":\#(source),"sourceEnd":\#(source + 100),"fps":25}"#
        }
        let json = #"{"start":\#(start),"rate":25,"markers":[],"items":[\#(item(0, 25)),\#(item(100, 150)),\#(item(200, 275))],"transitions":[{"track":1,"start":\#(start + 88),"end":\#(start + 113),"type":"Heart"},{"track":1,"start":\#(start + 190),"end":\#(start + 210),"type":"Push"}]}"#
        guard let read = try? JSONDecoder().decode(ResolveTimelineRead.self, from: Data(json.utf8)) else { return check("transitions: resolve read decodes", false) }
        let (back, summary) = ProjectResolveRead.merge(read, into: model.project, link: link)
        let first = back.clips[1].transitionIn, second = back.clips[2].transitionIn
        check("transitions: changed in Resolve comes back", first?.kind == .heart && near(first?.length ?? 0, 1), "\(String(describing: first))")
        check("transitions: Pluck's own stays, its new length comes back", second?.kind == .cube && second?.way == .up && near(second?.length ?? 0, 0.8)
              && summary.transitions == 2, "\(String(describing: second)), \(summary.transitions)")
    }

    // MARK: - Drawing

    private static let size = CGSize(width: 96, height: 54)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Two pictures with something to move: a coloured ramp, and rings on another colour.
    private static func pictures() -> (CIImage, CIImage) {
        let frame = CGRect(origin: .zero, size: size)
        let a = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: size.height),
                                                              "inputColor0": CIColor(red: 0.95, green: 0.45, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.6, blue: 0.7)])!
            .outputImage!.cropped(to: frame)
        let b = CIFilter(name: "CICircularScreen", parameters: [kCIInputImageKey: CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.8)).cropped(to: frame),
                                                               kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2), kCIInputWidthKey: 9])!
            .outputImage!.cropped(to: frame)
        return (a, b)
    }

    /// RGBA, 0–255.
    private static func pixels(_ image: CIImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        context.render(image, toBitmap: &data, rowBytes: Int(size.width) * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                       colorSpace: ProjectCompositor.video)
        return data
    }

    private static func difference(_ x: [UInt8], _ y: [UInt8]) -> Double {
        guard x.count == y.count, !x.isEmpty else { return 255 }
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }

    private static func drawing() {
        let (a, b) = pictures()
        let pa = pixels(a), pb = pixels(b)
        var ends: [String] = [], blank: [String] = [], still: [String] = []
        for kind in Transition.Kind.allCases where kind.overlaps {
            for way in kind.settings.contains(.direction) ? Transition.Direction.allCases : [kind.defaultDirection] {
                let t = Transition(kind: kind, length: 1, direction: way)
                let name = "\(kind.rawValue)\(kind.settings.contains(.direction) ? "-" + way.rawValue : "")"
                let start = difference(pixels(ProjectTransitions.blend(t, from: a, to: b, progress: 0, size: size)), pa)
                let end = difference(pixels(ProjectTransitions.blend(t, from: a, to: b, progress: 1, size: size)), pb)
                if start > 2 || end > 2 { ends.append("\(name) \(Int(start))/\(Int(end))") }
                var moving = false
                for p in [0.25, 0.5, 0.75] {
                    let frame = pixels(ProjectTransitions.blend(t, from: a, to: b, progress: p, size: size))
                    // Drawn (opaque, not all black).
                    let clear = stride(from: 3, to: frame.count, by: 4).filter { frame[$0] < 250 }
                    if !clear.isEmpty || !frame.contains(where: { $0 > 8 }) {
                        blank.append("\(name)@\(p) \(clear.count) \(clear.first.map { ($0 / 4 % Int(size.width), $0 / 4 / Int(size.width), frame[$0]) }.map { "\($0)" } ?? "")")
                    }
                    if min(difference(frame, pa), difference(frame, pb)) > 1 { moving = true }
                }
                if !moving { still.append(name) }
            }
        }
        check("transitions: every one draws at 25, 50 and 75 %", blank.isEmpty, "\(blank)")
        check("transitions: every one starts on A and ends on B", ends.isEmpty, "\(ends)")
        check("transitions: every one changes the picture on the way", still.isEmpty, "\(still)")
        // A direction is a direction.
        let left = pixels(ProjectTransitions.blend(Transition(kind: .wipe, length: 1, direction: .left), from: a, to: b, progress: 0.3, size: size))
        let right = pixels(ProjectTransitions.blend(Transition(kind: .wipe, length: 1, direction: .right), from: a, to: b, progress: 0.3, size: size))
        check("transitions: direction changes the wipe", difference(left, right) > 5)
        let soft = pixels(ProjectTransitions.blend(Transition(kind: .wipe, length: 1, softness: 0.6), from: a, to: b, progress: 0.5, size: size))
        let hard = pixels(ProjectTransitions.blend(Transition(kind: .wipe, length: 1), from: a, to: b, progress: 0.5, size: size))
        check("transitions: softness changes the edge", difference(soft, hard) > 1)
        let eased = pixels(ProjectTransitions.blend(Transition(kind: .dissolve, length: 1, easing: .easeIn), from: a, to: b, progress: 0.5, size: size))
        let plain = pixels(ProjectTransitions.blend(Transition(kind: .dissolve, length: 1), from: a, to: b, progress: 0.5, size: size))
        check("transitions: easing changes the timing", difference(eased, plain) > 3)
        // Only the ones ffmpeg draws the same go to ffmpeg.
        check("transitions: ffmpeg's own only for exact ones",
              Transition.Kind.allCases.filter { ProjectTransitions.native(Transition(kind: $0, length: 1)) != nil } == [.dissolve, .wipe, .push]
              && ProjectTransitions.native(Transition(kind: .wipe, length: 1, softness: 0.2)) == nil
              && ProjectTransitions.native(Transition(kind: .push, length: 1, easing: .easeOut)) == nil)
    }

    // MARK: - Resolve

    /// Resolve 21's own transitions (Video Transitions: Dissolve, Iris, Motion, Shape, Wipe; the Fusion ones Pluck uses).
    static let resolveTransitions: Set<String> = [
        "Cross Dissolve", "Additive Dissolve", "Blur Dissolve", "Dip To Color Dissolve", "Non-Additive Dissolve", "Smooth Cut",
        "Arrow Iris", "Cross Iris", "Diamond Iris", "Eye Iris", "Hexagon Iris", "Oval Iris", "Pentagon Iris", "Square Iris", "Triangle Iris",
        "Barn Door", "Push", "Slide", "Split", "Box", "Heart", "Star", "Triangle Left", "Triangle Right",
        "Band Wipe", "Center Wipe", "Clock Wipe", "Edge Wipe", "Radial Wipe", "Spiral Wipe", "Venetian Blind Wipe", "X Wipe",
        "Brightness Flash", "Camera Shake", "Crash Zoom", "Glitch", "Film Strip", "Tunnel of Light", "Zoom In and Out",
    ]

    private static func resolveNames() {
        let unknown = Transition.Kind.allCases.filter { !resolveTransitions.contains($0.resolve.name) }
        check("transitions: each goes to a Resolve transition", unknown.isEmpty, "\(unknown)")
        let back = Transition.Kind.allCases.filter { $0.resolve.exact }.filter { kind in
            Transition.Kind.from(resolve: kind.resolve.name).map { $0.resolve.name != kind.resolve.name } ?? true
        }
        check("transitions: the exact ones come back from Resolve", back.isEmpty, "\(back)")
        check("transitions: Resolve's own names come back", Transition.Kind.from(resolve: "Cross Dissolve") == .dissolve
              && Transition.Kind.from(resolve: "venetian blind wipe") == .venetianBlind && Transition.Kind.from(resolve: "Smooth Cut") == nil)
    }

    // MARK: - Saving and undo

    private static func savedAndUndone() async {
        let model = await project(["a.mp4", "a.mp4"])
        guard model.project.clips.count == 2 else { return check("transitions: clips", false) }
        model.trim(model.project.clips[0].id, start: 1, end: 4, record: true)
        model.trim(model.project.clips[1].id, start: 3, end: 6, record: true)
        let glitch = Transition(kind: .glitch, length: 0.8, intensity: 0.9, easing: .easeOut, sound: .cut)
        let cube = Transition(kind: .cube, length: 1.2, direction: .up)
        let dip = Transition(kind: .dipColour, length: 1, colour: TransitionColour(red: 0.2, green: 0.4, blue: 0.9), softness: 0.3)
        model.setTransition(into: 1, glitch)
        model.setTransition(into: 1, cube)
        check("transitions: changed", model.transition(into: 1) == cube)
        model.undo()
        check("transitions: undo brings the last one back with its settings", model.transition(into: 1) == glitch, "\(String(describing: model.transition(into: 1)))")
        model.redo()
        check("transitions: redo", model.transition(into: 1) == cube)
        model.undo(); model.undo()
        check("transitions: undo to none", model.transition(into: 1) == nil)
        model.redo()
        model.setTransition(into: 1, dip)

        let saved = try? JSONEncoder().encode(model.project)
        let read = saved.flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
        check("transitions: saving keeps every setting", read?.clips[1].transitionIn == dip, "\(String(describing: read?.clips[1].transitionIn))")
        let all = Transition(kind: .whip, length: 0.7, direction: .down, colour: .white, softness: 0.1, intensity: 0.3, easing: .easeInOut, sound: .crossfade)
        let again = (try? JSONEncoder().encode(all)).flatMap { try? JSONDecoder().decode(Transition.self, from: $0) }
        check("transitions: every setting is written", again == all)
        // Projects saved before the settings: "pushUp" is a push upwards.
        let old = try? JSONDecoder().decode([Transition].self, from: Data(#"[{"kind":"pushUp","length":0.8},{"kind":"wipeRight","length":1},{"kind":"whipLeft","length":0.5},{"kind":"irisOpen","length":1}]"#.utf8))
        check("transitions: old projects open", old == [Transition(kind: .push, length: 0.8, direction: .up), Transition(kind: .wipe, length: 1, direction: .right),
                                                      Transition(kind: .whip, length: 0.5, direction: .left), Transition(kind: .irisOpen, length: 1)],
              "\(String(describing: old))")
    }
}
