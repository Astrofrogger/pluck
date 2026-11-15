import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension Deliver {
    /// The review page's look for clients: a logo (and one for light backgrounds) and three colours.
    /// Set in Settings › Review for every project, or per project (overriding).
    struct Branding: Codable, Hashable {
        var name = ""
        var logo: Data?                  // PNG ≤ 512 px tall
        var logoLight: Data?
        var accent = "#B56C89"
        var bg = "#0F0F11"
        var text = "#EDEBE6"
        var header: Data?                // JPEG ≤ 400 KB, the link page's header picture (§6.1)
        static let headerBytes = 400_000

        /// Each logo at most this big, so `welcome` (both logos in base64) stays under a browser's 256 KiB message.
        static let logoBytes = 90_000

        /// The text and accent moved until they read on the background (WCAG: 4.5 for text, 3 for the accent).
        var readable: Branding {
            var fixed = self
            let bg = Self.rgb(self.bg)
            if Self.contrast(Self.rgb(text), bg) < 4.5 { fixed.text = Self.luminance(bg) > 0.4 ? "#111114" : "#F5F5F2" }
            var accent = Self.rgb(self.accent)
            for _ in 0..<20 where Self.contrast(accent, bg) < 3 {
                accent = Self.luminance(bg) > 0.4 ? accent.map { $0 * 0.85 } : accent.map { $0 + (1 - $0) * 0.2 }
            }
            fixed.accent = Self.hex(accent)
            return fixed
        }

        /// What browsers get after auth (§6 `welcome`): small, base64 PNGs.
        var wire: [String: Any] {
            var json: [String: Any] = ["name": name, "accent": accent, "bg": bg, "text": text]
            if let logo { json["logo"] = logo.base64EncodedString() }
            if let logoLight { json["logoLight"] = logoLight.base64EncodedString() }
            return json
        }

        static func rgb(_ hex: String) -> [Double] {
            let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            return [Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255]
        }

        static func hex(_ rgb: [Double]) -> String {
            String(format: "#%02X%02X%02X", Int((min(max(rgb[0], 0), 1) * 255).rounded()), Int((min(max(rgb[1], 0), 1) * 255).rounded()),
                   Int((min(max(rgb[2], 0), 1) * 255).rounded()))
        }

        static func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }

        static func contrast(_ a: [Double], _ b: [Double]) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }

        static func isHex(_ text: String) -> Bool { text.count == 7 && text.hasPrefix("#") && UInt32(text.dropFirst(), radix: 16) != nil }

        /// A PNG, SVG or PDF as a PNG at most 512 px tall and `logoBytes` big (smaller until it fits).
        static func logo(from url: URL) -> Data? {
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
            var height = min(512, max(image.size.height * 2, 64))
            while height >= 32 {
                let width = (image.size.width / image.size.height * height).rounded()
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                if let png = bitmap.representation(using: .png, properties: [:]), png.count <= logoBytes { return png }
                height = (height * 0.75).rounded()
            }
            return nil
        }

        /// A wide picture for the top of the link page: JPEG, at most 1920 px wide and `headerBytes` (smaller until it fits).
        static func header(from url: URL) -> Data? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var side = 1920
            while side >= 480 {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                                                                  kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(destination), data.length <= headerBytes { return data as Data }
                side = side * 3 / 4
            }
            return nil
        }

        /// Colours from a Brand Profile's palette: the most colourful as the accent.
        static func colours(from profile: BrandProfile) -> String? {
            profile.palette.compactMap(\.hex).filter(isHex).max { saturation(rgb($0)) < saturation(rgb($1)) }
        }

        /// The logo's own main colourful one (BrandPack's palette, for vector logos).
        static func colours(fromLogo url: URL) -> String? {
            guard let animation = try? LogoAnimation(contentsOf: url) else { return nil }
            let pack = BrandPack(logo: animation, font: "Helvetica Neue", lowerThirdStyle: .plate, background: nil)
            let colours = pack.palette.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] }
            return colours.max { saturation($0) < saturation($1) }.map(hex)
        }

        static func saturation(_ rgb: [Double]) -> Double { (rgb.max() ?? 0) - (rgb.min() ?? 0) }
    }
}

extension DeliverStore {
    private var brandingFile: URL { root.appendingPathComponent("branding.json") }

    /// Settings › Review's branding (nil: Pluck's own look).
    var branding: Deliver.Branding? {
        get { (try? Data(contentsOf: brandingFile)).flatMap { try? Deliver.decoder.decode(Deliver.Branding.self, from: $0) } }
        set {
            if let newValue { try? Deliver.encoder.encode(newValue).write(to: brandingFile, options: .atomic) } else { try? FileManager.default.removeItem(at: brandingFile) }
            commentsChangedTick()
        }
    }

    private func projectBrandingFile(_ project: UUID) -> URL { folder(project).appendingPathComponent("branding.json") }

    func projectBranding(_ project: UUID) -> Deliver.Branding? {
        (try? Data(contentsOf: projectBrandingFile(project))).flatMap { try? Deliver.decoder.decode(Deliver.Branding.self, from: $0) }
    }

    func setProjectBranding(_ branding: Deliver.Branding?, _ project: UUID) {
        let file = projectBrandingFile(project)
        if let branding { try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try? Deliver.encoder.encode(branding).write(to: file, options: .atomic) }
        else { try? FileManager.default.removeItem(at: file) }
        commentsChangedTick()
    }

    /// What a project's clients see: its own, else Settings'.
    func branding(for project: UUID) -> Deliver.Branding? { (projectBranding(project) ?? branding)?.readable }
}

/// The branding editor (Settings › Review, and a project's Branding sheet).
struct DeliverBrandingEditor: View {
    @Binding var branding: Deliver.Branding?
    @State private var logoFile: URL?
    @State private var profiles = BrandProfiles.shared

    var body: some View {
        let value = branding ?? Deliver.Branding()
        VStack(alignment: .leading, spacing: 2) {
            SettingRow("Name") { TextField("Studio name", text: bind(\.name)).settingField(width: 200) }
            SettingRow("Logo") {
                if let data = value.logo, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(height: 22) }
                Button("Choose…") { choose(light: false) }.settingButton()
                if value.logo != nil { Button("Remove") { change { $0.logo = nil } }.settingButton() }
            }
            SettingRow("Logo on light") {
                if let data = value.logoLight, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(height: 22).padding(2).background(.white) }
                Button("Choose…") { choose(light: true) }.settingButton()
                if value.logoLight != nil { Button("Remove") { change { $0.logoLight = nil } }.settingButton() }
            }
            SettingRow("Header picture") {
                if let data = value.header, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(height: 22) }
                Button("Choose…") { chooseHeader() }.settingButton()
                if value.header != nil { Button("Remove") { change { $0.header = nil } }.settingButton() }
            }
            SettingRow("Colours") {
                colour(\.accent, "Accent")
                colour(\.bg, "Background")
                colour(\.text, "Text")
            }
            SettingRow("From") {
                Menu {
                    ForEach(profiles.all) { profile in
                        Button(profile.name) { if let hex = Deliver.Branding.colours(from: profile) { change { $0.accent = hex; if $0.name.isEmpty { $0.name = profile.name } } } }
                    }
                } label: { StudioMenuLabel(title: String(localized: "A Brand Profile")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(profiles.all.isEmpty)
                Button("The Logo") { if let logoFile, let hex = Deliver.Branding.colours(fromLogo: logoFile) { change { $0.accent = hex } } }
                    .settingButton().disabled(logoFile == nil)
                if branding != nil { Button("Reset") { branding = nil }.settingButton() }
            }
            if let branding, branding.readable != branding {
                SettingNote(text: Text("Colours adjusted so text reads on the background."), symbol: "eye", colour: Design.Studio.textQuiet)
            }
        }
    }

    private func change(_ edit: (inout Deliver.Branding) -> Void) {
        var value = branding ?? Deliver.Branding()
        edit(&value)
        branding = value
    }

    private func bind(_ path: WritableKeyPath<Deliver.Branding, String>) -> Binding<String> {
        Binding(get: { (branding ?? Deliver.Branding())[keyPath: path] }, set: { text in change { $0[keyPath: path] = Deliver.clean(text, limit: 60) } })
    }

    private func colour(_ path: WritableKeyPath<Deliver.Branding, String>, _ help: LocalizedStringKey) -> some View {
        ColorPicker(selection: Binding(get: { Color(hex: (branding ?? Deliver.Branding())[keyPath: path]) }, set: { colour in
            guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
            change { $0[keyPath: path] = Deliver.Branding.hex([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]) }
        }), supportsOpacity: false) { EmptyView() }
            .labelsHidden()
            .help(Text(help))
    }

    private func chooseHeader() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url, let jpeg = Deliver.Branding.header(from: url) else { return }
        change { $0.header = jpeg }
    }

    private func choose(light: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .svg, .pdf, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let png = Deliver.Branding.logo(from: url) else { return }
        if !light { logoFile = url }
        change { if light { $0.logoLight = png } else { $0.logo = png } }
    }
}

/// A project's own branding (over Settings').
struct DeliverProjectBrandingSheet: View {
    let project: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var branding: Deliver.Branding?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Branding").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            Text(branding == nil ? "Uses the branding in Settings › Review." : "This project’s own.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            DeliverBrandingEditor(branding: $branding).padding(.vertical, 4).studioBox()
            HStack {
                Spacer()
                Button("Done") { DeliverStore.shared.setProjectBranding(branding, project); dismiss() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .background(Design.Studio.panel)
        .onAppear { branding = DeliverStore.shared.projectBranding(project) }
    }
}
