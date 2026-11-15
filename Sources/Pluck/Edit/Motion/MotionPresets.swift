import AppKit

/// The brand's colours in roles, from its logo (or colours the user picked): a main colour, a
/// second one, and a near black and near white tinted towards them.
struct BrandPalette: Hashable {
    var primary: MotionColor
    var secondary: MotionColor
    var dark: MotionColor
    var light: MotionColor

    /// Until there's a logo or colours of the brand's own: a plain blue and teal, no one's brand.
    static let neutral = BrandPalette(colours: [MotionColor(r: 0.20, g: 0.45, b: 0.75), MotionColor(r: 0.10, g: 0.58, b: 0.56)])

    /// From colours, the main one first (as a logo's, by how much of it they cover).
    init(colours: [MotionColor]) {
        let opaque = colours.map { MotionColor(r: $0.r, g: $0.g, b: $0.b) }
        func chroma(_ c: MotionColor) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        func far(_ a: MotionColor, _ b: MotionColor) -> Bool { pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2) > 0.08 }
        let main = opaque.first { chroma($0) > 0.15 } ?? opaque.first ?? BrandPalette.fallback
        primary = main
        secondary = opaque.first { $0 != main && chroma($0) > 0.15 && far($0, main) }
            ?? (main.relativeLuminance > 0.3 ? main.mixed(MotionColor(r: 0, g: 0, b: 0), 0.35) : main.mixed(.white, 0.35))
        let base = MotionColor(r: 0.04, g: 0.04, b: 0.05)
        // The logo's darkest colour (deepened), when it has a dark one; else its main one, nearly black.
        dark = opaque.filter { $0.relativeLuminance < 0.08 }.min { $0.relativeLuminance < $1.relativeLuminance }.map { $0.mixed(base, 0.55) }
            ?? main.mixed(base, 0.9)
        light = opaque.filter { $0.relativeLuminance > 0.85 }.max { $0.relativeLuminance < $1.relativeLuminance }
            ?? main.mixed(MotionColor(r: 0.97, g: 0.97, b: 0.96), 0.93)
    }

    private static let fallback = MotionColor(r: 0.20, g: 0.45, b: 0.75)

    /// A logo's colours: its accent first, then the rest by how much they cover.
    init(logo: LogoAnimation) { self.init(colours: Self.colours(of: logo)) }

    static func colours(of logo: LogoAnimation) -> [MotionColor] {
        let pack = BrandPack(logo: logo, font: "Helvetica Neue", lowerThirdStyle: .plate, background: nil)
        return [MotionColor(pack.brand)] + pack.palette.map(MotionColor.init)
    }
}

/// A preset: a whole look for every output (which layout each kind of graphic uses, the type,
/// shapes, motion and how the brand's colours are used), drawn in any brand's palette.
struct MotionPreset: Identifiable, Hashable {
    enum Group: String, CaseIterable, Identifiable {
        case clean, bold, elegant, playful, broadcast
        var id: String { rawValue }
        var label: String {
            switch self {
            case .clean: String(localized: "Clean")
            case .bold: String(localized: "Bold")
            case .elegant: String(localized: "Elegant")
            case .playful: String(localized: "Playful")
            case .broadcast: String(localized: "Broadcast")
            }
        }
    }

    /// What the cards stand on.
    enum Ground { case dark, deep, light, brand, clear }

    let id: String
    let name: String
    let group: Group
    /// The layout (template id) for lower thirds, titles, logo & end, social.
    let layouts: (lowerThird: String, title: String, logo: String, social: String)
    var titleFont = "Helvetica Neue"
    var bodyFont = "Helvetica Neue"
    var weight = 0.7
    var uppercase = false
    var tracking: Double?
    var round = 0.2
    var glow = 0.0
    var grain = false
    var moving = false
    var ground = Ground.dark
    /// Words and plates in a gradient of the brand's two colours (else its main colour only).
    var gradient = false
    /// No colour but black and white (and the logo's own).
    var mono = false
    /// See-through plates (a frosted look over the picture).
    var glass = false

    static func == (a: MotionPreset, b: MotionPreset) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func layout(_ category: MotionTemplate.Category) -> MotionTemplate {
        let id = switch category {
        case .lowerThird: layouts.lowerThird
        case .title: layouts.title
        case .logo: layouts.logo
        case .social: layouts.social
        }
        return MotionTemplate.all.first { $0.id == id } ?? .slab
    }

    /// The look in a brand's colours, every pair of text and what it's on readable (WCAG: 4.5:1
    /// for text, 3:1 for big words, lines and plates in the brand colour).
    func style(_ palette: BrandPalette) -> MotionStyle {
        var style = MotionStyle()
        style.titleFont = titleFont
        style.bodyFont = bodyFont
        style.titleWeight = weight
        style.uppercase = uppercase ? true : nil
        style.tracking = tracking
        style.roundness = round
        style.glow = glow
        style.grain = grain
        style.moving = moving
        style.plates = nil
        let background: MotionColor? = switch ground {
        case .dark: palette.dark
        case .deep: palette.primary.mixed(MotionColor(r: 0.03, g: 0.03, b: 0.04), 0.78)
        case .light: palette.light
        case .brand: palette.primary
        case .clear: nil
        }
        style.background = background
        // Text: white or near black, whichever reads on the card (white over the picture).
        let surface = background ?? MotionColor(r: 0.08, g: 0.08, b: 0.09)
        style.text = surface.ink
        // Plates: a step further from the text than the card (the brand's near black or near
        // white on a card in its main colour), or frosted.
        let darkText = style.text == .ink
        var plate = darkText ? surface.mixed(.white, 0.6) : surface.mixed(MotionColor(r: 0, g: 0, b: 0), 0.35)
        if ground == .brand { plate = darkText ? palette.light : palette.dark }
        if plate.contrast(style.text) < 4.5 { plate = darkText ? MotionColor(r: 0.97, g: 0.97, b: 0.96) : MotionColor(r: 0.06, g: 0.06, b: 0.07) }
        if glass { plate = MotionColor(r: 1, g: 1, b: 1, a: 0.16) }
        style.secondary = plate
        // The accent: the brand's main colour (its second on a card in the main colour), readable on the card.
        var accent = ground == .brand ? palette.secondary : palette.primary
        if mono { accent = style.text }
        accent = accent.readable(on: surface, 3)
        if ground == .brand, accent.contrast(surface) < 3 { accent = style.text }
        style.accent = accent
        var partner = gradient && !mono ? (ground == .brand ? palette.primary.mixed(palette.secondary, 0.5) : palette.secondary) : accent
        partner = partner.readable(on: surface, 3)
        // Words set on the gradient read on both of its ends.
        if accent.ink.contrast(partner) < 3 { partner = accent }
        style.accent2 = partner
        return style
    }

    // MARK: - The presets

    static let all: [MotionPreset] = [
        MotionPreset(id: "minimal", name: String(localized: "Minimal"), group: .clean,
                     layouts: ("editorial", "minimal", "endminimal", "caption"), weight: 0.45, round: 0, ground: .clear),
        MotionPreset(id: "corporate", name: String(localized: "Corporate"), group: .clean,
                     layouts: ("stack", "headline", "endcard", "features"), titleFont: "Avenir Next", bodyFont: "Avenir Next", weight: 0.62,
                     round: 0.15, ground: .deep),
        MotionPreset(id: "bold", name: String(localized: "Bold"), group: .bold,
                     layouts: ("broadcast", "bigtype", "wipe", "subscribe"), titleFont: "Futura", bodyFont: "Avenir Next", weight: 0.95,
                     uppercase: true, round: 0, ground: .brand),
        MotionPreset(id: "editorial", name: String(localized: "Magazine"), group: .elegant,
                     layouts: ("editorial", "chapter", "endcorner", "quote"), titleFont: "Didot", bodyFont: "Avenir Next", weight: 0.5, round: 0),
        MotionPreset(id: "tech", name: String(localized: "Tech"), group: .clean,
                     layouts: ("outline", "frame", "endminimal", "typing"), titleFont: "Avenir Next", bodyFont: "Menlo", weight: 0.55,
                     round: 0.3, glow: 0.25, ground: .deep, gradient: true),
        MotionPreset(id: "luxury", name: String(localized: "Luxury"), group: .elegant,
                     layouts: ("tag", "minimal", "endminimal", "quote"), titleFont: "Bodoni 72", bodyFont: "Optima", weight: 0.3,
                     uppercase: true, tracking: 0.16, round: 0),
        MotionPreset(id: "sport", name: String(localized: "Sport"), group: .bold,
                     layouts: ("broadcast", "split", "wipe", "progress"), titleFont: "DIN Condensed", bodyFont: "Avenir Next Condensed", weight: 0.95,
                     uppercase: true, round: 0, ground: .brand, gradient: true),
        MotionPreset(id: "documentary", name: String(localized: "Documentary"), group: .elegant,
                     layouts: ("tag", "headline", "endminimal", "caption"), titleFont: "Iowan Old Style", bodyFont: "Avenir Next", weight: 0.45,
                     round: 0, grain: true),
        MotionPreset(id: "pop", name: String(localized: "Social Pop"), group: .playful,
                     layouts: ("pill", "statement", "endcard", "subscribe"), titleFont: "Avenir Next", bodyFont: "Avenir Next", weight: 0.9,
                     round: 1, glow: 0.3, ground: .brand, gradient: true),
        MotionPreset(id: "retro", name: String(localized: "Retro Film"), group: .playful,
                     layouts: ("stack", "frame", "sting", "quote"), titleFont: "Rockwell", bodyFont: "American Typewriter", weight: 0.7,
                     round: 0.1, grain: true, ground: .deep),
        MotionPreset(id: "mono", name: String(localized: "Monochrome"), group: .clean,
                     layouts: ("slab", "boxed", "endminimal", "caption"), weight: 0.7, round: 0, mono: true),
        MotionPreset(id: "gradient", name: String(localized: "Gradient"), group: .playful,
                     layouts: ("slab", "headline", "sting", "features"), titleFont: "Avenir Next", bodyFont: "Avenir Next", weight: 0.75,
                     round: 0.3, glow: 0.6, grain: true, moving: true, ground: .deep, gradient: true),
        MotionPreset(id: "glass", name: String(localized: "Glass"), group: .clean,
                     layouts: ("slab", "frame", "endcard", "typing"), titleFont: "Avenir Next", bodyFont: "Avenir Next", weight: 0.55,
                     round: 0.6, moving: true, ground: .deep, glass: true),
        MotionPreset(id: "split", name: String(localized: "Split"), group: .bold,
                     layouts: ("stack", "split", "endsplit", "quote"), titleFont: "Gill Sans", bodyFont: "Gill Sans", weight: 0.75, round: 0),
        MotionPreset(id: "outline", name: String(localized: "Outline"), group: .clean,
                     layouts: ("outline", "frame", "endminimal", "caption"), titleFont: "Avenir Next Condensed", bodyFont: "Avenir Next", weight: 0.6,
                     uppercase: true, round: 0, ground: .clear),
        MotionPreset(id: "bigtype", name: String(localized: "Big Type"), group: .bold,
                     layouts: ("highlight", "bigtype", "endcorner", "caption"), weight: 1, uppercase: true, tracking: -0.01, round: 0),
        MotionPreset(id: "news", name: String(localized: "News"), group: .broadcast,
                     layouts: ("broadcast", "boxed", "bug", "progress"), weight: 0.8, round: 0),
        MotionPreset(id: "festival", name: String(localized: "Festival"), group: .playful,
                     layouts: ("kinetic", "statement", "sting", "subscribe"), titleFont: "Futura", bodyFont: "Futura", weight: 0.9,
                     uppercase: true, round: 0.5, glow: 0.5, moving: true, ground: .deep, gradient: true),
        MotionPreset(id: "realestate", name: String(localized: "Real Estate"), group: .elegant,
                     layouts: ("slab", "minimal", "endsplit", "features"), titleFont: "Optima", bodyFont: "Avenir Next", weight: 0.5,
                     round: 0.1, ground: .light),
        MotionPreset(id: "automotive", name: String(localized: "Automotive"), group: .bold,
                     layouts: ("editorial", "split", "wipe", "progress"), titleFont: "Futura", bodyFont: "Avenir Next", weight: 0.6,
                     uppercase: true, tracking: 0.12, round: 0),
        MotionPreset(id: "fashion", name: String(localized: "Fashion"), group: .elegant,
                     layouts: ("stack", "bigtype", "endcorner", "quote"), titleFont: "Didot", bodyFont: "Futura", weight: 0.4,
                     uppercase: true, tracking: 0.08, round: 0, ground: .light, mono: true),
        MotionPreset(id: "food", name: String(localized: "Food"), group: .playful,
                     layouts: ("stack", "boxed", "endcard", "features"), titleFont: "Avenir Next", bodyFont: "Avenir Next", weight: 0.8,
                     round: 0.8, ground: .light),
        MotionPreset(id: "nonprofit", name: String(localized: "Nonprofit"), group: .clean,
                     layouts: ("stack", "headline", "endsplit", "quote"), titleFont: "Seravek", bodyFont: "Seravek", weight: 0.65,
                     round: 0.3, ground: .light),
        MotionPreset(id: "studio", name: String(localized: "Studio"), group: .broadcast,
                     layouts: ("slab", "chapter", "endcard", "progress"), titleFont: "DIN Alternate", bodyFont: "Helvetica Neue", weight: 0.8,
                     round: 0.1, ground: .deep),
        MotionPreset(id: "event", name: String(localized: "Conference"), group: .broadcast,
                     layouts: ("tag", "boxed", "endsplit", "features"), titleFont: "Gill Sans", bodyFont: "Gill Sans", weight: 0.7,
                     round: 0.2, ground: .brand),
        MotionPreset(id: "cinema", name: String(localized: "Cinema"), group: .elegant,
                     layouts: ("editorial", "minimal", "endminimal", "caption"), titleFont: "Baskerville", bodyFont: "Gill Sans", weight: 0.4,
                     uppercase: true, tracking: 0.28, round: 0, grain: true),
    ]

    static func named(_ id: String?) -> MotionPreset? { all.first { $0.id == id } }

    /// Graphics over the picture drawn larger in stills, to be seen in a small thumbnail.
    static func stillPlacement(_ template: MotionTemplate, _ placement: MotionPlacement) -> MotionPlacement {
        guard !template.fullFrame else { return placement }
        var shown = placement
        shown.scale *= template.category == .lowerThird ? 2 : 1.5
        return shown
    }

    /// A moment that shows the graphic settled (for stills): after the logo has landed.
    static func stillTime(_ template: MotionTemplate, placement: MotionPlacement, logoPlan: LogoAnimation.Plan?) -> Double {
        let settled = max(2.6, (logoPlan?.intro ?? 0) + 0.4) / max(placement.speed, 0.1)
        return min(settled, max(placement.duration - 0.8, 0.5))
    }
}

extension MotionTemplate.Category {
    var symbol: String {
        switch self {
        case .lowerThird: "rectangle.bottomthird.inset.filled"
        case .title: "textformat.size"
        case .logo: "seal"
        case .social: "bubble.left"
        }
    }
}

extension MotionTemplate {
    /// What lower thirds that set words straight on the picture are judged against (a dim frame).
    static let pictureStandIn = MotionColor(r: 0.22, g: 0.24, b: 0.27)
    /// Lower thirds and overlays whose words sit on the picture, not on a plate.
    static let overPicture: Set<String> = ["editorial", "kinetic", "outline", "tag", "highlight", "pill", "bug"]
}
