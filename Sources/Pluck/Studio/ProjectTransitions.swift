import CoreImage
import Foundation

/// Every transition that shows both pictures at once, drawn by Core Image. The viewer calls `blend`
/// for the frames around a cut, and so does the export (`ProjectTransitionRender`, on the frames
/// ffmpeg made), so both draw the same frame. ffmpeg's own xfade is used only where it draws exactly
/// this (`native`), as it's faster at 4K.
/// `q` runs from 0 (all the outgoing picture, A) to 1 (all the incoming one, B); every transition is
/// exactly A at 0 and B at 1.
enum ProjectTransitions {
    /// The blur dissolve's blur at its middle (a share of the width).
    private static let blurSigma = 0.01

    // MARK: - The renderer

    /// The frame `q` of the way through, both pictures filling `size` (opaque).
    static func blend(_ transition: ProjectTransition, from a: CIImage, to b: CIImage, progress q: Double, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        let q = transition.curve.apply(min(max(q, 0), 1)), cq = CGFloat(q)
        let k = transition.strength
        /// 0 at either end, 1 in the middle.
        let bump = sin(.pi * q)
        // Mixed on the encoded values (as the file has them), not in linear light.
        let a = encoded(a.cropped(to: frame)), b = encoded(b.cropped(to: frame))
        let black = CIImage(color: .black).cropped(to: frame)

        func moved(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> CIImage { image.transformed(by: CGAffineTransform(translationX: x, y: y)) }
        /// Turned and scaled about the middle (edges repeated).
        func turned(_ image: CIImage, angle: Double = 0, scale s: Double = 1) -> CIImage {
            image.clampedToExtent().transformed(by: CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: angle).scaledBy(x: s, y: s)
                .translatedBy(x: -w / 2, y: -h / 2)).cropped(to: frame)
        }
        func scaled(_ image: CIImage, _ s: Double) -> CIImage { turned(image, scale: s) }
        /// Smaller than the frame about the middle, on black.
        func shrunk(_ image: CIImage, _ s: Double) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: w / 2, y: h / 2).scaledBy(x: max(s, 0.001), y: max(s, 0.001))
                .translatedBy(x: -w / 2, y: -h / 2)).composited(over: black)
        }
        func mix(_ from: CIImage, _ to: CIImage, _ t: Double) -> CIImage {
            if t <= 0 { return from }
            if t >= 1 { return to }
            return from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: t])
        }
        func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
            radius < 0.05 ? image : image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: frame)
        }
        func motionBlurred(_ image: CIImage, _ radius: Double, vertical: Bool) -> CIImage {
            // (Its taps can add up to a little under one: opaque again.)
            radius < 0.5 ? image : image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius,
                                                                                                       kCIInputAngleKey: vertical ? Double.pi / 2 : 0])
                .unpremultiplyingAlpha().settingAlphaOne(in: frame).cropped(to: frame)
        }
        func zoomBlurred(_ image: CIImage, _ amount: Double) -> CIImage {
            amount < 0.5 ? image : image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: w / 2, y: h / 2),
                                                                                                     "inputAmount": amount]).cropped(to: frame)
        }
        /// The mean of copies turned by these angles.
        func spun(_ image: CIImage, _ angles: [Double]) -> CIImage {
            var mean: CIImage?
            for (n, angle) in angles.enumerated() {
                let part = turned(image, angle: angle)
                mean = mean.map { mix($0, part, 1 / Double(n + 1)) } ?? part
            }
            return mean ?? image
        }
        /// Each channel times this (in the encoded numbers).
        func times(_ image: CIImage, _ f: Double) -> CIImage {
            let v = CGFloat(f)
            return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: v, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
                                                                      "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0)])
        }
        /// B where the mask is white, A where it's black.
        func masked(_ mask: CIImage) -> CIImage {
            b.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask])
        }
        func reveal(_ shape: Float) -> CIImage {
            let mask = revealKernel?.apply(extent: frame, arguments: [Float(q), Float(w), Float(h), shape, Float(transition.soft), direction(transition.way)])
            return masked(mask ?? black)
        }
        /// Where the incoming picture comes from, as a whole frame's move (Core Image's y is up).
        let way = transition.way
        let horizontal = way == .left || way == .right
        let step: (x: CGFloat, y: CGFloat) = switch way {
        case .left: (-w, 0)
        case .right: (w, 0)
        case .up: (0, h)
        case .down: (0, -h)
        }
        /// A moved `t` of the way, B coming in behind it.
        func pushed(_ t: CGFloat, gap: CGFloat = 1) -> CIImage {
            moved(b, step.x * gap * (t - 1), step.y * gap * (t - 1)).composited(over: moved(a, step.x * gap * t, step.y * gap * t)).composited(over: black).cropped(to: frame)
        }
        let smooth = q * q * (3 - 2 * q)
        /// The switch from one picture to the other around the middle.
        func swap(_ from: Double = 0.45, _ to: Double = 0.55) -> CIImage { mix(a, b, smoothstep(from, to, q)) }

        let out: CIImage
        switch transition.kind {
        // Dissolves
        case .dissolve, .dipBlack, .dipWhite:
            out = mix(a, b, q)
        case .dipColour:
            let colour = solid(transition.tint, frame)
            out = q < 0.5 ? mix(a, colour, q * 2) : mix(colour, b, q * 2 - 1)
        case .additiveDissolve:
            out = times(b, min(1, 1.4 * q)).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: times(a, min(1, 1.4 * (1 - q)))])
        case .nonAdditiveDissolve:
            out = times(b, min(1, 2 * q)).applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: times(a, min(1, 2 * (1 - q)))])
        case .lumaFade:
            let mask = lumaKernel?.apply(extent: frame, arguments: [b, Float(q), Float(transition.soft)])
            out = masked(mask ?? black)
        // Blur
        case .blurDissolve:
            let mixed = mix(a, b, q)
            out = mix(mixed, blurred(mixed, blurSigma * Double(w) * (0.4 + 1.2 * k)), 1 - abs(2 * q - 1))
        case .motionBlur:
            out = motionBlurred(mix(a, b, q), k * 0.12 * Double(w) * bump, vertical: !horizontal)
        case .zoomBlur:
            out = zoomBlurred(mix(scaled(a, 1 + 0.3 * k * q), scaled(b, 1 + 0.3 * k * (1 - q)), q), k * 0.16 * Double(w) * bump)
        case .spinBlur:
            let turn = 0.6 * k
            let mixed = mix(turned(a, angle: turn * q, scale: 1 + 0.3 * bump), turned(b, angle: -turn * (1 - q), scale: 1 + 0.3 * bump), smooth)
            out = spun(mixed, (-3...3).map { Double($0) * 0.03 * k * bump })
        case .focusPull:
            let r = k * 0.04 * Double(w)
            out = mix(blurred(a, r * min(2 * q, 1)), blurred(b, r * min(2 - 2 * q, 1)), smoothstep(0.35, 0.65, q))
        // Wipes, iris and shapes
        case .wipe: out = reveal(0)
        case .centerWipe: out = reveal(1)
        case .barnDoor: out = reveal(2)
        case .bandWipe: out = reveal(3)
        case .venetianBlind: out = reveal(4)
        case .edgeWipe: out = reveal(5)
        case .clockWipe: out = reveal(6)
        case .radialWipe: out = reveal(7)
        case .spiralWipe: out = reveal(8)
        case .xWipe: out = reveal(9)
        case .checkerWipe: out = reveal(10)
        case .randomBlocks: out = reveal(11)
        case .irisOpen: out = reveal(20)
        case .irisClose: out = reveal(21)
        case .squareIris: out = reveal(22)
        case .box: out = reveal(23)
        case .diamondIris: out = reveal(24)
        case .crossIris: out = reveal(25)
        case .hexagonIris: out = reveal(26)
        case .pentagonIris: out = reveal(27)
        case .triangleIris: out = reveal(28)
        case .triangleLeft: out = reveal(29)
        case .triangleRight: out = reveal(30)
        case .star: out = reveal(31)
        case .eyeIris: out = reveal(32)
        case .arrowIris: out = reveal(33)
        case .heart: out = reveal(34)
        // Slides and 3D
        case .push: out = pushed(cq)
        case .slide: out = moved(b, step.x * (cq - 1), step.y * (cq - 1)).composited(over: a).cropped(to: frame)
        case .reveal: out = moved(a, step.x * cq, step.y * cq).composited(over: b).cropped(to: frame)
        case .split:
            // A's halves part, B behind them.
            let first = horizontal ? CGRect(x: 0, y: 0, width: w / 2, height: h) : CGRect(x: 0, y: 0, width: w, height: h / 2)
            let second = horizontal ? CGRect(x: w / 2, y: 0, width: w / 2, height: h) : CGRect(x: 0, y: h / 2, width: w, height: h / 2)
            let o = (horizontal ? w : h) / 2 * cq
            let one = moved(a.cropped(to: first), horizontal ? -o : 0, horizontal ? 0 : -o)
            let two = moved(a.cropped(to: second), horizontal ? o : 0, horizontal ? 0 : o)
            out = one.composited(over: two).composited(over: b).cropped(to: frame)
        case .whip:
            out = motionBlurred(pushed(CGFloat(smooth)), k * 0.12 * Double(horizontal ? w : h) * bump, vertical: !horizontal)
        case .swipe:
            let small = 1 - 0.12 * bump
            out = motionBlurred(shrunk(pushed(CGFloat(smooth)), small), k * 0.16 * Double(horizontal ? w : h) * bump, vertical: !horizontal)
        case .squeeze:
            // A pressed against the side it goes to, B opening from the other.
            let s = CGFloat(max(1 - q, 0.0005)), t = CGFloat(max(q, 0.0005))
            let (sa, sb): (CGAffineTransform, CGAffineTransform) = switch way {
            case .left: (CGAffineTransform(scaleX: s, y: 1), CGAffineTransform(translationX: w * s, y: 0).scaledBy(x: t, y: 1))
            case .right: (CGAffineTransform(translationX: w * t, y: 0).scaledBy(x: s, y: 1), CGAffineTransform(scaleX: t, y: 1))
            case .up: (CGAffineTransform(translationX: 0, y: h * t).scaledBy(x: 1, y: s), CGAffineTransform(scaleX: 1, y: t))
            case .down: (CGAffineTransform(scaleX: 1, y: s), CGAffineTransform(translationX: 0, y: h * s).scaledBy(x: 1, y: t))
            }
            out = b.transformed(by: sb).composited(over: a.transformed(by: sa)).composited(over: black).cropped(to: frame)
        case .cube:
            out = cube(a, b, q: q, way: way, size: size, black: black)
        case .flip:
            out = flip(a, b, q: q, way: way, size: size, black: black)
        case .pageCurl:
            let angle: Double = switch way {
            case .left: 0
            case .right: .pi
            case .up: -.pi / 2
            case .down: .pi / 2
            }
            out = a.applyingFilter("CIPageCurlWithShadowTransition", parameters: [
                kCIInputTargetImageKey: b, "inputBacksideImage": a, kCIInputExtentKey: CIVector(cgRect: frame), kCIInputTimeKey: q,
                kCIInputAngleKey: angle, kCIInputRadiusKey: Double(min(w, h)) * 0.15, "inputShadowAmount": 0.5,
            ]).composited(over: black)
        case .door:
            out = door(a, b, q: q, way: way, size: size)
        // Zoom and spin
        case .zoomIn: out = mix(scaled(a, 1 + 0.5 * q), b, q)
        case .zoomOut: out = mix(a, scaled(b, 1.5 - 0.5 * q), q)
        case .pullIn, .crashZoom:
            let crash = transition.kind == .crashZoom
            let reach = (crash ? 2.5 : 1.5) * k, power = crash ? 3.0 : 2.0
            let mixed = mix(scaled(a, 1 + reach * pow(min(2 * q, 1), power)), scaled(b, 1 + reach * pow(min(2 - 2 * q, 1), power)),
                            smoothstep(crash ? 0.48 : 0.42, crash ? 0.52 : 0.58, q))
            out = zoomBlurred(mixed, (crash ? 0.25 : 0.15) * k * Double(w) * bump)
        case .pullOut:
            let reach = 1.5 * k
            let mixed = mix(scaled(a, 1 / (1 + reach * pow(min(2 * q, 1), 2))), scaled(b, 1 / (1 + reach * pow(min(2 - 2 * q, 1), 2))),
                            smoothstep(0.42, 0.58, q))
            out = zoomBlurred(mixed, 0.15 * k * Double(w) * bump)
        case .spin:
            let turns = 2 * Double.pi * (0.5 + k)
            let angle = q < 0.5 ? turns * pow(2 * q, 2) / 2 : -turns * pow(2 - 2 * q, 2) / 2
            let picture = turned(q < 0.5 ? a : b, angle: angle, scale: 1 + 0.6 * bump)
            out = spun(picture, (-2...2).map { Double($0) * 0.08 * k * bump })
        case .rotate:
            let turn = (way == .right || way == .down ? -1.0 : 1.0) * .pi / 2
            out = mix(turned(a, angle: turn * smooth, scale: 1 + 0.8 * bump), turned(b, angle: -turn * (1 - smooth), scale: 1 + 0.8 * bump),
                      smoothstep(0.3, 0.7, q))
        case .shake:
            let jolt = floor(q * 16)
            let reach = k * 0.08 * bump
            let dx = (hash(jolt * 3 + 1) - 0.5) * 2 * reach * Double(w), dy = (hash(jolt * 5 + 2) - 0.5) * 2 * reach * Double(h)
            let picture = turned(moved(swap(), CGFloat(dx), CGFloat(dy)), angle: (hash(jolt * 7 + 3) - 0.5) * 0.08 * k * bump, scale: 1 + reach)
            out = rgb(picture, picture, t: 0, shift: k * 0.012 * Double(w) * bump, frame: frame)
        // Light
        case .flash:
            out = mix(swap(), solid(transition.tint, frame), min(1, 2 * k) * pow(bump, 1.5))
        case .exposure:
            out = swap(0.4, 0.6).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 5 * k * bump * bump]).cropped(to: frame)
        case .glow:
            let mixed = mix(a, b, q)
            out = bump < 0.01 ? mixed : mixed.clampedToExtent().applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 0.04 * Double(w),
                                                                                                         kCIInputIntensityKey: 3 * k * bump]).cropped(to: frame)
        case .lightLeak:
            let strength = min(1, 1.6 * k) * bump
            func spot(_ colour: TransitionColour, _ x: Double, _ y: Double, _ radius: Double) -> CIImage {
                CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: w * x, y: h * y), "inputRadius0": 0, "inputRadius1": Double(w) * radius,
                    "inputColor0": linear(colour, alpha: strength), "inputColor1": linear(colour, alpha: 0),
                ])?.outputImage?.cropped(to: frame) ?? black
            }
            let leak = spot(TransitionColour(red: 1, green: 0.55, blue: 0.15), -0.2 + 1.4 * q, 0.65, 0.6)
                .composited(over: spot(TransitionColour(red: 1, green: 0.2, blue: 0.35), 1.2 - 1.2 * q, 0.3, 0.5))
            out = leak.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: swap(0.3, 0.7)])
        case .filmBurn:
            out = burnKernel?.apply(extent: frame, arguments: [a, b, Float(q), Float(w), Float(h), Float(k)]) ?? swap()
        case .lensFlare:
            let strength = min(1, 2 * k) * bump
            let centre = CIVector(x: w * (0.1 + 0.8 * q), y: h * (0.75 - 0.4 * q))
            let beams = CIFilter(name: "CISunbeamsGenerator", parameters: [
                "inputCenter": centre, "inputColor": linear(TransitionColour(red: 1, green: 0.85, blue: 0.6), alpha: 1),
                "inputSunRadius": Double(w) * 0.07, "inputMaxStriationRadius": 3, "inputStriationStrength": 1,
                "inputStriationContrast": 1.4, "inputTime": q,
            ])?.outputImage?.cropped(to: frame) ?? black
            out = times(beams, strength).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: swap(0.35, 0.65)])
        case .tunnelOfLight:
            let size = q < 0.5 ? 1 - 0.9 * smoothstep(0, 0.5, q) : 0.1 + 0.9 * smoothstep(0.5, 1, q)
            let picture = zoomBlurred(shrunk(q < 0.5 ? a : b, size), 0.2 * k * Double(w) * bump)
            let glow = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: w / 2, y: h / 2), "inputRadius0": 0, "inputRadius1": Double(w) * (0.15 + 0.6 * bump),
                "inputColor0": linear(.white, alpha: min(1, 2 * k) * bump), "inputColor1": linear(.white, alpha: 0),
            ])?.outputImage?.cropped(to: frame) ?? black
            out = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: picture])
        case .filmStrip:
            out = motionBlurred(pushed(CGFloat(smooth), gap: 1.08), 0.06 * Double(h) * bump, vertical: !horizontal)
        // Glitch and distortion
        case .glitch:
            out = glitchKernel?.apply(extent: frame, roiCallback: { _, _ in frame }, arguments: [a, b, Float(q), Float(k), Float(w), Float(h)]) ?? swap()
        case .rgbSplit:
            out = rgb(a, b, t: q, shift: k * 0.06 * Double(w) * bump, frame: frame)
        case .pixelate, .mosaic:
            let scale = k * 0.16 * Double(w) * bump
            let base = swap(0.4, 0.6)
            out = scale < 1.5 ? base : base.clampedToExtent().applyingFilter(transition.kind == .pixelate ? "CIPixellate" : "CIHexagonalPixellate",
                                                           parameters: [kCIInputCenterKey: CIVector(x: w / 2, y: h / 2), kCIInputScaleKey: scale]).cropped(to: frame)
        case .ripple, .swirl, .wave, .bulge:
            let base = mix(a, b, smooth)
            let warp: Float = switch transition.kind {
            case .ripple: 0
            case .swirl: 1
            case .wave: 2
            default: 3
            }
            out = bump < 0.002 ? base : warpKernel?.apply(extent: frame, roiCallback: { _, _ in frame }, image: base,
                                                          arguments: [warp, Float(k * bump * 2), Float(w), Float(h), Float(q)]) ?? base
        case .staticNoise:
            let jolt = floor(q * 24)
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .transformed(by: CGAffineTransform(translationX: CGFloat(hash(jolt + 1) * 997), y: CGFloat(hash(jolt + 2) * 991)))
                .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                .cropped(to: frame) ?? black
            out = mix(swap(), noise, min(1, 2 * k) * 0.9 * pow(bump, 0.7))
        }
        let picture = out.cropped(to: frame)
        return picture.matchedToWorkingSpace(from: ProjectCompositor.video) ?? picture.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// The picture's numbers as the video file has them.
    private static func encoded(_ image: CIImage) -> CIImage {
        image.matchedFromWorkingSpace(to: ProjectCompositor.video) ?? image.applyingFilter("CILinearToSRGBToneCurve")
    }

    private static func smoothstep(_ from: Double, _ to: Double, _ x: Double) -> Double {
        let t = min(max((x - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A number from 0 to 1 that looks random, the same for the same `n` (the kernels' hash too).
    static func hash(_ n: Double) -> Double {
        var p = n * 0.1031
        p -= floor(p)
        p *= p + 33.33
        p *= p + p
        return p - floor(p)
    }

    private static func direction(_ way: ProjectTransition.Direction) -> Float {
        switch way {
        case .left: 0
        case .right: 1
        case .up: 2
        case .down: 3
        }
    }

    /// The colour's numbers as they are (not taken for sRGB and made linear: the blend works on the video's numbers).
    private static func linear(_ colour: TransitionColour, alpha: Double = 1) -> CIColor {
        CIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: alpha, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            ?? CIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: alpha)
    }

    private static func solid(_ colour: TransitionColour, _ frame: CGRect) -> CIImage {
        CIImage(color: linear(colour)).cropped(to: frame)
    }

    /// A into B by `t`, red moved right and blue left by `shift` pixels.
    private static func rgb(_ a: CIImage, _ b: CIImage, t: Double, shift: Double, frame: CGRect) -> CIImage {
        guard shift >= 0.25 || (t > 0 && t < 1) else { return t >= 1 ? b : a }
        return rgbKernel?.apply(extent: frame, roiCallback: { _, _ in frame },
                                arguments: [a, b, Float(t), Float(shift), Float(frame.width), Float(frame.height)]) ?? (t < 0.5 ? a : b)
    }

    // MARK: - 3D

    /// A point on a face, as (along the move, across it, depth), turned by `phi` about the axis across.
    private typealias Corner = (u: Double, v: Double, z: Double)

    /// A face seen in perspective: its picture's four corners where they land (Core Image points) and how far back it is.
    private static func face(_ image: CIImage, first: (u: Double, z: Double), second: (u: Double, z: Double), phi: Double, centre: Double,
                             pivot: Double = 0, way: ProjectTransition.Direction, size: CGSize) -> (image: CIImage, depth: Double)? {
        let w = size.width, h = size.height
        let along = way == .left || way == .right ? w : h, across = way == .left || way == .right ? h : w
        let viewer = 2 * along
        /// The move's frame to Core Image's (y up).
        func place(_ u: Double, _ v: Double) -> CGPoint {
            switch way {
            case .left: CGPoint(x: w / 2 + u, y: h / 2 + v)
            case .right: CGPoint(x: w / 2 - u, y: h / 2 + v)
            case .up: CGPoint(x: w / 2 + v, y: h / 2 - u)
            case .down: CGPoint(x: w / 2 + v, y: h / 2 + u)
            }
        }
        var corners: [(flat: CGPoint, seen: CGPoint)] = []
        var depth = 0.0
        for edge in [first, second] {
            let u = pivot + (edge.u - pivot) * cos(phi) + edge.z * sin(phi), z = centre - (edge.u - pivot) * sin(phi) + edge.z * cos(phi)
            guard viewer + z > 1 else { return nil }
            let s = viewer / (viewer + z)
            depth += z / 2
            for v in [across / 2, -across / 2] {
                // Where this corner of the picture is when the face is flat, facing the viewer.
                let flatU = edge.u == first.u && edge.z == first.z ? -along / 2 : along / 2
                corners.append((place(flatU, v), place(u * s, v * s)))
            }
        }
        func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            CIVector(cgPoint: corners.first { abs($0.flat.x - x) < 0.5 && abs($0.flat.y - y) < 0.5 }?.seen ?? .zero)
        }
        let seen = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": corner(0, h), "inputTopRight": corner(w, h), "inputBottomRight": corner(w, 0), "inputBottomLeft": corner(0, 0),
        ])
        return (seen, depth)
    }

    /// A on the front of a cube turning away, B on the side coming round.
    private static func cube(_ a: CIImage, _ b: CIImage, q: Double, way: ProjectTransition.Direction, size: CGSize, black: CIImage) -> CIImage {
        let along = way == .left || way == .right ? size.width : size.height, half = along / 2
        let phi = q * .pi / 2
        let faces = [face(a, first: (-half, -half), second: (half, -half), phi: phi, centre: half, way: way, size: size),
                     face(b, first: (half, -half), second: (half, half), phi: phi, centre: half, way: way, size: size)].compactMap { $0 }
        return faces.sorted { $0.depth > $1.depth }.reduce(black) { $1.image.composited(over: $0) }.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A swung open like a door on the side it goes to, B behind it.
    private static func door(_ a: CIImage, _ b: CIImage, q: Double, way: ProjectTransition.Direction, size: CGSize) -> CIImage {
        let along = way == .left || way == .right ? size.width : size.height, half = along / 2
        // (Edge on at the end: nothing of A left to draw.)
        guard q < 0.995 else { return b }
        let seen = face(a, first: (-half, 0), second: (half, 0), phi: -q * .pi / 2, centre: 0, pivot: -half, way: way, size: size)
        return (seen?.image.composited(over: b) ?? b).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A card turned over: A to its edge, then B from its edge.
    private static func flip(_ a: CIImage, _ b: CIImage, q: Double, way: ProjectTransition.Direction, size: CGSize, black: CIImage) -> CIImage {
        let along = way == .left || way == .right ? size.width : size.height, half = along / 2
        let phi = q < 0.5 ? q * .pi : (q - 1) * .pi
        let seen = face(q < 0.5 ? a : b, first: (-half, 0), second: (half, 0), phi: phi, centre: 0, way: way, size: size)
        return (seen?.image.composited(over: black) ?? black).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Kernels

    private static let shared = """
    float hash(float n) { n = fract(n * 0.1031); n *= n + 33.33; n *= n + n; return fract(n); }
    """

    /// A wipe, iris or shape: white where B shows. Each shape gives every point the moment (0–1) it
    /// turns; `soft` widens the edge.
    private static let revealKernel = CIColorKernel(source: shared + """
    vec2 along(vec2 p, float dir) {
        if (dir < 0.5) return vec2(1.0 - p.x, p.y);
        if (dir < 1.5) return p;
        if (dir < 2.5) return vec2(1.0 - p.y, p.x);
        return vec2(p.y, p.x);
    }
    float poly(vec2 c, float n, float rot) {
        float d = -10.0;
        for (int i = 0; i < 6; i++) {
            if (float(i) < n) { float t = rot + 6.2831853 * float(i) / n; d = max(d, dot(c, vec2(sin(t), -cos(t)))); }
        }
        return d;
    }
    float star(vec2 c) {
        float seg = 1.2566371;
        float f = abs(mod(atan(c.x, -c.y) + seg * 0.5, seg) - seg * 0.5);
        vec2 e = vec2(0.45 * 0.809017 - 1.0, 0.45 * 0.5877853);
        return length(c) * (cos(f) * e.y - sin(f) * e.x) / e.y;
    }
    float inside(vec2 c, float s) {
        if (s < 32.5) return max(length(c - vec2(0.0, 0.75)), length(c + vec2(0.0, 0.75))) - 1.25;
        if (s < 33.5) {
            float head = (c.x >= 0.0 && abs(c.y) <= 0.8 * (1.0 - c.x)) ? -1.0 : 1.0;
            float shaft = (c.x < 0.0 && c.x > -1.0 && abs(c.y) < 0.3) ? -1.0 : 1.0;
            return min(head, shaft);
        }
        vec2 h = vec2(c.x, 0.1 - c.y) * 1.1;
        float t = h.x * h.x + h.y * h.y - 1.0;
        return t * t * t - h.x * h.x * h.y * h.y * h.y;
    }
    float radial(vec2 c, float s) {
        float lo = 0.0; float hi = 8.0;
        for (int i = 0; i < 18; i++) { float mid = 0.5 * (lo + hi); if (inside(c / mid, s) <= 0.0) hi = mid; else lo = mid; }
        return hi;
    }
    float size(vec2 c, float s, float a) {
        vec2 v = abs(c);
        if (s < 21.5) return length(c);
        if (s < 22.5) return max(v.x, v.y);
        if (s < 23.5) return max(v.x / a, v.y);
        if (s < 24.5) return v.x + v.y;
        if (s < 25.5) return max(max(v.x, v.y), 3.0 * min(v.x, v.y));
        if (s < 26.5) return max(v.y, v.x * 0.8660254 + v.y * 0.5);
        if (s < 27.5) return poly(c, 5.0, 3.1415927);
        if (s < 28.5) return poly(c, 3.0, 3.1415927);
        if (s < 29.5) return poly(c, 3.0, 1.5707963);
        if (s < 30.5) return poly(c, 3.0, -1.5707963);
        if (s < 31.5) return star(c);
        return radial(c, s);
    }
    float field(vec2 p, vec2 c, vec2 uv, float a, float s, float dir) {
        float across = dir < 1.5 ? abs(p.x - 0.5) : abs(p.y - 0.5);
        if (s < 0.5) return uv.x;
        if (s < 1.5) return across * 2.0;
        if (s < 2.5) return 1.0 - across * 2.0;
        if (s < 3.5) { float band = floor(uv.y * 6.0); return mod(band, 2.0) < 0.5 ? uv.x : 1.0 - uv.x; }
        if (s < 4.5) return fract(uv.x * 8.0);
        if (s < 5.5) return (uv.x + 0.35 * uv.y) / 1.35;
        if (s < 6.5) return fract(atan(c.x, -c.y) / 6.2831853 + 1.0);
        if (s < 7.5) return atan(p.y, p.x * a) / 1.5707963;
        if (s < 8.5) {
            float r = length(c) / length(vec2(a * 0.5, 0.5));
            float f = fract(atan(c.x, -c.y) / 6.2831853 + 1.0);
            return (floor(r * 3.0 - f) + f) / 3.0;
        }
        if (s < 9.5) { float dx = p.x - 0.5; float dy = p.y - 0.5; return min(abs(dx - dy), abs(dx + dy)) * 2.0; }
        if (s < 10.5) {
            float rows = floor(8.0 / a + 0.5);
            float odd = mod(floor(p.x * 8.0) + floor(p.y * rows), 2.0);
            return (odd + fract(uv.x * 8.0)) * 0.5;
        }
        if (s < 11.5) return hash(floor(p.x * 16.0) + floor(p.y * 9.0) * 16.0 + 1.0);
        vec2 k = vec2(a * 0.5, 0.5);
        float most = max(max(size(k, s, a), size(vec2(-k.x, k.y), s, a)), max(size(-k, s, a), size(vec2(k.x, -k.y), s, a)));
        float l = size(c, s, a) / most;
        return (s > 20.5 && s < 21.5) ? 1.0 - l : l;
    }
    kernel vec4 reveal(float q, float W, float H, float shape, float soft, float dir) {
        vec2 d = destCoord();
        vec2 p = vec2(d.x / W, 1.0 - d.y / H);
        float a = W / H;
        vec2 c = vec2((p.x - 0.5) * a, p.y - 0.5);
        float l = clamp(field(p, c, along(p, dir), a, shape, dir), 0.0, 1.0);
        float e = max(soft * 0.5, 0.0005);
        float t = q * (1.0 + 2.0 * e) - e;
        float m = 1.0 - smoothstep(t - e, t + e, l);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// B's brighter parts first.
    private static let lumaKernel = CIColorKernel(source: """
    kernel vec4 luma(__sample b, float q, float soft) {
        float l = 1.0 - clamp(dot(b.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
        float e = max(soft * 0.5, 0.0005);
        float t = q * (1.0 + 2.0 * e) - e;
        float m = 1.0 - smoothstep(t - e, t + e, l);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// B burnt through A from a hot, ragged edge.
    private static let burnKernel = CIColorKernel(source: """
    kernel vec4 burn(__sample a, __sample b, float q, float W, float H, float k) {
        vec2 d = destCoord();
        vec2 p = vec2(d.x / W, 1.0 - d.y / H);
        vec2 c = vec2((p.x - 0.25) * W / H, p.y - 0.7);
        float wobble = 0.05 * sin(p.x * 13.0 + p.y * 7.0) + 0.04 * sin(p.y * 17.0 - p.x * 5.0);
        float l = clamp(length(c) / 1.4 + wobble, 0.0, 1.0);
        float t = q * 1.3 - 0.15;
        float m = 1.0 - smoothstep(t - 0.12, t, l);
        float bump = sin(3.1415927 * q);
        float edge = exp(-pow((l - t) / 0.09, 2.0)) * bump * (0.5 + k);
        vec3 c3 = mix(a.rgb, b.rgb, m) + vec3(1.0, 0.5, 0.12) * edge + vec3(0.6) * edge * edge + vec3(0.5, 0.18, 0.04) * bump * k * (1.0 - l);
        return vec4(c3, 1.0);
    }
    """)

    /// A into B by `t`, red `shift` to one side and blue to the other.
    private static let rgbKernel = CIKernel(source: """
    vec4 at(sampler a, sampler b, vec2 p, float t, float W, float H) {
        vec2 c = clamp(p, vec2(0.5), vec2(W - 0.5, H - 0.5));
        return mix(sample(a, samplerTransform(a, c)), sample(b, samplerTransform(b, c)), t);
    }
    kernel vec4 rgbSplit(sampler a, sampler b, float t, float shift, float W, float H) {
        vec2 d = destCoord();
        float r = at(a, b, d - vec2(shift, 0.0), t, W, H).r;
        vec4 g = at(a, b, d, t, W, H);
        float bl = at(a, b, d + vec2(shift, 0.0), t, W, H).b;
        return vec4(r, g.g, bl, 1.0);
    }
    """)

    /// Bands of the picture knocked sideways, colours apart, each band changing over at its own moment.
    private static let glitchKernel = CIKernel(source: shared + """
    vec4 at(sampler s, vec2 p, float W, float H) { return sample(s, samplerTransform(s, clamp(p, vec2(0.5), vec2(W - 0.5, H - 0.5)))); }
    kernel vec4 glitch(sampler a, sampler b, float q, float k, float W, float H) {
        vec2 d = destCoord();
        float jolt = floor(q * 14.0);
        float band = floor((H - d.y) / H * 18.0);
        float on = k * sin(3.1415927 * q);
        float shift = hash(band * 7.0 + jolt * 13.0) > 0.55 ? (hash(band + jolt * 3.1) - 0.5) * 0.25 * W * on : 0.0;
        float split = 0.02 * W * on;
        float useB = q > 0.35 + 0.3 * hash(band * 3.7 + 1.0) ? 1.0 : 0.0;
        vec2 p = vec2(d.x + shift, d.y);
        float r = mix(at(a, p + vec2(split, 0.0), W, H).r, at(b, p + vec2(split, 0.0), W, H).r, useB);
        vec4 g = mix(at(a, p, W, H), at(b, p, W, H), useB);
        float bl = mix(at(a, p - vec2(split, 0.0), W, H).b, at(b, p - vec2(split, 0.0), W, H).b, useB);
        return vec4(r, g.g, bl, 1.0);
    }
    """)

    /// Where each point of a ripple, swirl, wave or bulge takes its picture from.
    private static let warpKernel = CIWarpKernel(source: """
    kernel vec2 warp(float kind, float amount, float W, float H, float q) {
        vec2 d = destCoord();
        vec2 c = vec2(W, H) * 0.5;
        vec2 v = d - c;
        float r = length(v);
        float R = length(c);
        vec2 p = d;
        if (kind < 0.5) {
            float moved = r + amount * 0.025 * R * sin(r / R * 40.0 - q * 20.0);
            p = c + v / max(r, 0.001) * moved;
        } else if (kind < 1.5) {
            float t = amount * 2.5 * pow(max(1.0 - r / R, 0.0), 2.0);
            p = c + vec2(v.x * cos(t) - v.y * sin(t), v.x * sin(t) + v.y * cos(t));
        } else if (kind < 2.5) {
            p = d + vec2(amount * 0.04 * W * sin(d.y / H * 12.0 + q * 8.0), amount * 0.02 * H * sin(d.x / W * 9.0 + q * 5.0));
        } else {
            p = c + v * (1.0 - amount * 0.45 * pow(max(1.0 - r / R, 0.0), 2.0));
        }
        return clamp(p, vec2(0.5), vec2(W - 0.5, H - 0.5));
    }
    """)

    /// The kernels that didn't build (a test: none should).
    static var brokenKernels: [String] {
        [("reveal", revealKernel as Any?), ("luma", lumaKernel), ("burn", burnKernel), ("rgb", rgbKernel), ("glitch", glitchKernel), ("warp", warpKernel)]
            .filter { $0.1 == nil }.map(\.0)
    }

    // MARK: - ffmpeg's own

    /// ffmpeg's xfade transition when it draws this exact frame (a dissolve, a hard wipe, a push),
    /// else nil (the export then blends it with `blend`).
    static func native(_ transition: ProjectTransition) -> String? {
        guard transition.curve == .linear else { return nil }
        let way = transition.way.rawValue
        switch transition.kind {
        case .dissolve: return "fade"
        case .wipe where transition.soft == 0: return "wipe\(way)"
        case .push: return "slide\(way)"
        default: return nil
        }
    }
}
