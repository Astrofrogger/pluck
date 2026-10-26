import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Photo signals, moments and their ranking (Edit Like Me, part 1), on made-up pictures.
extension PhotoSelfTest {
    static func signals() {
        // The same picture a stop brighter (twice the light) measures the same.
        let busy = shapes()
        let normal = PhotoSignals.measure(busy, exif: nil), bright = PhotoSignals.measure(brighter(busy), exif: nil)
        func close(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a - b) <= 0.02 * max(abs(a), abs(b))
        }
        let apart = PhotoSignals.distance(normal.print, bright.print)
        check("signals ignore brightness", close(normal.sharpness, bright.sharpness) && close(normal.faceQuality, bright.faceQuality)
              && close(normal.aesthetics, bright.aesthetics) && apart < 0.05,
              "within 2 %, print < 0.05; got sharpness \(String(describing: normal.sharpness)) / \(String(describing: bright.sharpness)), "
              + "aesthetics \(String(describing: normal.aesthetics)) / \(String(describing: bright.aesthetics)), print \(apart)")

        // Motion streaks one way; a soft focus is even.
        let motion = PhotoSignals.measure(checkerboard("CIMotionBlur", 12), exif: nil).blurDirection
        let soft = PhotoSignals.measure(checkerboard("CIGaussianBlur", 4), exif: nil).blurDirection
        check("blur shape", motion > 0.5 && soft < 0.3, "motion > 0.5, gaussian < 0.3; got \(motion), \(soft)")

        // A frame moved by 4 px is close; a different picture is far.
        let size = CGSize(width: busy.width, height: busy.height)
        let moved = render(CIImage(cgImage: busy).transformed(by: CGAffineTransform(translationX: 4, y: 4)).clampedToExtent(), size)
        let near = PhotoSignals.distance(normal.print, PhotoSignals.measure(moved, exif: nil).print)
        let far = PhotoSignals.distance(normal.print, PhotoSignals.measure(stripes(), exif: nil).print)
        check("print similarity", normal.print.count == 768 && near < 0.2 && far > 0.4,
              "768 numbers, shifted < 0.2, different > 0.4; got \(normal.print.count), \(near), \(far)")

        // A photo's check carries its signals, with the EXIF, and they save and load the same.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-signals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shapes.jpg")
        if let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            let exif: [CFString: Any] = [kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifISOSpeedRatings: [800], kCGImagePropertyExifFocalLength: 50,
                                         kCGImagePropertyExifDateTimeOriginal: "2024:05:01 12:30:00", kCGImagePropertyExifSubsecTimeOriginal: "66"]
            CGImageDestinationAddImage(destination, busy, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        let found = PhotoChecks.look(at: file.path)
        let signals = found?.signals
        let reread = found.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(PhotoCheck.self, from: $0) }
        // Bursts are ~10 a second: the time keeps the camera's hundredths (as Lightroom's does).
        let fraction = found?.taken.map { $0.timeIntervalSinceReferenceDate - $0.timeIntervalSinceReferenceDate.rounded(.down) } ?? 0
        check("check carries signals", signals?.print.count == 768 && signals?.sharpness != nil && signals?.shutter == 0.004
              && signals?.iso == 800 && signals?.focal == 50 && reread == found && abs(fraction - 0.66) < 0.005,
              "a print, sharpness, 1/250 s, ISO 800, 50 mm, taken at .66 s, the same after saving; got \(String(describing: signals?.print.count)), "
              + "\(String(describing: signals?.shutter)), \(String(describing: signals?.iso)), \(String(describing: signals?.focal)), \(fraction) s, same \(reread == found)")
    }

    // MARK: - Moments and what shows on top (made-up checks, no pictures)

    /// A made-up check: when it was taken, where its print sits, and what it measured.
    private static func made(_ taken: Double?, print: [Float] = [], sharpness: Double = 0.02, faceQuality: Double? = nil, eyesOpen: Double? = nil, aesthetics: Double? = nil) -> PhotoCheck {
        var signals = PhotoSignals()
        signals.print = print
        signals.sharpness = sharpness
        signals.faceCount = faceQuality == nil ? 0 : 1
        signals.faceQuality = faceQuality
        signals.eyesOpen = eyesOpen
        signals.aesthetics = aesthetics
        return PhotoCheck(sharpness: sharpness, faces: [], eyesClosed: false, taken: taken.map { Date(timeIntervalSinceReferenceDate: 1_000_000 + $0) }, signals: signals)
    }

    /// A print with these numbers first and zeros after (so two prints are as far apart as their numbers say).
    private static func spot(_ values: Float...) -> [Float] { values + [Float](repeating: 0, count: 768 - values.count) }

    static func moments() {
        // Six photos in capture order.
        let checks: [String: PhotoCheck] = [
            "A": made(0, print: spot(0)), "B": made(0.4, print: spot(0.2)),
            "C": made(30.4, print: spot(0, 0.6)), "D": made(31.4, print: spot(0, 0.6, 0.55)),
            "E": made(nil, print: spot(0)), "F": made(32.4),
        ]
        let photos = ["A", "B", "C", "D", "E", "F"]
        let grouped = PhotoMoments.group(photos, checks: checks)
        check("moments follow time and look", grouped == [["A", "B"], ["C", "D", "F"], ["E"]],
              "A+B together, C starts a new one, D joins C (within 2 s), F joins by time, undated E alone; got \(grouped)")
        check("moments keep every photo", grouped.flatMap { $0 }.sorted() == photos.sorted(),
              "each photo exactly once; got \(grouped.flatMap { $0 })")

        // A day's order doesn't matter, and nothing carries a date or a print.
        let shuffled = PhotoMoments.group(["B", "A", "D", "C"], checks: checks)
        let bare = PhotoMoments.group(["x", "y", "z"], checks: [:])
        let noPrint = PhotoMoments.group(["p", "q", "r"], checks: ["p": made(0), "q": made(1), "r": made(10)])
        check("moments without date or print", shuffled == [["A", "B"], ["C", "D"]] && bare == [["x"], ["y"], ["z"]] && noPrint == [["p", "q"], ["r"]]
              && PhotoMoments.group([], checks: [:]).isEmpty,
              "time order wins; no checks gives one each; no print joins within 1.5 s; got \(shuffled), \(bare), \(noPrint)")

        // The same look 30 s later joins, a different one does not.
        let late = PhotoMoments.group(["a", "b", "c"], checks: ["a": made(0, print: spot(0)), "b": made(30, print: spot(0.4)), "c": made(60, print: spot(0.4, 0.55))])
        check("moments need a close look when apart", late == [["a", "b"], ["c"]], "0.4 apart joins, 0.55 apart (over 2 s) does not; got \(late)")
    }

    static func ranking() {
        check("top quarter of a moment", [1, 2, 3, 8, 20, 300].map { PhotoMoments.onTop(count: $0) } == [1, 1, 1, 2, 5, 75],
              "1, 1, 1, 2, 5, 75; got \([1, 2, 3, 8, 20, 300].map { PhotoMoments.onTop(count: $0) })")

        // Four moments of 1, 3, 8 and 300 frames, sharper the higher the number.
        var checks: [String: PhotoCheck] = [:]
        var moments: [[String]] = []
        for (m, size) in [1, 3, 8, 300].enumerated() {
            let paths = (0..<size).map { "m\(m)-\($0)" }
            for (i, path) in paths.enumerated() { checks[path] = made(Double(m * 1000 + i), sharpness: 0.01 + Double((i * 7) % size) * 0.001) }
            moments.append(paths)
        }
        let input = Set(moments.flatMap { $0 })
        let collapsed = PhotoMoments.visible(moments, ranker: .builtIn, checks: checks, expanded: [])
        let stacked = collapsed.reduce(0) { $0 + $1.stacked }
        let expanded = PhotoMoments.visible(moments, ranker: .builtIn, checks: checks, expanded: Set(moments.compactMap(\.first)))
        let ordered = moments.allSatisfy { moment in
            let scores = PhotoRanker.builtIn.scores(moment, checks: checks)
            let byPath = Dictionary(uniqueKeysWithValues: zip(moment, scores))
            let listed = expanded.map(\.path).filter { byPath[$0] != nil }.map { byPath[$0]! }
            return zip(listed, listed.dropFirst()).allSatisfy { $0 >= $1 }
        }
        let tops = PhotoMoments.split(moments[3], scores: PhotoRanker.builtIn.scores(moments[3], checks: checks))
        check("stacks lose nothing", collapsed.count == 1 + 1 + 2 + 75 && collapsed.count + stacked == 312 && Set(collapsed.map(\.path)).isSubset(of: input)
              && Set(tops.top + tops.rest) == Set(moments[3]) && expanded.count == 312 && Set(expanded.map(\.path)) == input && expanded.allSatisfy { $0.stacked == 0 } && ordered,
              "top photos plus stacked = 312, expanded lists all 312, best first; got \(collapsed.count) + \(stacked), expanded \(expanded.count), ordered \(ordered)")

        // 3,000 photos: 30 scenes of 100 frames. Prints are made first, so only the grouping and ranking are timed.
        var big: [String: PhotoCheck] = [:]
        var all: [String] = []
        for scene in 0..<30 {
            for frame in 0..<100 {
                let path = "s\(scene)-\(frame)"
                var look = [Float](repeating: 0, count: 768)
                look[scene] = 1
                look[100 + frame % 10] = 0.01 * Float(frame % 7)
                big[path] = made(Double(scene * 600 + frame) * 0.4, print: look, sharpness: 0.01 + Double(frame % 13) * 0.001, faceQuality: frame % 3 == 0 ? Double(frame % 10) / 10 : nil, aesthetics: 0.1)
                all.append(path)
            }
        }
        let start = Date()
        let groups = PhotoMoments.group(all, checks: big)
        let shown = PhotoMoments.visible(groups, ranker: .builtIn, checks: big, expanded: [])
        let took = Date().timeIntervalSince(start)
        let hidden = shown.reduce(0) { $0 + $1.stacked }
        check("300 frames stay quick", took < 0.5 && groups.count == 30 && shown.count == 30 * 25 && shown.count + hidden == 3000,
              "3,000 photos grouped and ranked in under 0.5 s; got \(took) s, \(groups.count) moments, \(shown.count) on top, \(hidden) stacked")

        // The page's list: three moments (8, 4 and 1 photos, 5 min apart) and two photos with no check yet.
        var page: [String: PhotoCheck] = [:]
        var source: [String] = []
        for (m, size) in [8, 4, 1].enumerated() {
            for i in 0..<size {
                let path = "v\(m)-\(i)"
                page[path] = made(Double(m * 300 + i), print: spot(Float(m)), sharpness: 0.01 + Double((i * 5) % size) * 0.001)
                source.append(path)
            }
        }
        source += ["new-1", "new-2"]
        let closed = PhotoMoments.listing(source, ranker: .builtIn, checks: page, expanded: [])
        let opened = PhotoMoments.listing(source, ranker: .builtIn, checks: page, expanded: ["v0-0"])
        let moment0 = Set((0..<8).map { "v0-\($0)" })
        let unique = closed.paths.count == Set(closed.paths).count && opened.paths.count == Set(opened.paths).count
        let opens = opened.paths.filter { moment0.contains($0) }
        check("moments view keeps every photo", closed.paths.count == 2 + 1 + 1 + 2 && closed.stacked.values.reduce(0, +) == 6 + 3
              && Set(closed.paths).isSubset(of: Set(source)) && closed.paths.contains("new-1") && closed.paths.contains("new-2")
              && opened.paths.count == 8 + 1 + 1 + 2 && Set(opens) == moment0 && opened.opened.count == 1 && opened.stacked.values.reduce(0, +) == 3
              && opened.moment["v0-5"] == "v0-0" && closed.moment["new-1"] == nil && unique,
              "collapsed: 2 + 1 + 1 tops and the 2 new photos, 9 stacked; open the first: its 8 plus 1, 1, 2, none twice; got \(closed.paths.count) collapsed, \(opened.paths.count) open, unique \(unique)")

        // The page's cache gives the same list, and an opened moment stays open when a new photo becomes its first.
        let cache = MomentsCache()
        let cached = cache.listing(source, checks: page, style: nil, expanded: [])
        let cachedOpen = cache.listing(source, checks: page, style: nil, expanded: ["v0-0"])
        var earlier = page
        earlier["v0-early"] = made(-0.5, print: spot(0))
        let regrouped = cache.listing(["v0-early"] + source, checks: earlier, style: nil, expanded: ["v0-0"])
        check("moments cache matches", cached.paths == closed.paths && cached.stacked == closed.stacked && cachedOpen.paths == opened.paths
              && regrouped.moment["v0-0"] == "v0-early" && regrouped.opened.count == 1 && Set(regrouped.paths).isSuperset(of: moment0),
              "the same lists as without the cache; the open moment stays open with its new first photo; got \(cached.paths == closed.paths), "
              + "\(cachedOpen.paths == opened.paths), opened \(regrouped.opened.count)")

        // Same picture, eyes closed against open.
        let pair = ["closed": made(0, faceQuality: 0.6, eyesOpen: 0.05), "open": made(0, faceQuality: 0.6, eyesOpen: 0.3)]
        let scores = PhotoRanker.builtIn.scores(["closed", "open"], checks: pair)
        let split = PhotoMoments.split(["closed", "open"], scores: scores)
        check("built-in prefers open eyes", scores[1] > scores[0] && split.top == ["open"] && split.rest == ["closed"], "open ranks first; got \(scores)")

        let features = PhotoRanker.relativeFeatures(["a", "b"], checks: ["a": made(0, sharpness: 0.03), "b": made(1, sharpness: 0.01)])
        check("moment features", features[0]["rank_sharp"] == 0 && features[1]["rank_sharp"] == 1 && features[0]["momSize"] == 2 && abs((features[1]["diff_sharp"] ?? 0) - 0.02) < 1e-9
              && features[0]["rank_faceQ"] == -1 && features[0]["distBest"] == 0,
              "sharpest has rank 0, size 2, missing measures -1; got \(features)")
    }

    // MARK: - Made-up pictures

    private static func draw(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        body(context)
        return context.makeImage()!
    }

    private static func render(_ image: CIImage, _ size: CGSize) -> CGImage {
        CIContext().createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    /// Sixty shapes in made-up colours on a dim ground, always the same, none past mid-grey (so a stop brighter doesn't clip).
    private static func shapes() -> CGImage {
        draw(640, 480) { c in
            c.setFillColor(CGColor(gray: 0.15, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            var seed: UInt64 = 7
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            for _ in 0..<60 {
                c.setFillColor(CGColor(red: 0.1 + 0.5 * random(), green: 0.1 + 0.5 * random(), blue: 0.1 + 0.5 * random(), alpha: 1))
                let rect = CGRect(x: random() * 600, y: random() * 440, width: 10 + random() * 80, height: 10 + random() * 80)
                if random() > 0.5 { c.fillEllipse(in: rect) } else { c.fill(rect) }
            }
        }
    }

    /// Something else entirely: stripes and a triangle on a light ground.
    private static func stripes() -> CGImage {
        draw(640, 480) { c in
            c.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.8, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            c.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1))
            for x in stride(from: 0, to: 640, by: 40) { c.fill(CGRect(x: x, y: 0, width: 14, height: 480)) }
            c.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
            c.move(to: CGPoint(x: 100, y: 80))
            c.addLine(to: CGPoint(x: 540, y: 120))
            c.addLine(to: CGPoint(x: 320, y: 420))
            c.fillPath()
        }
    }

    /// The picture with twice the light (a stop brighter).
    private static func brighter(_ image: CGImage) -> CGImage {
        render(CIImage(cgImage: image).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1]), CGSize(width: image.width, height: image.height))
    }

    /// A black and white checkerboard (32 px squares) through a blur.
    private static func checkerboard(_ blur: String, _ radius: Double) -> CGImage {
        let board = CIImage.empty().applyingFilter("CICheckerboardGenerator", parameters: ["inputWidth": 32, "inputColor0": CIColor.black, "inputColor1": CIColor.white])
        return render(board.applyingFilter(blur, parameters: [kCIInputRadiusKey: radius]), CGSize(width: 512, height: 512))
    }
}

/// Level Exposure (Edit Like Me, part 1): three made-up grey photos at linear 0.1, 0.2 and 0.4.
extension PhotoSelfTest {
    static func levelExposure() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-level-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = PhotoCatalog.shared
        var paths: [String] = []
        for (index, linear) in [0.1, 0.2, 0.4].enumerated() {
            // sRGB value of that linear grey.
            let value = 1.055 * pow(linear, 1 / 2.4) - 0.055
            let image = draw(200, 150) { c in
                c.setFillColor(CGColor(gray: CGFloat(value), alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            }
            let url = folder.appendingPathComponent("grey-\(index).jpg")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
            paths.append(url.path)
        }
        defer { catalog.update(paths) { $0 = PhotoRecord() } }
        catalog.endStep()
        let reference = paths[1]
        let before = paths.map { catalog.record($0).adjust.exposure }
        await PhotoLevel.level(paths, reference: reference, whiteBalance: false)
        let after = paths.map { catalog.record($0).adjust.exposure }
        var medians: [Double] = []
        for path in paths { if let reading = await PhotoLevel.measure(path) { medians.append(reading.luma) } }
        let spread = (medians.max() ?? 1) / max(medians.min() ?? 1, 0.0001) - 1
        check("level exposure evens a set", medians.count == 3 && spread < 0.05,
              "measured medians within 5 %; got \(medians), spread \(spread), exposures \(after)")
        check("level exposure leaves the reference", after[1] == before[1], "reference unchanged at \(before[1]); got \(after[1])")
        catalog.undo()
        let back = paths.map { catalog.record($0).adjust.exposure }
        check("level exposure is one undo", back == before && after != before, "one undo restores \(before); got \(back) (after \(after))")
        let none = await PhotoLevel.offsets(paths, reference: reference, whiteBalance: true)
        check("level exposure offsets", abs((none[paths[0]]?.exposure ?? 9) - 1) < 0.15 && abs((none[paths[2]]?.exposure ?? 9) + 1) < 0.15
              && none[paths[1]]?.exposure == 0 && abs(none[paths[0]]?.temperature ?? 99) <= 30,
              "+1, 0, -1 stop for grey 0.1, 0.2, 0.4; got \(none)")
    }
}
