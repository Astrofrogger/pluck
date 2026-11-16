import AppKit
import CoreText
import SwiftUI

extension PhotoSelfTest {
    /// Brand profiles in Delivery Check (-PluckScreenshotOnly brandcheck): clips made in the test
    /// home by the bundled ffmpeg with a test logo at an exact place, then moved 1 and 3 px, 2 %
    /// bigger, in the wrong colour, gone from the end card, and with text in its clear space.
    /// Exactly placed: no issue; 1 px off: "off by 1 px" at tolerance 0, nothing at 1; the rest
    /// found. Measuring the exact clip gives back its rule; a brand book PDF gives its colours.
    static func brandCheckTest() async {
        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg") else { return check("brand: bundled ffmpeg", false, "no ffmpeg") }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("BrandCheckTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        /// The test logo: a square, a circle and a bar, 4 px of transparent edge round them.
        func logoPNG(scale: Double = 1, colour: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) -> Data? {
            let w = Int((156 * scale).rounded(.up)) + 8, h = Int((56 * scale).rounded(.up)) + 8
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Top left origin, like the frames.
            context.translateBy(x: 0, y: Double(h)); context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 4, y: 4); context.scaleBy(x: scale, y: scale)
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: 0, width: 56, height: 56))
            context.fillEllipse(in: CGRect(x: 66, y: 0, width: 56, height: 56))
            context.fill(CGRect(x: 132, y: 0, width: 24, height: 56))
            return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        func textPNG(_ text: String) -> (data: Data, width: Int)? {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]))
            let w = Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up)) + 4, h = 40
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.textPosition = CGPoint(x: 2, y: 10)
            CTLineDraw(line, context)
            return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }.map { ($0, w) }
        }
        guard let logo = logoPNG(), let big = logoPNG(scale: 1.02), let yellow = logoPNG(colour: CGColor(srgbRed: 0.94, green: 0.75, blue: 0.25, alpha: 1)),
              let text = textPNG("SAMPLE") else { return check("brand: test pictures", false) }
        for (name, data) in [("logo", logo), ("big", big), ("yellow", yellow), ("text", text.data)] {
            try? data.write(to: base.appendingPathComponent(name + ".png"))
        }

        // The rule: top right, 60 px in, 40 px down, 156 px wide, in 1280×720. The PNG's 4 px edge is outside the logo.
        let x = 1280 - 60 - 156 - 4, y = 40 - 4
        func clip(_ name: String, logo: String = "logo", at position: (Int, Int) = (x, y), until: Double? = nil, extra: String? = nil) -> URL {
            let out = base.appendingPathComponent(name + ".mov")
            var arguments = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=0x1C2633:s=1280x720:r=25:d=4",
                             "-i", base.appendingPathComponent(logo + ".png").path]
            // (RGB: in 4:2:0 ffmpeg would round the place to even pixels.)
            var graph = "[0][1]overlay=format=rgb:x=\(position.0):y=\(position.1)" + (until.map { ":enable='lt(t,\($0))'" } ?? "")
            if let extra {
                arguments += ["-i", base.appendingPathComponent("text.png").path]
                graph += "[a];[a][2]overlay=format=rgb:" + extra
            }
            graph += "[v]"
            _ = run(ffmpeg, arguments + ["-filter_complex", graph, "-map", "[v]", "-c:v", "prores_ks", "-profile:v", "2", out.path])
            return out
        }
        let exact = clip("exact"), one = clip("one", at: (x + 1, y)), three = clip("three", at: (x, y + 3))
        // 2 % bigger, its right edge kept where the rule's is (to a pixel).
        let bigger = clip("bigger", logo: "big", at: (1280 - 60 - Int((156 * 1.02).rounded()) - 4, y))
        let wrong = clip("wrong", logo: "yellow"), gone = clip("gone", until: 2)
        // "SAMPLE" ending 8 px left of the logo, inside its 20 px clear space.
        let crowded = clip("crowded", extra: "x=\(x + 4 - 8 - text.width):y=50")
        guard fm.fileExists(atPath: crowded.path) else { return check("brand: test clips made", false) }

        var profile = BrandProfile(name: "Example Brand")
        profile.logos = [.init(fileName: "logo.png", data: logo)]
        var placement = BrandProfile.Placement()
        placement.referenceWidth = 1280; placement.referenceHeight = 720
        placement.anchor = .topRight; placement.x = 60; placement.y = 40; placement.width = 156
        profile.placements = [placement]
        profile.timing.mode = .endCard; profile.timing.endCard = 2
        profile.clearSpace = .init(amount: 20, percent: false)
        profile.logoColour = "#FFFFFF"
        profile.forbiddenTexts = ["Sample"]

        func issues(_ file: URL, _ profile: BrandProfile) async -> [DeliveryCheck.Issue] {
            await BrandCheck.run(file: file, profile: profile, duration: 4) { _ in }
        }
        func describe(_ list: [DeliveryCheck.Issue]) -> String {
            list.map { "\($0.title) [\($0.time.map { String(format: "%.2f", $0) } ?? "-")–\($0.end.map { String(format: "%.2f", $0) } ?? "")] \($0.detail)" }
                .joined(separator: "; ")
        }

        // The locator itself, for the log: how close it gets on the exact clip.
        if let video = await BrandCheck.Video(exact), let image = await video.frame(60), let frame = BrandLogoLocator.Frame(image),
           let picture = BrandProfile.image(of: profile.logos[0]) {
            let expected = placement.rect(in: CGSize(width: 1280, height: 720), logoAspect: Double(picture.width) / Double(picture.height))
            if let match = BrandLogoLocator.locate(picture, in: frame, expected: expected) {
                note(String(format: "brand: exact clip found at %.3f, %.3f, %.3f wide (rule %.1f, %.1f, %.1f), score %.4f, colour %@",
                            match.rect.minX, match.rect.minY, match.rect.width, expected.minX, expected.minY, expected.width, match.score, BrandProfile.hex(match.colour)))
            } else {
                check("brand: locator finds the logo", false)
            }
        }

        let started = Date()
        let onExact = await issues(exact, profile)
        check("brand: exactly placed logo has no issues", onExact.isEmpty, describe(onExact))
        note(String(format: "brand: one clip checked in %.1f s", Date().timeIntervalSince(started)))

        let onOne = await issues(one, profile)
        check("brand: 1 px off says off by 1 px", onOne.contains { $0.title == "Logo off by 1 px" } && onOne.count == 1, describe(onOne))
        var lenient = profile
        lenient.placements[0].tolerance = 1
        let onOneLenient = await issues(one, lenient)
        check("brand: 1 px off is fine at 1 px tolerance", onOneLenient.isEmpty, describe(onOneLenient))
        let onThree = await issues(three, profile)
        check("brand: 3 px down says off by 3 px", onThree.contains { $0.title == "Logo off by 3 px" && $0.detail.contains("3 px down") }, describe(onThree))
        let onBigger = await issues(bigger, profile)
        check("brand: 2 % bigger is too large", onBigger.contains { $0.title == "Logo too large" && $0.detail.contains("+2.0") }, describe(onBigger))
        let onWrong = await issues(wrong, profile)
        check("brand: wrong colour found", onWrong.contains { $0.title == "Wrong logo colour" } && !onWrong.contains { $0.title.hasPrefix("Logo off") }, describe(onWrong))
        let onGone = await issues(gone, profile)
        let missing = onGone.filter { $0.title == "Logo missing in end card" }
        check("brand: logo missing in the end card, one issue over it", missing.count == 1 && abs((missing.first?.time ?? 0) - 2) < 0.05
              && (missing.first?.end ?? 0) > 3.9, describe(onGone))
        let onCrowded = await issues(crowded, profile)
        check("brand: text in the clear space found", onCrowded.contains { $0.title == "Something inside the logo’s clear space" && $0.detail.contains("SAMPLE") }, describe(onCrowded))
        check("brand: forbidden text found", onCrowded.contains { $0.title == "Forbidden text" }, describe(onCrowded))

        // Required text: the exact clip has none.
        var needsText = profile
        needsText.forbiddenTexts = []
        needsText.requiredTexts = [.init(text: "All rights reserved", when: .endCard)]
        let onRequired = await issues(exact, needsText)
        check("brand: required text missing", onRequired.contains { $0.title == "Required text missing" }, describe(onRequired))

        // Measuring an approved video.
        if let measured = await BrandCheck.measure(file: exact, logo: profile.logos[0]) {
            let p = measured.placement
            check("brand: measured placement is the rule", p.anchor == .topRight && p.x == 60 && p.y == 40 && p.width == 156
                  && p.referenceWidth == 1280 && measured.timing?.mode == .always && measured.colour == "#FFFFFF",
                  "\(p.anchor) \(p.x) \(p.y) \(p.width) \(p.referenceWidth) \(String(describing: measured.timing?.mode)) \(measured.colour)")
        } else {
            check("brand: measured placement is the rule", false, "not found")
        }
        if let measured = await BrandCheck.measure(file: gone, logo: profile.logos[0]) {
            check("brand: measured timing finds the logo's stretch", measured.timing?.mode == .ranges && measured.timing?.ranges.first == .init(start: 0, end: 2),
                  "\(String(describing: measured.timing))")
        }

        // Saved, exported and imported.
        let store = BrandProfiles.shared
        try? store.save(profile)
        check("brand: profile saved and read back", store.profile(profile.id) == profile)
        let exported = base.appendingPathComponent("Example Brand.json")
        try? BrandProfiles.encoded(profile).write(to: exported)
        let imported = try? store.importFile(exported)
        check("brand: imported profile is a copy", imported.map { $0.id != profile.id && $0.logos == profile.logos && $0.placements == profile.placements } ?? false)
        store.delete(profile)
        if let imported { store.delete(imported) }

        // A brand book.
        let pdf = base.appendingPathComponent("book.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        if let context = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            context.beginPDFPage(nil)
            let lines = ["Logo", "Clear space", "Keep 20 px free around the logo.", "Minimum size: 120 px wide.",
                         "Primary colour #E4002B", "Secondary RGB 0 163 224", "CMYK 0 100 80 5", "Pantone 186 C"]
            for (n, line) in lines.enumerated() {
                let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
                context.textPosition = CGPoint(x: 60, y: 780 - Double(n) * 24)
                CTLineDraw(ct, context)
            }
            if let source = CGImageSourceCreateWithData(logo as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                context.draw(image, in: CGRect(x: 60, y: 300, width: 164, height: 64))
            }
            context.endPDFPage()
            context.closePDF()
        }
        let suggestions = BrandBookImport.read(pdf)
        let labels = suggestions.map(\.label)
        check("brand: brand book colours found", labels.contains("#E4002B") && labels.contains("#00A3E0")
              && labels.contains("CMYK 0 100 80 5") && labels.contains("Pantone 186 C"), labels.joined(separator: ", "))
        check("brand: brand book clear space and minimum size", suggestions.contains { if case .clearSpace(let s) = $0.kind { s.amount == 20 && !s.percent } else { false } }
              && suggestions.contains { if case .minimumWidth(let w) = $0.kind { w == 120 } else { false } }, labels.joined(separator: ", "))
        check("brand: brand book logo picture found", suggestions.contains { if case .logo = $0.kind { true } else { false } }, labels.joined(separator: ", "))
        var fromBook = BrandProfile(name: "From book")
        BrandBookImport.apply(suggestions, to: &fromBook)
        check("brand: ticked suggestions applied", fromBook.palette.contains { $0.hex == "#E4002B" } && fromBook.clearSpace.amount == 20 && fromBook.minimumWidth == 120)

        let percent = BrandBookImport.rules(in: "Clear space\n25% of the logo width")
        check("brand: brand book percent clear space", percent.contains { if case .clearSpace(let s) = $0.kind { s.amount == 25 && s.percent } else { false } }, percent.map(\.label).joined(separator: ", "))
        // The editor drawn off screen (never shown), beside the log, for looking at.
        if let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") {
            var shown = profile
            shown.palette = [.init(hex: "#E4002B"), .init(hex: "#00A3E0"), .init(name: "Pantone 186 C")]
            shown.requiredTexts = [.init(text: "All rights reserved", when: .endCard, area: .bottom)]
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 820, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: BrandProfileEditor(profile: shown).environment(\.colorScheme, .dark))
            try? await Task.sleep(for: .seconds(1.5))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + "-editor.png"))
            }
            window.close()
        }

        func run(_ tool: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
