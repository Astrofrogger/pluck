import SwiftUI

/// Pluck's design tokens: the sizes, spacing and shapes controls share, so a text field, a menu
/// and buttons that sit side by side line up exactly. Use these instead of numbers in views.
enum Design {
    /// Pluck's own colours, from the app icon: a warm pink running into violet. Used sparingly,
    /// for what's chosen and the main action, so it keeps meaning something.
    /// Around photos being judged: a neutral grey (coloured or very dark surroundings shift how
    /// colour and brightness are seen).
    enum Photo {
        static let surroundWhite: CGFloat = 0.16
        static let surround = Color(white: surroundWhite)
    }

    enum Brand {
        static let pink = Color(red: 0.99, green: 0.37, blue: 0.48)
        static let violet = Color(red: 0.56, green: 0.33, blue: 0.96)
        static let gradient = LinearGradient(colors: [pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        /// What's chosen (a tab, a tool that's on): Pluck's colours in Pluck Studio, the Mac's
        /// accent colour in basic Pluck.
        static var chosen: AnyShapeStyle { Edition.isStudio ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.accentColor) }
        static var chosenFill: AnyShapeStyle {
            Edition.isStudio ? AnyShapeStyle(gradient.opacity(0.22)) : AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
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
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
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
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
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
                    Image(systemName: symbol(item))
                        .font(.system(size: Design.Size.icon - 3, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Design.Brand.chosen : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(on ? Color.primary.opacity(0.08) : .clear))
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
