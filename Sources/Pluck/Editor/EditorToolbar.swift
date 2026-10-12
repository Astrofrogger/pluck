import SwiftUI

/// The toolbar above the Editor's timeline, like an editing program's: the tools (selection and
/// blade), cutting and taking out, in and out, snapping and looping, and the zoom.
struct EditorToolbar: View {
    @Bindable var model: EditorModel
    @Binding var zoom: Double

    var body: some View {
        HStack(spacing: 2) {
            // The tools: what a click on the timeline does. One is always on.
            HStack(spacing: 0) {
                ToolButton(symbol: "cursorarrow", label: "Selection tool: click a part to select it (A)", on: model.tool == .select) { model.tool = .select }
                ToolButton(symbol: "scissors", label: "Blade tool: click the timeline to cut there (B)", on: model.tool == .blade) { model.tool = .blade }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.black.opacity(0.25)))
            divider
            ToolButton(symbol: "square.split.1x2", title: "Split", label: "Split at the Playhead (⌘B)") { model.cut(at: model.time) }
            ToolButton(symbol: "trash", label: "Take Out the Selected Parts (⌫)") { model.removeSelected() }
                .disabled(model.selected.isEmpty)
            ToolButton(symbol: "arrow.uturn.backward", label: "Undo (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            divider
            ToolButton(symbol: "arrow.right.to.line", label: "Mark In at the Playhead (I)") { model.markIn() }
            ToolButton(symbol: "arrow.left.to.line", label: "Mark Out at the Playhead (O)") { model.markOut() }
            ToolButton(symbol: "xmark.circle", label: "Clear In and Out (⌥X)") { model.clearRange() }
                .disabled(!model.hasRange)
            divider
            ToolButton(symbol: "point.forward.to.point.capsulepath", label: "Snapping (N)", on: model.snapping) { model.snapping.toggle() }
            ToolButton(symbol: "repeat", label: "Loop the Range", on: model.loop) { model.loop.toggle() }
            if model.hasVideo {
                divider
                ToolButton(symbol: "camera", label: "Save the Frame at the Playhead as a Picture") { model.saveFrame() }
            }
            Spacer(minLength: 4)
            Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(get: { log(zoom) }, set: { zoom = exp($0) }), in: 0...log(maxZoom))
                .controlSize(.mini)
                .frame(minWidth: 50, maxWidth: 110)
                .help("Zoom the timeline (⌥ and scroll, or ⌘+ and ⌘−)")
                .accessibilityLabel(Text("Zoom"))
            Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.fill.quaternary))
    }

    private var maxZoom: Double { max(1.01, min(model.duration / 2, 200)) }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }
}

/// A small square tool button: lit while its tool or option is on.
private struct ToolButton: View {
    let symbol: String
    /// A word next to the symbol, for actions that need saying.
    var title: LocalizedStringKey?
    let label: LocalizedStringKey
    var on = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if let title { Text(title).font(.caption.weight(.medium)) }
            }
                .foregroundStyle(on ? Color.accentColor : .primary)
                .padding(.horizontal, title == nil ? 0 : 6)
                .frame(minWidth: 28, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small)
                    .fill(on ? Color.accentColor.opacity(0.18) : hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}
