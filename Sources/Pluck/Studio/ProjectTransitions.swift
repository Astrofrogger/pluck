import CoreImage
import Foundation

/// The transitions that show both pictures at once, written twice from one description: for the
/// viewer (Core Image) and for the export (an ffmpeg xfade expression), so both draw the same frame.
/// `q` runs from 0 (all the outgoing picture, A) to 1 (all the incoming one, B); ffmpeg's P is 1 − q,
/// and its Y runs down (Core Image's up).
enum ProjectTransitions {
    /// How far an iris's soft edge reaches (a share of the half-diagonal).
    private static let edge = 0.04
    /// The blur dissolve's blur at its middle (a share of the width).
    private static let blurSigma = 0.01
    /// The whip pan's taps along its motion.
    private static let whipTaps = Array(-3...3)

    // MARK: - The viewer

    /// The frame `q` of the way through, both pictures filling `size` (opaque).
    static func blend(_ kind: ProjectTransition.Kind, from a: CIImage, to b: CIImage, progress q: Double, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height, q = min(max(q, 0), 1), cq = CGFloat(q)
        // Mixed as the export mixes: on the encoded values, not in linear light.
        let a = encoded(a.cropped(to: frame)), b = encoded(b.cropped(to: frame))
        func moved(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> CIImage { image.transformed(by: CGAffineTransform(translationX: x, y: y)) }
        func scaled(_ image: CIImage, _ s: Double) -> CIImage {
            image.clampedToExtent().transformed(by: CGAffineTransform(translationX: w / 2, y: h / 2).scaledBy(x: s, y: s).translatedBy(x: -w / 2, y: -h / 2))
        }
        func mix(_ from: CIImage, _ to: CIImage, _ t: Double) -> CIImage {
            from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: t])
        }
        /// The mean of copies moved by these offsets (edges repeated, as ffmpeg's samples are).
        func taps(_ image: CIImage, _ offsets: [(Double, Double)]) -> CIImage {
            let clamped = image.clampedToExtent()
            // A running mean: each copy mixed in by its share.
            var mean: CIImage?
            for (k, (x, y)) in offsets.enumerated() {
                let part = moved(clamped, CGFloat(x), CGFloat(y))
                mean = mean.map { mix($0, part, 1 / Double(k + 1)) } ?? part
            }
            return (mean ?? image).cropped(to: frame)
        }
        /// The incoming picture pushed in from the right (`o` pixels of the way).
        func pushedLeft(_ o: CGFloat) -> CIImage { moved(b, w - o, 0).composited(over: moved(a, -o, 0)).cropped(to: frame) }
        func pushedRight(_ o: CGFloat) -> CIImage { moved(b, o - w, 0).composited(over: moved(a, o, 0)).cropped(to: frame) }

        let out: CIImage
        switch kind {
        case .dissolve, .dipBlack, .dipWhite:
            out = mix(a, b, q)
        case .wipeLeft: out = b.cropped(to: CGRect(x: w * (1 - cq), y: 0, width: w * cq, height: h)).composited(over: a)
        case .wipeRight: out = b.cropped(to: CGRect(x: 0, y: 0, width: w * cq, height: h)).composited(over: a)
        case .wipeUp: out = b.cropped(to: CGRect(x: 0, y: 0, width: w, height: h * cq)).composited(over: a)
        case .wipeDown: out = b.cropped(to: CGRect(x: 0, y: h * (1 - cq), width: w, height: h * cq)).composited(over: a)
        case .pushLeft: out = pushedLeft(w * cq)
        case .pushRight: out = pushedRight(w * cq)
        case .pushUp: out = moved(b, 0, h * cq - h).composited(over: moved(a, 0, h * cq))
        case .pushDown: out = moved(b, 0, h - h * cq).composited(over: moved(a, 0, -h * cq))
        case .irisOpen, .irisClose:
            // Inside the circle the picture coming (open) or going (close); a soft edge.
            let radius = (kind == .irisOpen ? q : 1 - q) * (1 + 2 * edge) - edge
            let reach = hypot(w / 2, h / 2)
            let inner = max(radius - edge, 0), outer = radius + edge
            let mask: CIImage
            if outer <= 0 {
                mask = CIImage(color: .white).cropped(to: frame)
            } else {
                let start = min(max((inner - (radius - edge)) / (2 * edge), 0), 1)
                // The mask's numbers as they are (not taken for sRGB and made linear).
                let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: w / 2, y: h / 2), "inputRadius0": inner * reach, "inputRadius1": max(outer * reach, inner * reach + 0.01),
                    "inputColor0": CIColor(red: start, green: start, blue: start, alpha: 1, colorSpace: linear)!,
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1)])?.outputImage
                mask = (gradient ?? CIImage(color: .white)).cropped(to: frame)
            }
            // White outside the circle: the picture that's outside.
            let (outside, inside) = kind == .irisOpen ? (a, b) : (b, a)
            out = outside.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: inside, kCIInputMaskImageKey: mask])
        case .zoomIn: out = mix(scaled(a, 1 + 0.5 * q), b, q)
        case .zoomOut: out = mix(a, scaled(b, 1.5 - 0.5 * q), q)
        case .blurDissolve:
            // The dissolve, blurred more and more to the middle and sharp again after.
            let mixed = mix(a, b, q)
            let blurred = mixed.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurSigma * Double(w)]).cropped(to: frame)
            out = mix(mixed, blurred, 1 - abs(2 * q - 1))
        case .whipLeft, .whipRight:
            let o = w * CGFloat(q * q * (3 - 2 * q)), spread = 0.015 * Double(w) * sin(.pi * q)
            out = taps(kind == .whipLeft ? pushedLeft(o) : pushedRight(o), whipTaps.map { (Double($0) * spread, 0) })
        }
        let picture = out.cropped(to: frame)
        return picture.matchedToWorkingSpace(from: ProjectCompositor.video) ?? picture.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// The picture's numbers as the video file has them (what ffmpeg mixes).
    private static func encoded(_ image: CIImage) -> CIImage {
        image.matchedFromWorkingSpace(to: ProjectCompositor.video) ?? image.applyingFilter("CILinearToSRGBToneCurve")
    }

    // MARK: - The export

    /// The xfade for this transition: ffmpeg's own where it draws the same frame (a dissolve, the
    /// wipes and pushes; much faster at 4K), else a custom expression (on 4:4:4 pictures, so every
    /// plane has the frame's size). A blur dissolve is a dissolve with its blur laid over
    /// (`blurDissolve`).
    static func xfade(_ kind: ProjectTransition.Kind) -> String {
        switch kind {
        case .dissolve, .dipBlack, .dipWhite, .blurDissolve: "transition=fade"
        case .wipeLeft: "transition=wipeleft"
        case .wipeRight: "transition=wiperight"
        case .wipeUp: "transition=wipeup"
        case .wipeDown: "transition=wipedown"
        case .pushLeft: "transition=slideleft"
        case .pushRight: "transition=slideright"
        case .pushUp: "transition=slideup"
        case .pushDown: "transition=slidedown"
        default: "transition=custom:expr='\(expression(kind))'"
        }
    }

    /// The blur dissolve from `a` into `b` (labels) to `out`: the dissolve, then a blurred copy of
    /// its own frames faded in to the middle and out again (ffmpeg's own filters, not a
    /// per-pixel expression).
    static func blurDissolve(_ a: String, _ b: String, out: String, offset: Double, duration: Double, width: Int, label: String) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.5f", value) }
        let half = duration / 2
        return ["\(a)\(b)xfade=transition=fade:duration=\(number(duration)):offset=\(number(offset)),split=3[\(label)s][\(label)c][\(label)e]",
                "[\(label)c]trim=start=\(number(offset)):duration=\(number(duration)),setpts=PTS-STARTPTS,gblur=sigma=\(number(blurSigma * Double(width))):steps=3[\(label)g]",
                "[\(label)s][\(label)g]xfade=transition=fade:duration=\(number(half)):offset=\(number(offset))[\(label)h]",
                "[\(label)e]trim=start=\(number(offset + half)),setpts=PTS-STARTPTS[\(label)t]",
                "[\(label)h][\(label)t]xfade=transition=fade:duration=\(number(half)):offset=\(number(offset + half))\(out)"]
    }

    /// A sample of the outgoing (`a`) or incoming (`b`) picture, on the plane being made.
    private static func sample(_ input: String, _ x: String, _ y: String) -> String {
        "if(eq(PLANE,0),\(input)0(\(x),\(y)),if(eq(PLANE,1),\(input)1(\(x),\(y)),if(eq(PLANE,2),\(input)2(\(x),\(y)),\(input)3(\(x),\(y)))))"
    }

    /// The custom expression (also for the kinds ffmpeg draws itself: the same frame, slower).
    static func expression(_ kind: ProjectTransition.Kind) -> String {
        let q = "(1-P)"
        func number(_ value: Double) -> String { String(format: "%.5f", value) }
        func a(_ x: String, _ y: String) -> String { sample("a", x, y) }
        func b(_ x: String, _ y: String) -> String { sample("b", x, y) }
        /// The pushed picture at column `x` (clamped to the frame), the incoming one `o` in.
        func pushed(_ x: String, _ o: String, left: Bool) -> String {
            left ? "if(lt(\(x),W-\(o)),\(a("\(x)+\(o)", "Y")),\(b("\(x)-W+\(o)", "Y")))"
                : "if(gte(\(x),\(o)),\(a("\(x)-\(o)", "Y")),\(b("\(x)+W-\(o)", "Y")))"
        }
        switch kind {
        case .dissolve, .dipBlack, .dipWhite, .blurDissolve: return "A*P+B*\(q)"
        case .wipeLeft: return "if(gt(X,W*P),B,A)"
        case .wipeRight: return "if(lt(X,W*\(q)),B,A)"
        case .wipeUp: return "if(gt(Y,H*P),B,A)"
        case .wipeDown: return "if(lt(Y,H*\(q)),B,A)"
        case .pushLeft: return "if(lt(X,W*P),\(a("X+W*\(q)", "Y")),\(b("X-W*P", "Y")))"
        case .pushRight: return "if(gte(X,W*\(q)),\(a("X-W*\(q)", "Y")),\(b("X+W*P", "Y")))"
        case .pushUp: return "if(lt(Y,H*P),\(a("X", "Y+H*\(q)")),\(b("X", "Y-H*P")))"
        case .pushDown: return "if(gte(Y,H*\(q)),\(a("X", "Y-H*\(q)")),\(b("X", "Y+H*P")))"
        case .irisOpen, .irisClose:
            let radius = "(\(kind == .irisOpen ? q : "P")*\(number(1 + 2 * edge))-\(number(edge)))"
            let mask = "clip((hypot(X-W/2,Y-H/2)/hypot(W/2,H/2)-\(radius)+\(number(edge)))/\(number(2 * edge)),0,1)"
            return kind == .irisOpen ? "A*\(mask)+B*(1-\(mask))" : "B*\(mask)+A*(1-\(mask))"
        case .zoomIn:
            let s = "(1+0.5*\(q))"
            return "\(a("W/2+(X-W/2)/\(s)", "H/2+(Y-H/2)/\(s)"))*P+B*\(q)"
        case .zoomOut:
            let s = "(1+0.5*P)"
            return "A*P+\(b("W/2+(X-W/2)/\(s)", "H/2+(Y-H/2)/\(s)"))*\(q)"
        case .whipLeft, .whipRight:
            let o = "(W*\(q)*\(q)*(1+2*P))", spread = "(0.015*W*sin(PI*P))"
            let parts = whipTaps.map { k in pushed("clip(X+\(k)*\(spread),0,W-1)", o, left: kind == .whipLeft) }
            return "(\(parts.joined(separator: "+")))/\(whipTaps.count)"
        }
    }
}
