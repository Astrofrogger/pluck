import AppKit
import SwiftUI

/// The inspector's column stays inside its panel: a row wider than the panel once made the whole
/// column wider and centred it, cutting the fold and slider names off on the left.
extension PhotoSelfTest {
    static func panelColumn() async {
        // At the window's least width (1120) the photos keep 600 pt: the panels give way first.
        let fit = PhotoPage.fitted(left: 420, right: 520, total: 1118)
        check("photo page: the photos keep 600 pt at the narrowest window", 1118 - fit.left - fit.right >= 600 && fit.left >= 200 && fit.right >= 280
              && PhotoPage.fitted(left: 0, right: 310, total: 1118) == (0, 310), "got \(fit)")
        let box = Box()
        // The Light fold open, as it starts (put back afterwards).
        let defaults = UserDefaults.standard, wasOpen = defaults.object(forKey: "fold-light")
        defaults.set(true, forKey: "fold-light")
        defer { defaults.set(wasOpen, forKey: "fold-light") }
        // Nested as the Photo page holds its inspector: beside a flexible view, fixed width, clipped,
        // a header over a ScrollViewReader and a ScrollView.
        let view = HStack(spacing: 0) {
            Color.clear
            VStack(spacing: 0) {
                Text(verbatim: "Adjust").font(.headline)
                ScrollViewReader { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Wider than the panel (as the Profile, Auto and Looks row at a narrow panel).
                            Color.clear.frame(width: 400, height: 10)
                            AdjustFold(title: "Light", section: .light, adjust: PhotoAdjustments(), open: true, reset: {}) {
                                AdjustSlider(title: "Exposure", value: 0, range: -5...5) { _ in }
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { box.slider = $0 }
                            }
                        }
                        .panelColumn()
                    }
                }
            }
            .frame(width: 280)
            .clipped()
            .coordinateSpace(.named("panel"))
        }
        .frame(width: 900, height: 300)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let frame = box.slider
        check("inspector names start inside the panel", frame.width > 0 && frame.minX >= Design.Sidebar.inset - 0.5 && frame.maxX <= 280 - Design.Sidebar.inset + 0.5,
              "slider row within 8…272; got \(frame.minX)…\(frame.maxX)")
        window.close()
        scopesWiring()
    }

    /// The Photo page's scopes read a developed image through the Edit page's maths: pure red puts the parade's red at the top and the vectorscope in red's direction.
    static func scopesWiring() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        guard let data = PhotoScopes.data(red) else { check("photo scopes data", false, "no data for a red image"); return }
        func top(_ bins: [UInt16]) -> Int { (0..<256).last { bins[$0] > 0 } ?? -1 }
        let mid = data.width / 2 * 256
        let r = top(Array(data.red[mid..<mid + 256])), g = top(Array(data.green[mid..<mid + 256]))
        let want = ScopeAnalyzer.vectorPoint(red: 1, green: 0, blue: 0)
        let at = data.vector.indices.max { data.vector[$0] < data.vector[$1] } ?? 0
        check("photo scopes: red image", r >= 250 && g <= 5 && abs(Double(at % 256) - want.cb) <= 3 && abs(Double(at / 256) - want.cr) <= 3,
              "parade red top >= 250, green <= 5, vector at red; got \(r), \(g), cb \(at % 256) cr \(at / 256) vs \(want)")
    }

    @MainActor private final class Box { var slider = CGRect.zero }
}
