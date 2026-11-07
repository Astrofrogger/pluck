import AppKit
import CoreImage
import SwiftUI

/// The big photo follows the basic adjustments once its film is on: a real loupe in a window, its record changed
/// as the panel changes it, and what its canvas is given to draw measured (instant film, a drag, 400 %, and tables
/// made for an advanced setting).
extension PhotoSelfTest {
    static func filmRefresh() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-filmrefresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.jpg")
        // A real photo at 6000 px (larger than the preview, so 400 % needs the full size).
        guard let first = try? FileManager.default.contentsOfDirectory(atPath: photos).sorted().first(where: { $0.lowercased().hasSuffix(".jpg") }),
              let source = CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent(first)),
              case let big = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 6000 / source.extent.width, "inputAspectRatio": 1]),
              let jpeg = PhotoEngine.context.jpegRepresentation(of: big.cropped(to: big.extent.integral), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              (try? jpeg.write(to: file)) != nil else { return check("film loupe follows exposure", false, "a test photo written") }
        await FilmEngine.shared.loadProfiles()
        let editing = PhotoEditing.shared
        let saved = (editing.zoom, editing.beforeAfter)
        defer { editing.zoom = saved.0; editing.beforeAfter = saved.1 }
        editing.zoom = nil
        editing.beforeAfter = .off

        let box = RefreshBox()
        let host = NSHostingView(rootView: RefreshHost(path: file.path, box: box))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        /// The brightness of what the canvas is given to draw now.
        func shown() -> Double {
            guard let canvas = find(host), let image = Mirror(reflecting: canvas).children.first(where: { $0.label == "image" })?.value as? CIImage,
                  !image.extent.isInfinite, image.extent.width > 0 else { return -1 }
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var pixel = [Float](repeating: 0, count: 4)
            PhotoEngine.context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        }
        func settle(_ ms: Int = 2500) async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(ms))
            host.layoutSubtreeIfNeeded()
        }

        await settle()
        box.record.filmOn = true
        box.record.film.changed["scan_film"] = .number(0)
        await settle()
        let film = shown()
        // One click on the slider.
        box.record.adjust.exposure = 1.5
        await settle()
        let once = shown()
        check("film loupe follows exposure", once - film > 0.05, "brighter by 0.05 after +1.5 EV on film; got \(film) then \(once)")
        // A drag: quick steps, then it rests.
        for step in 1...8 {
            box.record.adjust.exposure = 1.5 - Double(step) * 0.3
            try? await Task.sleep(for: .milliseconds(40))
        }
        await settle()
        let dragged = shown()
        check("film loupe follows a dragged exposure", once - dragged > 0.05, "darker by 0.05 after dragging to -0.9 EV; got \(once) then \(dragged)")
        // Zoomed in past the preview: the full size follows too.
        editing.zoom = 4
        await settle(4000)
        box.record.adjust.exposure = 1.5
        await settle(4000)
        let zoomed = shown()
        check("film loupe follows exposure zoomed in", zoomed - dragged > 0.05, "brighter by 0.05 at 400% after +1.5 EV; got \(dragged) then \(zoomed)")
        // An advanced setting (its tables made first), then the exposure again.
        editing.zoom = nil
        guard FilmEngine.shared.state == .ready else { return skip("film loupe follows exposure on made tables", "no film data") }
        box.record.film.changed["push_pull_stops"] = .number(1)
        await settle(10000)
        let pushed = shown()
        box.record.adjust.exposure = -1
        await settle(4000)
        let darker = shown()
        check("film loupe follows exposure on made tables", pushed - darker > 0.05, "darker by 0.05 after -2.5 EV; got \(pushed) then \(darker)")
    }

    private static func find(_ view: NSView) -> PhotoCanvasView? {
        if let canvas = view as? PhotoCanvasView { return canvas }
        for sub in view.subviews { if let found = find(sub) { return found } }
        return nil
    }

    @MainActor @Observable fileprivate final class RefreshBox { var record = PhotoRecord() }

    fileprivate struct RefreshHost: View {
        let path: String
        let box: RefreshBox
        var body: some View { PhotoLoupe(path: path, record: box.record) }
    }
}
