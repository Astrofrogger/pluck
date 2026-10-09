import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

/// How captions (shorts) and burned-in subtitles look: a highlight style, its colour, a size and
/// a font. Deliberately few choices. Saved separately for shorts and for subtitles.
struct CaptionDesign: Codable, Equatable, Sendable {
    enum Emphasis: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A coloured box: behind the spoken word (shorts) or the whole line (subtitles).
        case box
        /// The text itself in the colour: the spoken word (shorts) or all of it (subtitles).
        case color
        /// White text with a soft shadow.
        case plain
        var id: String { rawValue }
    }

    enum Size: String, Codable, CaseIterable, Identifiable, Sendable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: String(localized: "Small")
            case .medium: String(localized: "Medium")
            case .large: String(localized: "Large")
            }
        }
    }

    var emphasis: Emphasis = .box
    /// RGB hex without "#".
    var color = "FF5C6B"
    var size: Size = .medium
    /// A font id from `CaptionFonts`.
    var font = "Avenir Next"

    static let shortsKey = "captionDesignShorts"
    static let subtitlesKey = "captionDesignSubtitles"

    /// Swatches offered next to the custom colour: Pluck pink, yellow, green, blue, white.
    static let swatches = ["FF5C6B", "FFD60A", "30D158", "0A84FF", "FFFFFF"]

    static func load(_ key: String) -> CaptionDesign {
        guard let data = UserDefaults.standard.data(forKey: key),
              let design = try? JSONDecoder().decode(CaptionDesign.self, from: data) else {
            var design = CaptionDesign()
            if key == subtitlesKey { design.emphasis = .plain }
            return design
        }
        return design
    }

    func save(_ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: key)
    }

    // MARK: Colours

    var rgb: (r: Double, g: Double, b: Double) {
        let value = UInt32(color, radix: 16) ?? 0xFF5C6B
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    var swiftUIColor: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }

    /// Light colours (yellow, white) need dark text on top of them.
    var isLight: Bool {
        let (r, g, b) = rgb
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6
    }

    /// The colour as ASS writes it: &HAABBGGRR.
    func assColor(alpha: UInt8 = 0) -> String {
        let value = UInt32(color, radix: 16) ?? 0xFF5C6B
        return String(format: "&H%02X%02X%02X%02X", alpha, value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

/// Fonts for captions: a few good built-in ones, plus fonts the user adds (copied into
/// Application Support/Pluck/Fonts, which ffmpeg's subtitle renderer is pointed at).
enum CaptionFonts {
    struct Font: Identifiable, Hashable {
        /// Family name for built-ins, file name for added fonts.
        let id: String
        let displayName: String
        /// The name the subtitle renderer looks up (family, or full name for added fonts).
        let assName: String
        let postScriptName: String
        /// Whether the renderer should pick the family's bold face.
        let bold: Bool
        let isCustom: Bool
    }

    static let builtIn: [Font] = [
        Font(id: "Avenir Next", displayName: "Avenir Next", assName: "Avenir Next", postScriptName: "AvenirNext-Bold", bold: true, isCustom: false),
        Font(id: "Helvetica Neue", displayName: "Helvetica Neue", assName: "Helvetica Neue", postScriptName: "HelveticaNeue-Bold", bold: true, isCustom: false),
        Font(id: "Futura", displayName: "Futura", assName: "Futura", postScriptName: "Futura-Bold", bold: true, isCustom: false),
        Font(id: "DIN Alternate", displayName: "DIN Alternate", assName: "DIN Alternate", postScriptName: "DINAlternate-Bold", bold: true, isCustom: false),
        Font(id: "Georgia", displayName: "Georgia", assName: "Georgia", postScriptName: "Georgia-Bold", bold: true, isCustom: false),
    ]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Fonts", isDirectory: true)
    }

    /// Fonts the user added, registered for this app so previews and measuring can use them.
    static var custom: [Font] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(font(at:))
    }

    static var all: [Font] { builtIn + custom }

    static func find(_ id: String) -> Font {
        all.first { $0.id == id } ?? builtIn[0]
    }

    private static var registered: Set<String> = []

    private static func font(at url: URL) -> Font? {
        guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first,
              let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? postScript
        let full = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? family
        if !registered.contains(url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            registered.insert(url.path)
        }
        return Font(id: url.lastPathComponent, displayName: full, assName: full, postScriptName: postScript, bold: false, isCustom: true)
    }

    /// Asks for font files and copies them in. Returns the first added font's id.
    @MainActor static func addFonts() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose font files (.ttf or .otf) to use for captions and subtitles.")
        guard panel.runModal() == .OK else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var first: String?
        for url in panel.urls {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil, font(at: target) != nil else { continue }
            first = first ?? target.lastPathComponent
        }
        return first
    }
}

/// The caption design controls with a live preview, used by Make Shorts and Subtitles.
struct CaptionDesignEditor: View {
    @Binding var design: CaptionDesign
    /// Shorts highlight the spoken word; subtitles style the whole line.
    var forShorts: Bool
    @State private var fonts: [CaptionFonts.Font] = CaptionFonts.all

    var body: some View {
        preview
        Picker("Highlight", selection: $design.emphasis) {
            Text(forShorts ? "Box" : "Background").tag(CaptionDesign.Emphasis.box)
            Text("Text color").tag(CaptionDesign.Emphasis.color)
            Text("Plain").tag(CaptionDesign.Emphasis.plain)
        }
        .pickerStyle(.segmented)
        if design.emphasis != .plain {
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(CaptionDesign.swatches, id: \.self) { hex in
                        swatch(hex)
                    }
                    ColorPicker("", selection: Binding(get: { design.swiftUIColor },
                                                        set: { design.color = CaptionDesign.hex(from: $0) }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .help("Choose another color")
                }
            }
        }
        Picker("Size", selection: $design.size) {
            ForEach(CaptionDesign.Size.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        HStack {
            Picker("Font", selection: $design.font) {
                ForEach(fonts) { font in
                    Text(font.displayName).tag(font.id)
                }
            }
            Button("Add Font…") {
                if let added = CaptionFonts.addFonts() {
                    fonts = CaptionFonts.all
                    design.font = added
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        var sample = CaptionDesign()
        sample.color = hex
        let selected = design.color.uppercased() == hex
        return Button { design.color = hex } label: {
            Circle()
                .fill(sample.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0.2), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == "FFFFFF" ? String(localized: "White") : "#\(hex)")
    }

    /// What it'll look like, drawn with the real font.
    private var preview: some View {
        let font = CaptionFonts.find(design.font)
        let size: CGFloat = switch design.size {
        case .small: 17
        case .medium: 21
        case .large: 25
        }
        let words = String(localized: "Every production is different").split(separator: " ").map(String.init)
        let active = forShorts ? min(1, words.count - 1) : -1
        let textColor: (Bool) -> Color = { isActive in
            switch design.emphasis {
            case .box where forShorts: isActive && design.isLight ? .black : .white
            case .box: design.isLight ? .black : .white
            case .color: forShorts ? (isActive ? design.swiftUIColor : .white) : design.swiftUIColor
            case .plain: .white
            }
        }
        return HStack(spacing: size * 0.28) {
            ForEach(words.indices, id: \.self) { index in
                Text(words[index])
                    .font(.custom(font.postScriptName, size: size))
                    .foregroundStyle(textColor(index == active))
                    .padding(.horizontal, forShorts && index == active && design.emphasis == .box ? size * 0.22 : 0)
                    .background {
                        if forShorts, index == active, design.emphasis == .box {
                            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(design.swiftUIColor)
                        }
                    }
            }
        }
        .shadow(color: .black.opacity(design.emphasis == .box && !forShorts ? 0 : 0.6), radius: 3, y: 1)
        .padding(.horizontal, !forShorts && design.emphasis == .box ? size * 0.4 : 0)
        .padding(.vertical, !forShorts && design.emphasis == .box ? size * 0.15 : 0)
        .background {
            if !forShorts, design.emphasis == .box {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(design.swiftUIColor.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
