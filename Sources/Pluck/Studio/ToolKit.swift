import SwiftUI

// Pieces the Studio tool screens share (layout boards 6a–6h on the 2026-11-12 canvas).

extension View {
    /// A floating Studio panel: panel grey, rounded, on the backdrop.
    func studioPanel() -> some View {
        background(Design.Studio.panel, in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
            .clipShape(.rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
    }

    /// A box inside a panel (a job, a card, a list item): backdrop-dark, rounded.
    func studioBox(outline: Color? = nil) -> some View {
        background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
            .overlay {
                if let outline {
                    RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous).strokeBorder(outline, lineWidth: 1)
                }
            }
    }
}

/// A thin progress bar, plum up to `share` (0…1).
struct StudioProgress: View {
    let share: Double
    var tint: AnyShapeStyle = AnyShapeStyle(Design.Brand.gradient)

    var body: some View {
        Capsule().fill(Design.Studio.line).frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(tint).frame(width: geometry.size.width * min(max(share, 0), 1), height: 3)
                }
            }
            .animation(.smooth, value: share)
            .accessibilityElement()
            .accessibilityValue(Text(share, format: .percent.precision(.fractionLength(0))))
    }
}

/// A small rounded label: "Safe to format", "Medium", a score.
struct StudioChip: View {
    let text: Text
    var symbol: String?
    var colour = Design.Studio.textQuiet
    /// A light tint of the colour behind it, else the raised grey.
    var tinted = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            text
        }
        .font(Design.Studio.hint)
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(tinted ? AnyShapeStyle(colour.opacity(0.12)) : AnyShapeStyle(Design.Studio.raised), in: .capsule)
    }
}

/// An inspector row: a quiet 84 pt label on the left, the control on the right.
struct StudioField<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).frame(width: 84, alignment: .leading)
            HStack(spacing: 6) { Spacer(minLength: 0); control }
        }
        .frame(minHeight: 34)
    }
}

/// A switch with its name on the right ("Eject when done"), as on the boards.
struct StudioSwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: $isOn).toggleStyle(StudioSwitchStyle())
            Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
        }
        .frame(height: 28)
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
    }
}

/// A dashed "add" tile: "Add a drive…", "Folder…".
struct StudioDashedButton: View {
    let title: LocalizedStringKey
    var symbol = "plus"
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.textQuiet)
            .padding(.horizontal, 14)
            .frame(height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Design.Studio.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A 40 pt raised tile with a symbol: the start of a job or result row.
struct StudioTile: View {
    let symbol: String
    var colour = Design.Studio.text
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4))
            .foregroundStyle(colour)
            .frame(width: size, height: size)
            .background(Design.Studio.raised, in: .rect(cornerRadius: size / 4, style: .continuous))
    }
}

/// "Runs on this Mac" and the like, faint and centred at a panel's foot.
struct StudioFootnote: View {
    let text: LocalizedStringKey
    var symbol = "lock.shield"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Design.Studio.hint)
            .foregroundStyle(Design.Studio.textFaint)
            .frame(maxWidth: .infinity)
    }
}

/// A tool's empty work area, the same in every tool: its symbol on a tile, what to do in one line, and a button.
struct StudioEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var line: LocalizedStringKey?
    /// Pink while something is dragged over it.
    var targeted = false
    /// The button as the page's main action (plum).
    var prominent = false
    var button: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            StudioTile(symbol: symbol, colour: targeted ? Design.Brand.pink : Design.Studio.textQuiet)
                .padding(.bottom, 4)
            Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            if let line {
                Text(line).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let button, let action {
                Button(button, action: action).buttonStyle(StudioFlatButtonStyle(prominent: prominent)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// A dashed drop area around an empty state; plum while a file is dragged over it.
    func studioDropZone(targeted: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
                .strokeBorder(targeted ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Design.Studio.line),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [4, 3]))
        }
        .contentShape(.rect)
    }
}

extension View {
    /// The tool's name before its top bar, so every tool screen says what it is (as the other pages' headers do).
    func studioToolTitle(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 20) {
            Text(title).font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text).lineLimit(1).fixedSize()
            self
        }
    }
}

/// A small plum arc going round: work under way with no share to show (every tool's spinner).
struct PlumSpinner: View {
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Design.Studio.line, lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(Design.Brand.pink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 11, height: 11)
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true } }
        .accessibilityLabel(Text("Working"))
    }
}
