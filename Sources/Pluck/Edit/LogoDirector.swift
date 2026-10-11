import CoreGraphics
import CoreImage
import Foundation
import FoundationModels

/// The director: looks at a logo the way a designer would (local AI: the open vision model, else
/// Apple's on-device model) and picks the animation that suits its character, together with what
/// the analysis knows about its layout.
enum LogoDirector {
    struct Advice: Sendable {
        var style: LogoAnimation.Style
        /// Why, in a sentence (shown under the style menu).
        var reason: String
    }

    enum Mood: String, CaseIterable {
        case playful, friendly, bold, elegant, technical, organic

        var label: String {
            switch self {
            case .playful: String(localized: "playful")
            case .friendly: String(localized: "friendly")
            case .bold: String(localized: "bold")
            case .elegant: String(localized: "elegant")
            case .technical: String(localized: "technical")
            case .organic: String(localized: "organic")
            }
        }
    }

    static func advise(_ animation: LogoAnimation) async -> Advice {
        let mood = await mood(of: animation.logo)
        let layout = animation.layoutStyle
        let style: LogoAnimation.Style
        // Assemble, staged in two acts, is the most crafted: it's the choice unless the logo's
        // character asks for something else.
        switch mood {
        case .organic?: style = .liquid
        case .technical?: style = animation.symbolAndWordmark != nil ? .assemble : .lineDraw
        case .playful?, .friendly?:
            // Bouncing suits a playful name without a symbol or a hero to lead it.
            if case .tracking = animation.assembleMode { style = .bounce } else { style = .assemble }
        case .bold?, .elegant?: style = .assemble
        case nil: style = layout
        }
        let reason: String
        if let mood {
            reason = String(localized: "The logo looks \(mood.label), so: \(style.label). \(style.detail)")
        } else {
            reason = String(localized: "Chosen from the logo’s shapes: \(style.label). \(style.detail)")
        }
        return Advice(style: style, reason: reason)
    }

    private static let question = """
        This is a company or brand logo. In one word, what is its personality? Choose exactly one of: \
        playful, friendly, bold, elegant, technical, organic. Answer with that one word only.
        """

    /// The logo's character, from the local vision model (nil where none can look).
    static func mood(of logo: CGImage) async -> Mood? {
        guard let picture = onWhite(logo) else { return nil }
        var answer: String?
        if VisionModel.ready != nil {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-logo-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            if let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, picture, nil)
                if CGImageDestinationFinalize(destination) {
                    answer = try? await VisionRunner.shared.describe(file, instructions: "You judge brand design.", prompt: question, maxTokens: 12)
                }
            }
        }
        if answer == nil, VisualIndex.canDescribe, #available(macOS 27, *) {
            answer = try? await LanguageModelSession().respond {
                question
                Attachment(picture)
            }.content
        }
        let word = answer?.lowercased() ?? ""
        return Mood.allCases.first { word.contains($0.rawValue) }
    }

    /// The logo on white, with a margin (transparent logos look like nothing to a model).
    private static func onWhite(_ logo: CGImage) -> CGImage? {
        let scale = min(1, 768 / Double(max(logo.width, logo.height)))
        let w = Int(Double(logo.width) * scale), h = Int(Double(logo.height) * scale)
        let margin = max(w, h) / 10
        guard let context = CGContext(data: nil, width: w + margin * 2, height: h + margin * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: margin, y: margin, width: w, height: h))
        return context.makeImage()
    }
}
