import AppKit
import CoreImage
import Foundation
import ImageIO
import simd
import SwiftUI
import UniformTypeIdentifiers

/// Process 5's Colour Warper (in Curves): untouched renders as none, one dot moves only the colours up to its neighbours and
/// keeps grey, a strongly bent grid stays smooth on ramps (no NaN, no steps), dragging is as quick as a slider; and Point
/// Colour's new Range.
extension PhotoSelfTest {
    private static func r4bCL(_ c: SIMD3<Double>) -> Double { let o = fsLab(c); return fsChroma(o) / max(o.x, 1e-6) }
    /// A finished picture (as shot) through the engine, before the screen's gamut map.
    private static func r4bPicture(_ image: CIImage, _ a: PhotoAdjustments) -> [SIMD3<Double>] {
        var a = a; a.profile = .asShot
        return fsPixels(PhotoRender.adjusted(image, a, isRaw: false, kelvin: 5500), image.extent)
    }
    /// A hue ring, 360 × 4 (x = OkLCh hue in degrees).
    private static func r4bRing(_ L: Double, _ C: Double) -> CIImage {
        fsImage(360, 4) { x, _ in
            let h = Double(x) * .pi / 180, (r, g, b) = OkLab.to(L, C * cos(h), C * sin(h))
            return SIMD3(Float(r), Float(g), Float(b))
        }
    }
    /// Hue across (480), colourfulness down (120): the sheet's and the smoothness check's ramp.
    private static let r4bWide = fsImage(480, 120) { x, y in
        let h = Double(x) / 480 * 2 * .pi, C = 0.16 * (1 - Double(y) / 140), L = 0.72 - 0.25 * Double(y) / 120
        let (r, g, b) = OkLab.to(L, C * cos(h), C * sin(h))
        return SIMD3(Float(r), Float(g), Float(b))
    }
    /// A warp with these dots (hue column, ring) moved.
    private static func r4bWarp(_ moves: [(Int, Int, Double, Double)]) -> ColourWarp {
        var w = ColourWarp()
        for (i, j, turn, scale) in moves { w.turn[ColourWarp.index(i, j)] = turn; w.scale[ColourWarp.index(i, j)] = scale }
        return w
    }
    /// A strong bend: skin warmer and paler, greens to teal, blue deeper, magenta out.
    private static let r4bBent = r4bWarp([(0, 0, 25, 1.4), (0, 1, 30, 0.6), (3, 1, -20, 1.6), (4, 2, 35, 0.5), (8, 1, -25, 1.8),
                                          (8, 2, 40, 1.3), (10, 0, 15, 0.2), (10, 3, -30, 1.2), (6, 0, 0, 2.5)])

    static func revamp4b() async {
        warperOff()
        warperOneDot()
        warperSmooth()
        pointRangeDefault()
        await warperSpeed()
        await revamp4bDump()
    }

    // MARK: Off is off

    /// An untouched grid renders exactly as none and isn't sent; saved and read back; an old file (or a grid of another size)
    /// reads as none.
    private static func warperOff() {
        let ring = r4bRing(0.6, 0.07), ramp = fsImage(64, 4) { x, _ in SIMD3(repeating: Float(0.18 * exp2(Double(x) / 6 - 7))) }
        let plain = PhotoAdjustments()
        var flat = PhotoAdjustments(); flat.curves.warp = ColourWarp()
        var differ = 0
        for image in [ring, ramp, r4bWide] {
            for raw in [true, false] {
                let a = fsPixels(PhotoRender.adjusted(image, plain, isRaw: raw, kelvin: 5500), image.extent)
                let b = fsPixels(PhotoRender.adjusted(image, flat, isRaw: raw, kelvin: 5500), image.extent)
                differ += zip(a, b).filter { $0.0 != $0.1 }.count
            }
        }
        var bent = PhotoAdjustments(); bent.curves.warp = r4bBent
        let back = (try? JSONEncoder().encode(bent)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        let odd = try? JSONDecoder().decode(ColourWarp.self, from: Data(#"{"turn":[1,2,3],"scale":[1,1,1]}"#.utf8))
        let old = try? JSONDecoder().decode(PhotoCurves.self, from: Data(#"{"master":[{"x":0,"y":0},{"x":1,"y":1}],"red":[{"x":0,"y":0},{"x":1,"y":1}],"green":[{"x":0,"y":0},{"x":1,"y":1}],"blue":[{"x":0,"y":0},{"x":1,"y":1}]}"#.utf8))
        check("warper untouched renders as none", differ == 0 && PhotoEngine.colourTools(flat) == nil && flat.curves.isDefault
              && !bent.curves.isDefault && AdjustSection.curves.isEdited(bent) && back == bent && odd?.isDefault == true && old?.warp == nil,
              "pixels differ \(differ), round trip \(back == bent), other size \(String(describing: odd?.isDefault)), old \(String(describing: old?.warp))")
    }

    // MARK: One dot

    /// Red's inner dot turned +20° and red's second-ring dot ×1.5: on a ring of C/L about its first ring, red turns about
    /// 20° and the turn fades to nothing by the next dots (±30°); grey stays grey; the grid's spline doesn't overshoot.
    private static func warperOneDot() {
        let ring = r4bRing(0.6, 0.072)
        var a = PhotoAdjustments()
        // (The base through the colour tools too, by a dot far out that reaches nothing here, so the OkLab round trip's float
        // error, about 0.1° of hue at this colourfulness, isn't counted as the warp's.)
        a.curves.warp = r4bWarp([(6, 3, 0, 1.0001)])
        let base = r4bPicture(ring, a)
        let shownCL = r4bCL(base[2 * 360 + 29])
        a.curves.warp = r4bWarp([(6, 3, 0, 1.0001), (0, 0, 20, 1)])
        let moved = r4bPicture(ring, a)
        let t: [Double] = (0..<360).map { x in
            var d = fsHue(fsLab(moved[2 * 360 + x])) - fsHue(fsLab(base[2 * 360 + x]))
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            return d
        }
        // (By the hue as shown: the profile moves it a little from the ring's own.)
        func apart(_ x: Int) -> Double { let d = abs(fsHue(fsLab(base[2 * 360 + x])) - 29.2).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        // (Past the next dots by one table step, 5°: the table is read straight between its steps.)
        let outside = (0..<360).filter { apart($0) > 35 }.map { abs(t[$0]) }.max()!
        let step = (1..<360).map { abs(t[$0] - t[$0 - 1]) }.max()!
        let under = t.min()!
        // Grey: a ramp from black to white keeps its (lack of) colour (up to the OkLab round trip's float error).
        let greys = fsImage(64, 4) { x, _ in SIMD3(repeating: Float(0.9 * Double(x) / 63)) }
        let g0 = r4bPicture(greys, PhotoAdjustments()), g1 = r4bPicture(greys, a)
        let grey = zip(g0, g1).map { simd_length(fsLab($0.0) - fsLab($0.1)) * 100 }.max()!
        // The table itself: a dot on ring 2 ×1.5 changes ring 2 at its hue, nothing two rings out or a column and more away.
        let table = r4bWarp([(0, 1, 0, 1.5)]).table(hueSteps: 72, satSteps: 16, top: PhotoEngine.satAxis)
        func entry(_ hue: Double, _ cl: Double) -> Double { table[Int((hue / 5).rounded()) % 72 * 16 + Int((cl / PhotoEngine.satAxis * 15).rounded())].scale }
        let atDot = entry(30, 0.24), ringOut = entry(30, 0.48), across = entry(65, 0.24), centre = entry(30, 0), most = table.map(\.scale).max()!
        let row = String(format: "shown C/L %.3f; red %+.1f°, 15° away %+.1f°, past the next dots (+5°) ≤ %.3f°, most opposite %+.2f°, largest step %.2f°/°; grey ΔE ≤ %.4f; table ×1.5 dot: at it %.3f, two rings out %.3f, a column and more away %.3f, grey %.3f, most %.3f",
                         shownCL, t[29], t[44], outside, under, step, grey, atDot, ringOut, across, centre, most)
        note("warper one dot: " + row)
        check("warper one dot moves only its neighbourhood", t[29] > 15 && t[29] < 21 && t[44] > 3 && outside < 0.05 && under > -0.1 && step < 1.5
              && grey < 0.05 && abs(atDot - 1.5) < 0.01 && abs(ringOut - 1) < 1e-9 && abs(across - 1) < 1e-9 && abs(centre - 1) < 1e-9 && most <= 1.5 + 1e-9, row)
    }

    // MARK: Smooth

    /// The strong bend on the hue × colourfulness ramp: every number finite, and no step between neighbouring pixels much
    /// bigger than the ramp's own (no tear, no band).
    private static func warperSmooth() {
        var a = PhotoAdjustments()
        let base = r4bPicture(r4bWide, a)
        a.curves.warp = r4bBent
        let bent = r4bPicture(r4bWide, a)
        let finite = bent.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        func steps(_ px: [SIMD3<Double>]) -> (across: Double, down: Double) {
            var across = 0.0, down = 0.0
            for y in 0..<120 {
                for x in 0..<480 {
                    let here = fsLab(px[y * 480 + x])
                    if x > 0 { across = max(across, simd_length(here - fsLab(px[y * 480 + x - 1]))) }
                    if y > 0 { down = max(down, simd_length(here - fsLab(px[(y - 1) * 480 + x]))) }
                }
            }
            return (across * 100, down * 100)
        }
        let s0 = steps(base), s1 = steps(bent)
        let changed = zip(base, bent).map { simd_length(fsLab($0.0) - fsLab($0.1)) * 100 }.max()!
        let row = String(format: "finite %@; largest step across %.2f (plain %.2f), down %.2f (plain %.2f), OkLab ×100; largest change %.1f", finite ? "yes" : "no", s1.across, s0.across, s1.down, s0.down, changed)
        note("warper strong bend on the ramp: " + row)
        check("warper smooth on ramps", finite && changed > 5 && s1.across < 3 * s0.across + 0.3 && s1.down < 3 * s0.down + 0.3, row)
    }

    /// Point Colour: a new pick reaches Range 30 (50 took walls and hair with skin).
    private static func pointRangeDefault() {
        let p = ColourPoint.picked(SIMD3(0.6, 0.4, 0.3))
        check("point colour starts at range 30", p.range == 30, "range \(p.range)")
    }

    // MARK: Speed

    /// Dragging a warper dot (DSC01994, 2048 px; each step a new grid) against a plain slider without it: as quick.
    private static func warperSpeed() async {
        let arw = p4Raws.appendingPathComponent("DSC01994.ARW").path
        guard FileManager.default.fileExists(atPath: arw) else { skip("warper drag speed", "no DSC01994"); return }
        func ms(_ start: Date) -> Double { (Date().timeIntervalSince(start) * 1000).rounded() }
        var drag: [Bool: [Double]] = [:]
        for on in [false, true, false, true] {
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            var record = PhotoRecord()
            if on { record.adjust.curves.warp = r4bBent }
            if let image = PhotoRender.image(arw, record: record, maxSize: 2048) { _ = PhotoRender.picture(image) }
            var times: [Double] = []
            for k in 0..<12 {
                var moved = record
                if on { moved.adjust.curves.warp?.turn[ColourWarp.index(2, 1)] = Double(k) * 3 } else { moved.adjust.exposure = Double(k) / 10 }
                let start = Date()
                if let image = PhotoRender.image(arw, record: moved, maxSize: 2048) { _ = PhotoRender.picture(image) }
                times.append(ms(start))
            }
            drag[on, default: []].append(times.sorted()[times.count / 2])
        }
        let off = drag[false]!.min()!, with = drag[true]!.min()!
        let start = Date()
        for k in 0..<20 { var w = r4bBent; w.turn[k] = 10; _ = w.table(hueSteps: 72, satSteps: 16, top: PhotoEngine.satAxis) }
        let table = Date().timeIntervalSince(start) * 1000 / 20
        note(String(format: "warper drag (DSC01994, 2048 px, median of 12, ms): exposure slider \(drag[false]!), warper dot \(drag[true]!); its table %.2f ms", table))
        check("warper drag speed", with <= off * 1.3 + 5, "median \(with) ms against \(off)")
    }

    // MARK: The sheet's renders

    /// Into <photos>/../revamp4b/dump when that folder exists: 8-bit sRGB PNGs for the sheet, and the Curves section with
    /// the warper as the inspector draws it.
    private static func revamp4bDump() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = base.appendingPathComponent("revamp4b/dump"), raws = base.appendingPathComponent("shootout/raws")
        guard FileManager.default.fileExists(atPath: out.path) else { return }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func write(_ cg: CGImage, _ name: String) {
            guard let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        func save(_ image: CIImage, _ name: String) {
            let e = image.extent.integral
            let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            if let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb) { write(cg, name) }
        }
        let cases: [(String, ColourWarp?)] = [
            ("plain", nil),
            ("one", r4bWarp([(0, 0, 20, 1)])),
            ("greens", r4bWarp([(3, 0, 25, 1.3), (3, 1, 30, 1.3), (4, 0, 20, 1), (4, 1, 25, 1)])),
            ("bent", r4bBent),
        ]
        for (name, warp) in cases {
            var a = PhotoAdjustments(); a.profile = .asShot; a.curves.warp = warp
            save(PhotoRender.output(PhotoRender.adjusted(r4bWide, a, isRaw: false, kelvin: 5500), a, p3: false), "ramp-\(name)")
            for file in ["DSC02845.ARW", "R6LO7461.CR3"] {
                let path = raws.appendingPathComponent(file).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                var record = PhotoRecord(); record.adjust.curves.warp = warp
                BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
                if let d = PhotoRender.decoded(path, maxSize: 900, record: record) {
                    save(PhotoRender.output(PhotoRender.adjusted(d, record.adjust, path: path), record.adjust, p3: false), "photo-\((file as NSString).deletingPathExtension)-\(name)")
                }
            }
        }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        let defaults = UserDefaults.standard
        let was = defaults.object(forKey: "fold-curves")
        defaults.set(true, forKey: "fold-curves")
        defer { defaults.set(was, forKey: "fold-curves") }
        var curves = PhotoCurves(); curves.warp = r4bBent
        for (name, warp) in [("ui-warper", curves), ("ui-warper-plain", PhotoCurves())] {
            let view = VStack(alignment: .leading, spacing: 16) {
                AdjustFold(title: "Curves", section: .curves, adjust: PhotoAdjustments(), open: true, reset: {}) {
                    CurvesEditor(curves: warp, colour: true, warper: true) { _ in }
                }
            }
            .panelColumn()
            .frame(width: 280, height: 380, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 280, height: 380)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let cg = rep.cgImage { write(cg, name) }
            }
            window.close()
        }
    }
}
