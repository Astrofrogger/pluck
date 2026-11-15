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
            // As in the reference: the tabs, then + to add media. Moving or hiding the panel: right-click,
            // or ⌥⌘P and ⌥⌘L.
            HStack(spacing: 4) {
                InspectorTabBar(tabs: EditLibraryTab.allCases, selection: $tab, symbol: \.symbol) { Text($0.title) }
                Button(action: addMedia) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Design.Studio.textQuiet)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Add media")
                .padding(.trailing, 6)
            }
            .frame(height: 44)
            .contextMenu {
                Picker("Panel", selection: $position) {
                    ForEach(EditPanelPosition.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Hide the Panel (⌥⌘L)") { withAnimation(.snappy) { shown = false } }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // (The page draws the panel's grey around it.)
    }

    private func addMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let files = panel.urls
        Task { await model.add(files) }
        AppDelegate.shared?.ai.imported(files)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .media: ProjectMediaList(model: model, audioOnly: false)
        case .music: ProjectMediaList(model: model, audioOnly: true)
        case .transitions: EditLibraryList(model: model, kind: .transitions)
        case .titles: EditLibraryList(model: model, kind: .titles)
        case .effects: EditLibraryList(model: model, kind: .effects)
        case .assets: AssetLibraryView(model: model)
        }
    }
}
