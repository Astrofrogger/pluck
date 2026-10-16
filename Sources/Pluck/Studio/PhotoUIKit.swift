import AppKit
import SwiftUI

// MARK: - Slider

/// The Photo page's slider: what it does shows in its track (colours for temperature, tint and
/// saturation), it fills from its middle when it goes both ways, and its name lights up once it's
/// changed. Double-click to reset, click the number to type one, arrow keys to nudge (Shift: more,
/// Option: less), Option while dragging to see what clips. VoiceOver reads and moves it.
struct AdjustSlider: View {
    enum Track: Equatable {
        case plain, temperature, tint, saturation
        case hues
        case colour(Color)
    }

    let title: LocalizedStringKey
    let value: Double
    let range: ClosedRange<Double>
    var neutral = 0.0
    var format = "%+.0f"
    /// Shown instead of the number (the light in Kelvin).
    var label: String?
    var track = Track.plain
    /// Option while dragging shows the clipping (the tone sliders, as in Lightroom).
    var clipping = false
    /// How far a typed number may go past the track's ends.
    var limit: ClosedRange<Double>?
    let set: (Double) -> Void

    @State private var typing = false
    @State private var typed = ""
    @State private var showedClipping: Bool?
    @FocusState private var focused: Bool
    @State private var editing = PhotoEditing.shared

    private var changed: Bool { abs(value - neutral) > 0.0001 }
    private var shown: String { label ?? String(format: format, value) }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(changed ? .primary : .secondary)
                .fontWeight(changed ? .medium : .regular)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
                .onTapGesture(count: 2) { set(neutral) }
            bar
            Text(verbatim: shown)
                .font(.caption.monospacedDigit())
                .foregroundStyle(changed ? .primary : .tertiary)
                .frame(width: label == nil ? 44 : 58, alignment: .trailing)
                .contentShape(.rect)
                .onTapGesture(count: 2) { set(neutral) }
                .onTapGesture { typed = String(format: format.replacingOccurrences(of: "+", with: ""), value); typing = true }
                .popover(isPresented: $typing, arrowEdge: .bottom) {
                    TextField("", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .padding(8)
                        .onSubmit { commit() }
                }
                .help("Click to type, double-click to reset")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            let step = (range.upperBound - range.lowerBound) / 200
            let scale = press.modifiers.contains(.shift) ? 10.0 : press.modifiers.contains(.option) ? 0.2 : 1
            switch press.key {
            case .leftArrow, .downArrow: nudge(-step * scale)
            case .rightArrow, .upArrow: nudge(step * scale)
            default: return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: shown))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 40
            nudge(direction == .increment ? step : -step)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) in CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) * width }
            let middle = x(neutral), at = x(value)
            ZStack(alignment: .leading) {
                Capsule().fill(trackFill).frame(height: 4).opacity(track == .plain ? 1 : 0.9)
                if track == .plain {
                    Capsule().fill(Color.accentColor).frame(width: abs(at - middle), height: 4).offset(x: min(at, middle))
                }
                if middle > 1, middle < width - 1 {
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 8).offset(x: middle - 0.5)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .overlay(Circle().stroke(focused ? Color.accentColor : .clear, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .offset(x: at - 6.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if showedClipping == nil {
                        showedClipping = editing.showClipping
                        if clipping, NSEvent.modifierFlags.contains(.option) { editing.showClipping = true }
                        focused = true
                    }
                    let share = min(max(drag.location.x / width, 0), 1)
                    var new = range.lowerBound + Double(share) * span
                    // A little pull towards the middle, so it's easy to land on.
                    if abs(new - neutral) < span * 0.012 { new = neutral }
                    set(new)
                }
                .onEnded { _ in
                    if let before = showedClipping { editing.showClipping = before }
                    showedClipping = nil
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { set(neutral) })
        }
        .frame(height: 18)
    }

    private var trackFill: AnyShapeStyle {
        switch track {
        case .plain: AnyShapeStyle(Color.primary.opacity(0.14))
        case .temperature: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 1), Color(white: 0.75), Color(red: 1, green: 0.78, blue: 0.3)],
                                                        startPoint: .leading, endPoint: .trailing))
        case .tint: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.3, green: 0.8, blue: 0.35), Color(white: 0.75), Color(red: 0.9, green: 0.35, blue: 0.85)],
                                                 startPoint: .leading, endPoint: .trailing))
        case .saturation: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.55), Color(red: 1, green: 0.3, blue: 0.4), Color(red: 1, green: 0.75, blue: 0.2),
                                                                Color(red: 0.25, green: 0.75, blue: 0.45), Color(red: 0.25, green: 0.5, blue: 1)],
                                                       startPoint: .leading, endPoint: .trailing))
        case .hues: AnyShapeStyle(LinearGradient(colors: stride(from: 0.0, through: 1, by: 1 / 8).map { Color(hue: $0, saturation: 0.7, brightness: 0.95) },
                                                 startPoint: .leading, endPoint: .trailing))
        case .colour(let colour): AnyShapeStyle(LinearGradient(colors: [Color(white: 0.55), colour], startPoint: .leading, endPoint: .trailing))
        }
    }

    private func nudge(_ amount: Double) {
        let bounds = limit ?? range
        set(min(max(value + amount, bounds.lowerBound), bounds.upperBound))
    }

    private func commit() {
        typing = false
        let cleaned = typed.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-+".contains($0) }
        guard let number = Double(cleaned) else { return }
        let bounds = limit ?? range
        set(min(max(number, bounds.lowerBound), bounds.upperBound))
    }
}

// MARK: - Sections

/// The Adjust panel's sections, each with what it holds (to show it's edited, to peek at the photo
/// without it, and to reset it).
enum AdjustSection: String, CaseIterable {
    case light, colour, presence, mixer, curves, wheels, detail

    func isEdited(_ a: PhotoAdjustments) -> Bool {
        var plain = a
        reset(&plain)
        return plain != a
    }

    func reset(_ a: inout PhotoAdjustments) {
        let fresh = PhotoAdjustments()
        switch self {
        case .light:
            a.exposure = 0; a.contrast = 0; a.highlights = 0; a.shadows = 0; a.whites = 0; a.blacks = 0
        case .colour:
            a.temperature = 0; a.tint = 0; a.vibrance = 0; a.saturation = 0
        case .presence:
            a.texture = 0; a.clarity = 0; a.dehaze = 0; a.vignette = 0
        case .mixer:
            a.mixer = fresh.mixer
        case .curves:
            a.curves = fresh.curves
        case .wheels:
            a.wheels = fresh.wheels
        case .detail:
            a.sharpen = 0; a.noise = 0; a.moire = 0
        }
    }
}

/// A section of the Adjust panel: its name, a dot when something in it is changed, an eye to
/// hold for the photo without it, and a reset (while the pointer is over it). Opens and closes.
struct AdjustFold<Content: View>: View {
    let title: LocalizedStringKey
    let section: AdjustSection
    let adjust: PhotoAdjustments
    let reset: () -> Void
    @ViewBuilder var content: Content
    @AppStorage private var isOpen: Bool
    @State private var hovering = false
    @State private var editing = PhotoEditing.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: LocalizedStringKey, section: AdjustSection, adjust: PhotoAdjustments, open: Bool = false, reset: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.section = section
        self.adjust = adjust
        self.reset = reset
        self.content = content()
        _isOpen = AppStorage(wrappedValue: open, "fold-" + section.rawValue)
    }

    var body: some View {
        let edited = section.isEdited(adjust)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button {
                    if reduceMotion { isOpen.toggle() } else { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(title).font(.caption.weight(.semibold)).textCase(.uppercase)
                            .foregroundStyle(edited ? .primary : .secondary)
                        if edited { Circle().fill(Color.accentColor).frame(width: 5, height: 5).accessibilityHidden(true) }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(edited ? "Changed" : "Not changed"))
                .accessibilityHint(Text(isOpen ? "Closes the section" : "Opens the section"))
                if edited, hovering || editing.peek == section {
                    Image(systemName: editing.peek == section ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { pressing in
                            editing.peek = pressing ? section : nil
                        })
                        .help("Hold to see the photo without this")
                        .accessibilityLabel(Text("Hold to see the photo without this"))
                    Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reset this section")
                        .accessibilityLabel(Text("Reset this section"))
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .onHover { hovering = $0 }
            if isOpen { content }
        }
    }
}

// MARK: - Looks

/// Looks: the profiles and your presets as small pictures of this photo. Point at one to see it
/// on the big photo, click to use it.
struct PhotoLooks: View {
    let path: String
    let record: PhotoRecord
    let apply: (PhotoRecord) -> Void
    let save: () -> Void
    @State private var catalog = PhotoCatalog.shared
    @State private var editing = PhotoEditing.shared
    @State private var pictures: [String: NSImage] = [:]

    private struct Look: Identifiable {
        let id: String
        let title: String
        let record: PhotoRecord
        var preset: UUID?
        var film = false
    }

    private var profiles: [Look] {
        let raw = PhotoRender.isRaw(path)
        return PhotoEngine.Profile.allCases.filter { raw ? $0 != .asShot : true }.map { profile in
            var r = record
            r.adjust.profile = profile
            return Look(id: "profile-" + profile.rawValue, title: profile.title, record: r)
        }
    }

    private var presets: [Look] {
        catalog.presets.map { preset in
            var r = record
            r.adjust = preset.adjust.keepingDecoder(of: record.adjust)
            r.filmOn = preset.filmOn
            r.film = preset.film
            return Look(id: preset.id.uuidString, title: preset.name, record: r, preset: preset.id, film: preset.filmOn)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Profiles", profiles)
                section("Presets", presets)
                if catalog.presets.isEmpty {
                    Text("Save a look you like to use it on other photos.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save This Look as a Preset…", systemImage: "plus", action: save).buttonStyle(.link).font(.callout)
            }
            .padding(12)
        }
        .frame(width: 340, height: 420)
        .onDisappear { editing.previewRecord = nil }
        .task(id: record) { await render() }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, _ looks: [Look]) -> some View {
        if !looks.isEmpty {
            Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(looks) { look in tile(look) }
            }
        }
    }

    private func tile(_ look: Look) -> some View {
        let current = look.record.adjust == record.adjust && look.record.filmOn == record.filmOn && look.record.film == record.film
        return Button { apply(look.record) } label: {
            VStack(spacing: 4) {
                ZStack {
                    Design.Photo.surround
                    if let picture = pictures[look.id] {
                        Image(nsImage: picture).resizable().scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if look.film { Image(systemName: "film").font(.caption2).padding(3).background(.black.opacity(0.5), in: .circle).padding(3) }
                }
                Text(look.title).font(.caption).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in editing.previewRecord = inside ? look.record : nil }
        .contextMenu {
            if let id = look.preset { Button("Delete Preset", role: .destructive) { catalog.deletePreset(id) } }
        }
        .accessibilityLabel(Text(look.title))
    }

    /// The small pictures, one after the other (the film's are shown without it: too slow).
    private func render() async {
        for look in profiles + presets where pictures[look.id] == nil {
            var shown = look.record
            shown.filmOn = false
            let path = self.path
            let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let image = PhotoRender.image(path, record: shown, maxSize: 240) else { return nil }
                return PhotoRender.picture(image, maxSize: 200)
            }.value
            if Task.isCancelled { return }
            if let made { pictures[look.id] = NSImage(cgImage: made, size: .zero) }
        }
    }
}
