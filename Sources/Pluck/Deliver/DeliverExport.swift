import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Comments out of Pluck (A3): CSV and plain text, markers for Final Cut Pro / Resolve (FCPXML 1.10), Premiere
/// (FCP 7 xmeml), Avid (locators), Resolve's EDL, and a PDF with a still per comment and its drawing.
/// Every export takes the comments as shown (the panel's filter applied).
@MainActor
enum DeliverExport {
    enum Format: String, CaseIterable, Identifiable {
        case csv, text, fcpxml, premiere, avid, edl, pdf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .csv: "CSV"
            case .text: String(localized: "Plain Text")
            case .fcpxml: "Final Cut Pro / Resolve (FCPXML)"
            case .premiere: "Premiere Pro (XML)"
            case .avid: String(localized: "Avid Locators")
            case .edl: "Resolve (EDL)"
            case .pdf: "PDF"
            }
        }
        var ext: String {
            switch self {
            case .csv: "csv"
            case .text, .avid: "txt"
            case .fcpxml: "fcpxml"
            case .premiere: "xml"
            case .edl: "edl"
            case .pdf: "pdf"
            }
        }
        /// Timeline formats need timecoded comments (video and sound).
        var timeline: Bool { [.fcpxml, .premiere, .avid, .edl].contains(self) }
    }

    struct Clip {
        var name: String
        var version: Int
        var probe: Deliver.Probe?
        var fpsNum: Int { probe?.fpsNum ?? 25 }
        var fpsDen: Int { probe?.fpsDen ?? 1 }
        var drop: Bool { probe?.dropFrame ?? false }
        var start: Int { DeliverTimecode.frames(probe?.startTimecode ?? "00:00:00:00", fpsNum: fpsNum, fpsDen: fpsDen, drop: drop) }
        func timecode(_ frame: Int) -> String {
            DeliverTimecode.string(frame: frame, start: probe?.startTimecode ?? "00:00:00:00", fpsNum: fpsNum, fpsDen: fpsDen, drop: drop)
        }
        func place(_ comment: Deliver.Comment) -> String {
            if let frame = comment.frame { return timecode(frame) + (comment.endFrame.map { "–" + timecode($0) } ?? "") }
            if let page = comment.page { return String(localized: "Page \(page)") }
            return String(localized: "General")
        }
    }

    // MARK: - Text formats

    /// A client's text can start with = + - @ (a spreadsheet formula): a leading ' keeps it text.
    static func csvField(_ raw: String) -> String {
        let text = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
        return text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    static func csv(_ comments: [Deliver.Comment], clip: Clip) -> String {
        let head = ["#", "Timecode", "End", "Frame", "Page", "Author", "Comment", "Replies", "Completed", "Internal", "Tags", "Created"]
        let rows = comments.enumerated().map { n, c -> String in
            [String(n + 1), c.frame.map(clip.timecode) ?? "", c.endFrame.map(clip.timecode) ?? "", c.frame.map(String.init) ?? "", c.page.map(String.init) ?? "",
             c.author, c.text, c.replies.map { "\($0.author): \($0.text)" }.joined(separator: "\n"), c.completed ? "yes" : "no", c.isInternal ? "yes" : "no",
             c.tags.map { "#" + $0 }.joined(separator: " "), DeliverServer.date(c.created)].map(csvField).joined(separator: ",")
        }
        return ([head.joined(separator: ",")] + rows).joined(separator: "\r\n") + "\r\n"
    }

    static func text(_ comments: [Deliver.Comment], clip: Clip) -> String {
        var lines = ["\(clip.name) v\(clip.version)", ""]
        for (n, c) in comments.enumerated() {
            lines.append("\(n + 1). \(clip.place(c))  \(c.author)\(c.completed ? "  ✓" : "")\(c.isInternal ? "  (internal)" : "")")
            lines.append(c.text)
            for reply in c.replies { lines.append("   ↳ \(reply.author): \(reply.text)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// FCPXML 1.10: a project whose spine is one gap carrying a marker per comment (to-do markers, ticked when completed).
    static func fcpxml(_ comments: [Deliver.Comment], clip: Clip) -> String {
        let den = clip.fpsDen, num = clip.fpsNum
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames * den)/\(num)s" }
        let frames = max(clip.probe?.frames ?? 1, 1), start = clip.start
        let markers = comments.compactMap { c -> String? in
            guard let frame = c.frame else { return nil }
            let length = (c.endFrame ?? frame) - frame + 1
            return "          <marker start=\"\(time(start + frame))\" duration=\"\(time(length))\" value=\"\(xml(c.author + ": " + c.text))\" completed=\"\(c.completed ? 1 : 0)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" frameDuration="\(den)/\(num)s" width="\(clip.probe?.width ?? 1920)" height="\(clip.probe?.height ?? 1080)"/>
          </resources>
          <library>
            <event name="\(xml(clip.name)) review">
              <project name="\(xml("\(clip.name) v\(clip.version) markers"))">
                <sequence format="r1" duration="\(time(frames))" tcStart="\(time(start))" tcFormat="\(clip.drop ? "DF" : "NDF")">
                  <spine>
                    <gap name="Markers" offset="\(time(start))" start="\(time(start))" duration="\(time(frames))">
        \(markers.joined(separator: "\n"))
                    </gap>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
    }

    /// Final Cut Pro 7 XML (xmeml 5), which Premiere imports: a sequence with a marker per comment.
    static func premiere(_ comments: [Deliver.Comment], clip: Clip) -> String {
        let timebase = DeliverTimecode.rate(clip.fpsNum, clip.fpsDen), ntsc = clip.fpsDen == 1001 ? "TRUE" : "FALSE"
        let rate = "<rate><timebase>\(timebase)</timebase><ntsc>\(ntsc)</ntsc></rate>"
        let markers = comments.compactMap { c -> String? in
            guard let frame = c.frame else { return nil }
            return "    <marker><name>\(xml(c.author))</name><comment>\(xml(c.text))</comment><in>\(frame)</in><out>\(c.endFrame.map(String.init) ?? "-1")</out></marker>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="5">
          <sequence>
            <name>\(xml("\(clip.name) v\(clip.version) markers"))</name>
            <duration>\(max(clip.probe?.frames ?? 1, 1))</duration>
            \(rate)
            <timecode>\(rate)<string>\(clip.probe?.startTimecode ?? "00:00:00:00")</string><frame>\(clip.start)</frame><displayformat>\(clip.drop ? "DF" : "NDF")</displayformat></timecode>
            <media><video><format><samplecharacteristics><width>\(clip.probe?.width ?? 1920)</width><height>\(clip.probe?.height ?? 1080)</height></samplecharacteristics></format></video></media>
        \(markers.joined(separator: "\n"))
          </sequence>
        </xmeml>

        """
    }

    /// Avid Media Composer locators: name, timecode, track, colour, comment, tab separated.
    static func avid(_ comments: [Deliver.Comment], clip: Clip) -> String {
        comments.compactMap { c -> String? in
            guard let frame = c.frame else { return nil }
            let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            return [clean(c.author), clip.timecode(frame), "V1", c.completed ? "green" : "red", clean(c.text)].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    static func string(_ format: Format, _ comments: [Deliver.Comment], clip: Clip) -> String? {
        switch format {
        case .csv: csv(comments, clip: clip)
        case .text: text(comments, clip: clip)
        case .fcpxml: fcpxml(comments, clip: clip)
        case .premiere: premiere(comments, clip: clip)
        case .avid: avid(comments, clip: clip)
        case .edl: DeliverAssetView.markers(comments.filter { $0.frame != nil }, probe: clip.probe, title: clip.name)
        case .pdf: nil
        }
    }

    // MARK: - Stills and the PDF

    /// One frame of a movie as a JPEG at most `maxSide` px.
    nonisolated static func frame(_ movie: URL, seconds: Double, maxSide: Int, into out: URL) async -> Bool {
        guard let image = await image(movie, seconds: seconds, maxSide: maxSide) else { return false }
        return jpeg(image, out)
    }

    nonisolated static func image(_ movie: URL, seconds: Double, maxSide: Int) async -> CGImage? {
        if DeliverStore.kind(movie) == .image {
            guard let source = CGImageSourceCreateWithURL(movie as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000)).image
    }

    nonisolated static func jpeg(_ image: CGImage, _ out: URL, quality: Double = 0.85) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The picture a comment is on: a frame of the original (or the copy's picture or page), with its drawing on top.
    static func still(for comment: Deliver.Comment, asset: Deliver.Asset, version: Deliver.Version, store: DeliverStore) async -> CGImage? {
        let copies = store.copies(version.id)
        var base: CGImage?
        switch asset.kind {
        case .image: base = await image(copies.appendingPathComponent("image.jpg"), seconds: 0, maxSide: 1280)
        case .document: base = await image(copies.appendingPathComponent("pages/\(comment.page ?? 1).jpg"), seconds: 0, maxSide: 1280)
        case .video:
            if let original = store.original(version) {
                let seconds = (Double(comment.frame ?? 0) + 0.5) * Double(version.probe?.fpsDen ?? 1) / Double(version.probe?.fpsNum ?? 25)
                base = await image(original, seconds: seconds, maxSide: 1280)
            }
            if base == nil { base = await image(copies.appendingPathComponent("poster.jpg"), seconds: 0, maxSide: 1280) }
        default: return nil
        }
        guard let base else { return nil }
        guard comment.drawing != nil || comment.anchor != nil else { return base }
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // (Drawings are in 0…1 from the top left.)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for stroke in comment.drawing?.strokes ?? [] { draw(stroke, in: context, size: CGSize(width: width, height: height)) }
        if let anchor = comment.anchor, anchor.count == 2 {
            let point = CGPoint(x: anchor[0] * Double(width), y: anchor[1] * Double(height)), r = max(Double(width) * 0.012, 6)
            context.setFillColor(NSColor(Color(hex: "#E0605E")).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }
        return context.makeImage() ?? base
    }

    static func draw(_ stroke: Deliver.Drawing.Stroke, in context: CGContext, size: CGSize) {
        let points = stroke.points.map { CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) }
        guard let first = points.first else { return }
        let last = points.last ?? first
        context.setStrokeColor(NSColor(Color(hex: stroke.colour)).cgColor)
        context.setLineWidth(max(stroke.width * size.width, 1.5))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        let box = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        switch stroke.tool {
        case .pen: context.addLines(between: points)
        case .line: context.addLines(between: [first, last])
        case .rect: context.addRect(box)
        case .ellipse: context.addEllipse(in: box)
        case .arrow:
            context.addLines(between: [first, last])
            let angle = atan2(last.y - first.y, last.x - first.x), head = max(stroke.width * size.width * 4, 10)
            for turn in [Double.pi * 0.8, -Double.pi * 0.8] {
                context.move(to: last)
                context.addLine(to: CGPoint(x: last.x + head * cos(angle + turn), y: last.y + head * sin(angle + turn)))
            }
        }
        context.strokePath()
    }

    /// A4 pages: the asset's name, then per comment its still (with the drawing), place, author, text and replies.
    static func pdf(_ comments: [Deliver.Comment], asset: Deliver.Asset, version: Deliver.Version, store: DeliverStore, into url: URL) async -> Bool {
        let clip = Clip(name: asset.name, version: version.number, probe: version.probe)
        var stills: [UUID: CGImage] = [:]
        for comment in comments { stills[comment.id] = await still(for: comment, asset: asset, version: version, store: store) }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let margin: CGFloat = 40, width = box.width - margin * 2
        var y: CGFloat = 0
        func newPage() {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            y = box.height - margin
        }
        func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, colour: NSColor = .black) {
            let attributed = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour])
            let height = attributed.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
            if y - height < margin { pdf.endPDFPage(); newPage() }
            attributed.draw(with: NSRect(x: margin, y: y - height, width: width, height: height), options: [.usesLineFragmentOrigin])
            y -= height + 4
        }
        NSGraphicsContext.saveGraphicsState()
        newPage()
        text("\(asset.name) v\(version.number)", size: 18, weight: .semibold)
        text(String(localized: "\(comments.count) comments · \(Date.now.formatted(date: .abbreviated, time: .shortened))"), size: 10, colour: .darkGray)
        y -= 10
        for (n, comment) in comments.enumerated() {
            if let image = stills[comment.id] {
                let height = min(width * CGFloat(image.height) / CGFloat(max(image.width, 1)), 300), drawWidth = height * CGFloat(image.width) / CGFloat(max(image.height, 1))
                if y - height < margin { pdf.endPDFPage(); newPage() }
                pdf.draw(image, in: CGRect(x: margin, y: y - height, width: drawWidth, height: height))
                y -= height + 6
            }
            text("\(n + 1).  \(clip.place(comment))   \(comment.author)\(comment.completed ? "   ✓" : "")", size: 11, weight: .semibold)
            text(comment.text, size: 11)
            for reply in comment.replies { text("↳ \(reply.author): \(reply.text)", size: 10, colour: .darkGray) }
            y -= 14
        }
        pdf.endPDFPage()
        NSGraphicsContext.restoreGraphicsState()
        pdf.closePDF()
        return true
    }

    /// Asks where, then writes the export.
    static func save(_ format: Format, _ comments: [Deliver.Comment], asset: Deliver.Asset, version: Deliver.Version) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(asset.name) v\(version.number) comments.\(format.ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let clip = Clip(name: asset.name, version: version.number, probe: version.probe)
        if let text = string(format, comments, clip: clip) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            Task { _ = await pdf(comments, asset: asset, version: version, store: .shared, into: url) }
        }
    }
}
