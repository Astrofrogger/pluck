import SwiftUI

/// Pluck's design tokens: the sizes, spacing and shapes controls share, so a text field, a menu
/// and buttons that sit side by side line up exactly. Use these instead of numbers in views.
enum Design {
    /// Pluck's own colours, from the app icon: a warm pink running into violet. Used sparingly,
    /// for what's chosen and the main action, so it keeps meaning something.
    /// Around photos being judged: a neutral grey (coloured or very dark surroundings shift how
    /// colour and brightness are seen).
    enum Photo {
        /// The grey around a photo (0 black … 1 white), chosen by the user; dark grey unless changed.
        static let surroundKey = "photoSurround"
        static var surroundWhite: CGFloat {
            CGFloat(UserDefaults.standard.object(forKey: surroundKey) as? Double ?? 0.16)
        }
        static var surround: Color { Color(white: surroundWhite) }
        /// The choices: black, the important greys (18 % grey is the middle), white.
        static let surrounds: [(title: LocalizedStringKey, white: Double)] = [
            ("Black", 0), ("Dark Grey", 0.16), ("Middle Grey (18 %)", 0.46), ("Light Grey", 0.75), ("White", 1),
        ]
    }

    enum Brand {
        /// Pluck Studio uses the brandbook's plum (2026-11-09); basic Pluck keeps the icon's pink into violet.
        static let pink = Edition.isStudio ? rgb(0xB56C89) : Color(red: 0.99, green: 0.37, blue: 0.48)
        static let violet = Edition.isStudio ? rgb(0x7C5FC0) : Color(red: 0.56, green: 0.33, blue: 0.96)
        static let gradient = LinearGradient(colors: [pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        /// Deeper plum: a selected tab's solid fill (with white text) and the logo.
        static let deep = LinearGradient(colors: [rgb(0x8E4C64), rgb(0x533C88)], startPoint: .topLeading, endPoint: .bottomTrailing)
        /// What's chosen (a tab, a tool that's on): Pluck's colours in Pluck Studio, the Mac's
        /// accent colour in basic Pluck.
        static var chosen: AnyShapeStyle { Edition.isStudio ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.accentColor) }
        static var chosenFill: AnyShapeStyle {
            Edition.isStudio ? AnyShapeStyle(gradient.opacity(0.22)) : AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
    }

    /// Pluck Studio's surfaces, text and shapes (brandbook v1, 2026-11-09). The interface stays
    /// neutral so colour judgement isn't tinted: plum only for the logo, what's selected and what changed.
    enum Studio {
        static let backdrop = rgb(0x0F0F11)
        static let panel = rgb(0x1A1A1D)
        static let raised = rgb(0x242428)
        static let line = rgb(0x333338)
        static let text = rgb(0xEDEBE6)
        static let textQuiet = rgb(0xA3A3A9)
        /// Chevrons and icons only: too faint for text you have to read.
        static let textFaint = rgb(0x66666C)
        /// Warnings (a check that failed, a jump cut): soft amber; the brandbook has no red.
        static let warn = rgb(0xE0A15E)
        /// Done and checked (an offload on every drive), and gone wrong (a problem to fix).
        static let good = rgb(0x7CC294)
        static let bad = rgb(0xE0605E)

        static let controlRadius: CGFloat = 7
        static let panelRadius: CGFloat = 12
        static let windowRadius: CGFloat = 14
        static let panelGap: CGFloat = 8
        static let panelInset: CGFloat = 12
        static let sectionGap: CGFloat = 18
        static let sliderRow: CGFloat = 22
        static let sliderTrack: CGFloat = 3
        static let sliderDot: CGFloat = 12

        static let hint = Font.system(size: 11)
        static let body = Font.system(size: 12)
        static let sectionTitle = Font.system(size: 14, weight: .medium)
        static let pageTitle = Font.system(size: 22)
    }

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    enum Size {
        /// Every control in a bar: the link field, the format menu, the round buttons.
        static let control: CGFloat = 44
        /// Symbols inside bar controls.
        static let icon: CGFloat = 17
        /// The main action's symbol, a touch bolder.
        static let primaryIcon: CGFloat = 19
    }

    enum Spacing {
        /// Between controls in a bar.
        static let controls: CGFloat = 10
        /// Inside a capsule control, from its edge to its content.
        static let inset: CGFloat = 16
        /// Between a window's edge and its content.
        static let window: CGFloat = 20
        /// Around a sheet's or tool window's content.
        static let sheet: CGFloat = 24
        /// Between the parts of a sheet (header, form, notes, buttons).
        static let section: CGFloat = 16
        /// Between a header's symbol and its text.
        static let headerGap: CGFloat = 12
    }

    /// One scale of corner radii, from the smallest badge to the window-wide highlight.
    enum Radius {
        /// Duration badges on thumbnails.
        static let badge: CGFloat = 4
        /// Small thumbnails in lists, colour swatches.
        static let small: CGFloat = 6
        /// Small boxes and tiles.
        static let control: CGFloat = 8
        /// Thumbnails and previews.
        static let thumbnail: CGFloat = 10
        /// Grouped panels inside a window.
        static let box: CGFloat = 12
        /// Banners and cards on the main window.
        static let card: CGFloat = 16
        /// The drop highlight around the whole window.
        static let panel: CGFloat = 18
    }

    /// The left sidebars (Photo, Edit's panel, Projects) and the inspectors' folds, after
    /// LightCraft's calm rhythm (docs/superpowers/specs/2026-11-04-sidebar-layout.md).
    enum Sidebar {
        static let width: Double = 260
        static let widthRange: ClosedRange<Double> = 200...420
        /// From the panel's edge to a row's highlight.
        static let inset: CGFloat = 8
        /// Inside a row's highlight, to its icon and its count (so both sit 18 from the edge).
        static let rowPadding: CGFloat = 10
        static let rowHeight: CGFloat = 28
        /// The Photo page's top row, in the middle (toolbar) and in the inspector (tabs), so their dividers line up.
        static let topRowHeight: CGFloat = 46
        static let headerHeight: CGFloat = 28
        /// Above each section, with a hairline in the middle.
        static let sectionGap: CGFloat = 12
        /// Per level of a tree.
        static let indent: CGFloat = 16
        static let icon: CGFloat = 16
        static let iconGap: CGFloat = 8
        static let label = Font.body
        static let count = Font.callout.monospacedDigit()
        /// Title Case, dimmed; 13 like LightCraft (one token if it feels too big).
        static let header = Font.body.weight(.semibold)
        /// An inspector's fold (Light, Colour, Transform…).
        static let foldHeight: CGFloat = 32
        /// A slider row in an inspector: one line, its name in a column this wide.
        static let sliderHeight: CGFloat = 28
        static let sliderLabel: CGFloat = 88
    }

    enum Typography {
        /// Text typed in, or chosen in, a bar control.
        static let control = Font.system(size: 15)
        /// Small counts and badges in a bar control.
        static let badge = Font.callout.weight(.medium)
        /// A sheet's title.
        static let sheetTitle = Font.title3.weight(.semibold)
        /// The big symbol next to a sheet's title.
        static let sheetSymbol = Font.largeTitle
        /// Notes under a form ("Runs on this Mac…").
        static let note = Font.callout
    }
}

/// Exactly as wide as it's offered (a scroll view's width), never as wide as its widest child:
/// that child runs off on the right instead of widening and centring everything.
private struct OfferedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The top of a sheet or tool window: its symbol, title and what it works on.
struct SheetHeader: View {
    let symbol: String
    let title: Text
    var subtitle: Text?
    /// An item's name: one line, shortened in the middle. Otherwise the subtitle wraps.
    var subtitleIsName = true

    var body: some View {
        HStack(spacing: Design.Spacing.headerGap) {
            Image(systemName: symbol)
                .font(Design.Typography.sheetSymbol)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(Design.Typography.sheetTitle)
                if let subtitle {
                    if subtitleIsName {
                        subtitle.foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        subtitle.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A note under a form, like "Runs on this Mac…": small, secondary, wrapping.
    func noteStyle() -> some View {
        font(Design.Typography.note)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A side panel's scrolling column (an inspector): the sidebar's inset, and never wider than the
    /// panel. Without the cap, one row wider than the panel made the whole column wider, centred
    /// it, and cut the fold names and slider names off on the left.
    func panelColumn() -> some View {
        OfferedWidth { padding(.horizontal, Design.Sidebar.inset) }
    }

    /// A capsule bar control: the shared height, inset and glass, for fields and menus.
    func barControl() -> some View {
        padding(.horizontal, Design.Spacing.inset)
            .frame(height: Design.Size.control)
            .glassBackground(in: .capsule, interactive: true)
    }

    /// A text field as a capsule bar control: plain, the control font, glass.
    func capsuleField() -> some View {
        textFieldStyle(.plain)
            .font(Design.Typography.control)
            .barControl()
    }

    /// A box for longer text (a text editor, a list of names): glass with the box radius.
    func textBox(height: CGFloat) -> some View {
        font(Design.Typography.control)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: height)
            .glassBackground(in: .rect(cornerRadius: Design.Radius.box, style: .continuous), interactive: true)
    }
}

/// A round bar button with the shared size: plain glass, or filled with the accent colour for
/// the main action.
struct BarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? Design.Size.primaryIcon : Design.Size.icon,
                          weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Design.Size.control, height: Design.Size.control)
            .background {
                // Pluck Studio's main buttons wear its own colours.
                if prominent { Circle().fill(Edition.isStudio ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.accentColor)) }
            }
            .glassBackground(in: .circle, interactive: true)
            .contentShape(.circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A capsule bar button with text, the shared height: the main action of a bar (accent), or one
/// that ends something (red), like Record and Stop.
struct BarCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.control.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, Design.Spacing.inset + 4)
            .frame(height: Design.Size.control)
            .background(Capsule().fill(tint))
            .glassBackground(in: .capsule, interactive: true)
            .contentShape(.capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A card: one block of a tool window, with the download rows' rounded fill, so tool windows
/// read like the main window.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(Design.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .fill(.fill.quaternary)
                    .opacity(0.6)
            }
    }
}

/// A card's top line: its symbol in a tinted tile, title, an optional line under it, and
/// whatever goes on the right (a status chip, a switch, a button).
struct CardHeader<Accessory: View>: View {
    let symbol: String
    let title: Text
    var subtitle: Text?
    var tint: Color = .accentColor
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: Design.Size.icon, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: Design.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline)
                if let subtitle {
                    subtitle.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(symbol: String, title: Text, subtitle: Text? = nil, tint: Color = .accentColor) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, tint: tint) { EmptyView() }
    }
}

/// A small status in a capsule with a coloured dot: Ready, Connecting…, Off.
struct StatusChip: View {
    let text: Text
    var colour: Color = .green
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(colour).frame(width: 7, height: 7)
            }
            text.font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(colour.opacity(0.12), in: .capsule)
        .foregroundStyle(.primary)
    }
}

/// A capsule bar button for secondary actions (Choose…, Add Folder…): the shared height and
/// glass, without the accent fill of the main action.
struct GlassCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.control.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Design.Spacing.inset)
            .frame(height: Design.Size.control)
            .glassBackground(in: .capsule, interactive: true)
            .contentShape(.capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A small round glass button for an action in a row or card (cancel, fetch, remove).
struct RowButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .buttonStyle(BarButtonStyle())
        .scaleEffect(0.82)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

/// A tool window's page: scrolling, the window's margin, and a readable width for pages of
/// cards (pass `maxWidth: nil` for full-width media, like grids and previews).
struct ToolPage<Content: View>: View {
    var maxWidth: CGFloat? = 760
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.section) { content }
                .padding(Design.Spacing.window)
                .frame(maxWidth: maxWidth ?? .infinity)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .softTopScrollEdge()
    }
}

/// The welcome at the top of a tool with nothing in it yet: a symbol in a tinted circle, a
/// title and one line on what it does. The tool's main input bar goes under it.
struct ToolWelcome: View {
    let symbol: String
    let title: Text
    let subtitle: Text

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .background(Color.accentColor.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
            title.font(.title2.weight(.semibold))
            subtitle
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }
}

/// The one-line note at the bottom of a page ("Runs on this Mac."), with the details in its hint.
struct PageNote: View {
    let text: Text
    var symbol = "lock.shield"
    var detail: Text?

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .help(detail ?? text)
    }
}

/// A primary input bar like the main window's link field: a symbol, a text field, and whatever
/// sits next to it (menus, the main action), all in glass at the shared height.
struct InputBar<Trailing: View>: View {
    let symbol: String
    let prompt: Text
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GlassGroup(spacing: Design.Spacing.controls) {
            HStack(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Image(systemName: symbol)
                        .font(.system(size: Design.Size.icon - 2, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(text: $text, prompt: prompt) { prompt }
                        .textFieldStyle(.plain)
                        .font(Design.Typography.control)
                        .onSubmit(onSubmit)
                }
                .barControl()
                trailing
            }
        }
    }
}

/// A list row with the download rows' look: an icon tile, a title, a line under it, optional
/// extra content (a progress bar), and actions on the right.
struct ItemRow<Detail: View, Actions: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: Text
    var subtitle: Text?
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: Design.Size.icon, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title.fontWeight(.semibold).lineLimit(1)
                if let subtitle { subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                detail
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(.fill.quaternary)
                .opacity(0.6)
        }
    }
}

/// One setting inside a card: its name on the left, its control (a menu, a field, a switch) on
/// the right, like a row of the main window's options.
struct CardField<Control: View>: View {
    let label: Text
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            label
            Spacer(minLength: 12)
            control.labelsHidden()
        }
    }
}

/// What went wrong, in one calm line: an orange triangle and a sentence.
struct ProblemLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A finished result: a green check, what was made, and a way to show it.
struct DoneLabel: View {
    let text: Text
    var file: URL?

    var body: some View {
        HStack(spacing: Design.Spacing.controls) {
            Label { text } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if let file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// A choice as a capsule bar control, like the main window's format menu: a symbol, what's
/// chosen and a small chevron; the options open as a menu.
struct BarPicker<Value: Hashable, Options: View>: View {
    let symbol: String
    let label: Text
    @Binding var selection: Value
    let current: Text
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { label }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: Design.Size.icon - 2, weight: .medium))
                    .accessibilityHidden(true)
                current.lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(Design.Typography.control)
            .foregroundStyle(.primary)
            .barControl()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The file a tool works on, as a capsule bar control (or what to do when there's none yet).
struct FileCapsule: View {
    let file: URL?
    var symbol = "doc"
    var placeholder: Text = Text("No file chosen")

    var body: some View {
        Label {
            if let file { Text(file.lastPathComponent) } else { placeholder.foregroundStyle(.secondary) }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(Design.Typography.control)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .barControl()
        .help(file.map { Text($0.path) } ?? placeholder)
    }
}

/// Where a tool takes a file before it has one: a dashed card that lights up while a file is
/// dragged over it. The window itself takes the drop.
struct DropZone: View {
    var symbol = "square.and.arrow.down"
    let text: Text
    var targeted = false
    var busy = false

    var body: some View {
        VStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            text
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
        }
        .padding(Design.Spacing.window)
        .frame(maxWidth: .infinity, minHeight: 160)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .animation(.snappy(duration: 0.15), value: targeted)
    }
}

/// A pane of a workspace window (a list of clips, a transcript): the card fill around it,
/// edge to edge, so it scrolls inside its card.
struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .fill(.fill.quaternary)
                    .opacity(0.6)
            }
            .clipShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
    }
}

/// A search field at the top of a pane: a magnifying glass and a plain field, a line under it.
struct PaneSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(prompt, text: $text).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
        }
    }
}


/// The main action in Pluck Studio's colours: a gradient capsule that lifts a little under the
/// pointer.
struct BrandButtonStyle: ButtonStyle {
    var large = true

    func makeBody(configuration: Configuration) -> some View {
        BrandButton(configuration: configuration, large: large)
    }

    private struct BrandButton: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
                .labelStyle(BrandLabelStyle())
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 22 : 14)
                .frame(minHeight: large ? 38 : 30)
                .background(Capsule().fill(Edition.isStudio ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.accentColor)))
                .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.15 : hovering ? 0.08 : 0)))
                .shadow(color: (Edition.isStudio ? Design.Brand.violet : Color.accentColor).opacity(isEnabled && hovering ? 0.45 : 0.2), radius: hovering ? 10 : 5, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.snappy(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A divider to drag, to make a side panel wider or narrower.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the window the panel is on (dragging right widens a leading panel).
    let edge: HorizontalEdge
    @State private var start: Double?

    var body: some View {
        Group {
            if Edition.isStudio { Color.clear.frame(width: Design.Studio.panelGap) } else { Divider() }
        }
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // (Measured in the window: the handle itself moves with the drag, which made it jump.)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if start == nil { start = width }
                            let delta = Double(value.translation.width) * (edge == .leading ? 1 : -1)
                            width = min(max((start ?? width) + delta, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityHidden(true)
    }
}

/// The symbol and words of a main button, with room between them.
struct BrandLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
            configuration.title
        }
    }
}

/// A soft glow in Pluck's colours behind a page's top. Still on purpose: a moving blur this
/// size kept the Mac busy the whole time the page was open.
struct BrandGlow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Warm at the top, fading through the page: pink and violet from the icon.
            ZStack {
                glow(Design.Brand.pink, size.width * 0.6, x: size.width * 0.22, y: size.height * 0.05)
                glow(Design.Brand.violet, size.width * 0.65, x: size.width * 0.8, y: size.height * 0.02)
                glow(Design.Brand.violet, size.width * 0.55, x: size.width * 0.15, y: size.height * 0.85, strength: 0.45)
                glow(Design.Brand.pink, size.width * 0.5, x: size.width * 0.85, y: size.height * 0.95, strength: 0.4)
            }
            .frame(width: size.width, height: size.height)
            .blur(radius: 120)
            .opacity(colorScheme == .dark ? 0.34 : 0.2)
            .drawingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, _ diameter: CGFloat, x: CGFloat, y: CGFloat, strength: Double = 1) -> some View {
        Circle().fill(color.opacity(strength)).frame(width: diameter, height: diameter).position(x: x, y: y)
    }
}

/// A divider dragged up or down to give the panel under it more height (the timeline).
struct HeightHandle: View {
    @Binding var grow: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Group {
            if Edition.isStudio { Color.clear.frame(height: Design.Studio.panelGap) } else { Divider() }
        }
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    // (Measured in the window: the handle itself moves with the drag, which made it jump.)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if start == nil { start = grow }
                            grow = min(max((start ?? grow) - Double(value.translation.height), range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityHidden(true)
    }
}

/// The Edit page's media panel, handed to the open project or file, which puts it beside its
/// viewer (so the timeline can run the whole width under both).
private struct EditMediaKey: EnvironmentKey {
    static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    var editMedia: AnyView? {
        get { self[EditMediaKey.self] }
        set { self[EditMediaKey.self] = newValue }
    }
}

/// An inspector's tabs: a row of symbols, the chosen one in Pluck's colours (as the page bar).
struct InspectorTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let symbol: (Tab) -> String
    let title: (Tab) -> Text

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { item in
                let on = selection == item
                Button { selection = item } label: {
                    // Studio: the chosen tab filled deep plum with a white symbol (layout reference).
                    Image(systemName: symbol(item))
                        .font(.system(size: Design.Size.icon - 3, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? (Edition.isStudio ? AnyShapeStyle(Color.white) : Design.Brand.chosen)
                                            : AnyShapeStyle(Edition.isStudio ? AnyShapeStyle(Design.Studio.textQuiet) : AnyShapeStyle(.secondary)))
                        .frame(width: Edition.isStudio ? 28 : nil, height: 28)
                        .frame(maxWidth: .infinity)
                        .background {
                            if Edition.isStudio {
                                RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous).fill(on ? AnyShapeStyle(Design.Brand.deep) : AnyShapeStyle(Color.clear))
                                    .frame(width: 28, height: 28)
                            } else {
                                RoundedRectangle(cornerRadius: Design.Radius.small).fill(on ? Color.primary.opacity(0.08) : .clear)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(title(item))
                .accessibilityLabel(title(item))
            }
        }
        .padding(6)
    }
}

// MARK: - Pluck Studio pieces (brandbook v1)

/// A few choices side by side, the chosen one on a raised grey (not plum: plum is for what's
/// selected in the work, not for a view filter). Render 2/4 of the 2026-11-12 layout.
struct StudioSegmented<Value: Hashable>: View {
    /// The box's colour: darker than a panel it sits on, lighter than the backdrop in the title row.
    var ground = Design.Studio.backdrop
    let options: [(value: Value, title: LocalizedStringKey)]
    @Binding var selection: Value
    /// Symbols shown instead of the titles (the titles become the help and what VoiceOver says).
    var symbols: [String] = []
    /// Across the whole width, the parts equally wide (a panel's switch); otherwise each as wide as its title.
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if index < symbols.count { Image(systemName: symbols[index]).font(.system(size: 11)) } else { Text(option.title) }
                    }
                        .font(Design.Studio.body)
                        .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                        .lineLimit(1)
                        .minimumScaleFactor(fill ? 0.85 : 1)
                        // (Filling a narrow panel: less room round each title, so three fit.)
                        .padding(.horizontal, fill ? 4 : 10)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 24)
                        .background(on ? Design.Studio.line : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(index < symbols.count ? Text(option.title) : Text(verbatim: ""))
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ground, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// A raised grey button with a label and a small chevron, for menus in a header ("Date added ⌄").
struct StudioMenuLabel: View {
    let title: String
    /// Quiet: grey text, no button behind it (inside a field).
    var quiet = false

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: title)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
        }
        .font(Design.Studio.body)
        .foregroundStyle(quiet ? Design.Studio.textQuiet : Design.Studio.text)
        .padding(.horizontal, 10)
        .frame(height: quiet ? 32 : 28)
        .background(quiet ? Color.clear : Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .contentShape(.rect)
    }
}

/// Pluck Studio's mark (logo-master/pluck-studio-icon-final.svg), drawn: a split tile, a plum line and ring forming a p.
struct StudioMark: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 130
            let plum = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Design.rgb(0x8E4C64), Design.rgb(0x533C88)]),
                startPoint: CGPoint(x: 20 * s, y: 10 * s), endPoint: CGPoint(x: 110 * s, y: 120 * s))
            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 130 * s, height: 130 * s), cornerRadius: 30 * s, style: .continuous)
            context.fill(tile, with: .color(Design.rgb(0x121016)))
            context.clip(to: tile)
            context.fill(Path(CGRect(x: 0, y: 0, width: 47 * s, height: 130 * s)), with: .color(Design.rgb(0x27212F)))
            context.fill(Path(CGRect(x: 42.5 * s, y: 0, width: 9 * s, height: 130 * s)), with: plum)
            let ring = Path(ellipseIn: CGRect(x: 47 * s, y: 29 * s, width: 42 * s, height: 42 * s))
            context.fill(ring, with: .color(Design.rgb(0x121016)))
            context.stroke(ring, with: plum, lineWidth: 9 * s)
        }
        .accessibilityHidden(true)
    }
}

/// Studio's search field in the title bar: a dark box, a magnifier, the hint, and its key on the right.
struct StudioSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var key = "⌘F"
    var focused: FocusState<Bool>.Binding
    /// Offered under the field while it's empty (recent searches).
    var suggestions: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(Design.Studio.textQuiet)) { Text(prompt) }
                .textFieldStyle(.plain)
                .font(Design.Studio.body)
                .focused(focused)
                .modifier(InputSuggestions(items: text.isEmpty ? suggestions : []))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Design.Studio.textQuiet) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            } else {
                Text(verbatim: key).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 354, height: 28)
        .background(Design.Studio.panel, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }
}

/// Completions offered under a text field (macOS 15 and later).
private struct InputSuggestions: ViewModifier {
    let items: [String]

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.textInputSuggestions {
                ForEach(items, id: \.self) { Label($0, systemImage: "clock.arrow.circlepath").textInputCompletion($0) }
            }
        } else { content }
    }
}

/// A small Studio slider: a thin grey track, the part up to the dot a little lighter, a white dot.
struct StudioSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// What VoiceOver calls it.
    var label: LocalizedStringKey = "Size"

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let x = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Studio.line).frame(height: Design.Studio.sliderTrack)
                Capsule().fill(Design.Studio.text.opacity(0.35)).frame(width: x, height: Design.Studio.sliderTrack)
                Circle().fill(Design.Studio.text).frame(width: Design.Studio.sliderDot, height: Design.Studio.sliderDot)
                    .offset(x: x - Design.Studio.sliderDot / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let share = min(max(drag.location.x / width, 0), 1)
                value = range.lowerBound + Double(share) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: "\(Int(((value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne) * 100).rounded())) %"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// Pluck Studio's on/off switch: a small pill, deep plum when on, a white knob (no system glass).
struct StudioSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // (Just the switch: its name is the row's own text, so it isn't said twice.)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 0) {
                // The name stays for VoiceOver, unseen.
                configuration.label.frame(width: 0, height: 0).clipped().opacity(0)
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Design.Brand.deep) : AnyShapeStyle(Design.Studio.line))
                    .frame(width: 28, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Design.Studio.text).frame(width: 12, height: 12).padding(2)
                    }
                    .animation(.snappy(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}
