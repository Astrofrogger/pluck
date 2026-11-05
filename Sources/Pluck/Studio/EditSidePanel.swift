import SwiftUI

/// The Edit page's panel beside a project: its own media, and the libraries to drag from
/// (transitions, titles, effects, music). It sits at the bottom, at the top or the full height
/// of the window, as the person likes.
struct EditSidePanel: View {
    @Bindable var model: ProjectModel
    @Binding var tab: EditLibraryTab
    @Binding var position: EditPanelPosition
    @AppStorage("studioMediaShown") private var shown = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                InspectorTabBar(tabs: EditLibraryTab.allCases, selection: $tab, symbol: \.symbol) { Text($0.title) }
                Menu {
                    Picker("Panel", selection: $position) {
                        ForEach(EditPanelPosition.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: position.next.symbol)
                } primaryAction: {
                    withAnimation(.snappy) { position = position.next }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Move the panel: bottom, top or full height (⌥⌘P). Hold for the list.")
                Button {
                    withAnimation(.snappy) { shown = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide the panel (⌥⌘L)")
                .padding(.trailing, Design.Sidebar.rowPadding)
            }
            .frame(height: Design.Size.control)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(.background.secondary)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .media: ProjectMediaList(model: model, audioOnly: false)
        case .music: ProjectMediaList(model: model, audioOnly: true)
        case .transitions: EditLibraryList(model: model, kind: .transitions)
        case .titles: EditLibraryList(model: model, kind: .titles)
        case .effects: EditLibraryList(model: model, kind: .effects)
        }
    }
}
