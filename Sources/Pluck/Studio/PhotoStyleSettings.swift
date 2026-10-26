#if STUDIO
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Styles: the rankings the user trains from their own Lightroom picks. Pick a catalog, tick the
/// collections (shoots) to learn from, train, and optionally take the keepers' usual look.
struct PhotoStyleSettings: View {
    @State private var styles = PhotoStyles.shared
    @State private var selection: UUID?
    @State private var collections: [LightroomCatalog.Collection] = []
    @State private var loadingCollections = false
    @State private var unreadable = false
    @State private var progress: Double?
    @State private var training: Task<Void, Never>?
    @State private var failure: String?
    @State private var lookMessage: String?
    @State private var savingLook = false

    private var style: PhotoStyle? { styles.styles.first { $0.id == selection } }

    var body: some View {
        Section {
            HStack {
                Picker("Style", selection: $selection) {
                    if styles.styles.isEmpty { Text("None").tag(UUID?.none) }
                    ForEach(styles.styles) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Button("New Style", systemImage: "plus", action: add)
                    .labelStyle(.iconOnly)
                    .help("New Style")
                if let style {
                    Button("Delete", systemImage: "trash") { delete(style) }
                        .labelStyle(.iconOnly)
                        .help("Delete Style")
                        .disabled(progress != nil)
                }
            }
            if let style {
                TextField("Name", text: binding(\.name, of: style))
                catalogRow(style)
                collectionsList(style)
                trainRow(style)
                if style.trained != nil, progress == nil { result(style) }
            }
        } header: {
            Text("Styles")
        } footer: {
            Text("A style learns which photos of a moment you keep, from collections in Lightroom. Moments rank with it on the Photo page. Nothing in Lightroom is changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            if selection == nil { selection = styles.chosen ?? styles.styles.first?.id }
        }
        .task(id: style?.catalog) { await loadCollections() }
        .onDisappear { training?.cancel() }
    }

    // MARK: Rows

    private func catalogRow(_ style: PhotoStyle) -> some View {
        LabeledContent("Catalog") {
            HStack {
                let known = LightroomCatalog.defaultCatalogs()
                if known.count > 1 {
                    Picker("Catalog", selection: catalogBinding(style)) {
                        ForEach(known, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag($0) }
                        if !known.contains(style.catalog) { Text(style.catalog.deletingPathExtension().lastPathComponent).tag(style.catalog) }
                    }
                    .labelsHidden()
                } else if hasCatalog(style) {
                    Text(style.catalog.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("No catalog").foregroundStyle(.secondary)
                }
                Button("Choose…") { chooseCatalog(style) }
            }
        }
        .disabled(progress != nil)
    }

    @ViewBuilder
    private func collectionsList(_ style: PhotoStyle) -> some View {
        if unreadable {
            Label("Pluck can’t open this catalog. Is it still where it was?", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else if loadingCollections {
            HStack { ProgressView().controlSize(.small); Text("Reading catalog…").foregroundStyle(.secondary) }
        } else if hasCatalog(style) {
            if collections.isEmpty {
                Text("No collections with kept photos in this catalog.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Collections") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Design.Spacing.controls / 2) {
                            ForEach(collections) { collection in
                                Toggle(isOn: includeBinding(collection.id, in: style)) {
                                    HStack {
                                        Text(collection.name).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(collection.photos) photos · \(collection.keepers) kept")
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .disabled(progress != nil)
            }
        }
    }

    private func trainRow(_ style: PhotoStyle) -> some View {
        HStack {
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 220)
                Button("Cancel") { training?.cancel() }
            } else {
                Button("Train") { train(style) }
                    .disabled(style.collections.isEmpty || !hasCatalog(style))
                Button("Use Look") { useLook(style) }
                    .disabled(style.trained == nil || savingLook)
                    .help("Save the usual look of your keepers as a look you can apply")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func result(_ style: PhotoStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary(style))
            if style.skipped > 0 { Text("Skipped \(style.skipped) without a preview") }
        }
        .font(.callout).foregroundStyle(.secondary)
        if let lookMessage { Text(lookMessage).font(.callout).foregroundStyle(.secondary) }
        if let failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
    }

    /// "About 6 in 10 of your keepers on top · 31 % of photos shown · measured on 4 of your shoots".
    private func summary(_ style: PhotoStyle) -> String {
        guard let covered = style.covered, let shown = style.shown else {
            return String(localized: "Couldn’t be measured with one shoot. Pick more shoots to see how well it works.")
        }
        let parts = [
            String(localized: "About \(Int((covered * 10).rounded())) in 10 of your keepers on top"),
            String(localized: "\(Int((shown * 100).rounded())) % of photos shown"),
            String(localized: "measured on \(style.collections.count) of your shoots"),
        ]
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func add() {
        let catalog = LightroomCatalog.defaultCatalogs().first ?? URL(fileURLWithPath: "/")
        let new = PhotoStyle(name: String(localized: "New Style"), catalog: catalog, collections: [])
        styles.update(new)
        selection = new.id
        failure = nil
        lookMessage = nil
    }

    private func delete(_ style: PhotoStyle) {
        styles.remove(style)
        selection = styles.styles.first?.id
        failure = nil
        lookMessage = nil
    }

    private func chooseCatalog(_ style: PhotoStyle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrcat")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a Lightroom catalog")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCatalog(url, for: style)
    }

    private func setCatalog(_ url: URL, for style: PhotoStyle) {
        guard var current = self.style, current.id == style.id, current.catalog != url else { return }
        current.catalog = url
        current.collections = []
        current.trained = nil
        current.covered = nil
        current.shown = nil
        styles.update(current)
    }

    private func hasCatalog(_ style: PhotoStyle) -> Bool {
        style.catalog.pathExtension == "lrcat" && FileManager.default.fileExists(atPath: style.catalog.path)
    }

    /// Reads the collections off the main thread: a big catalog takes a while.
    private func loadCollections() async {
        collections = []
        unreadable = false
        guard let style, hasCatalog(style) else { return }
        loadingCollections = true
        let url = style.catalog
        let found = await Task.detached(priority: .userInitiated) { () -> [LightroomCatalog.Collection]? in
            guard let catalog = try? LightroomCatalog(url: url) else { return nil }
            return catalog.collections()
        }.value
        guard !Task.isCancelled else { return }
        loadingCollections = false
        if let found { collections = found } else { unreadable = true }
    }

    private func train(_ style: PhotoStyle) {
        failure = nil
        lookMessage = nil
        progress = 0
        let id = style.id
        training = Task {
            do {
                let trained = try await PhotoStyleTrainer.train(style) { value in
                    Task { @MainActor in if progress != nil { progress = value } }
                }
                // The style may have been deleted or edited meanwhile; keep the user's latest choices.
                if var latest = styles.styles.first(where: { $0.id == id }) {
                    latest.trained = trained.trained
                    latest.photos = trained.photos
                    latest.skipped = trained.skipped
                    latest.covered = trained.covered
                    latest.shown = trained.shown
                    styles.update(latest)
                }
            } catch is CancellationError {
            } catch PhotoStyleTrainer.Failure.catalogUnreadable {
                failure = String(localized: "Pluck can’t open this catalog. Is it still where it was?")
            } catch PhotoStyleTrainer.Failure.needsKeepersAndDrops {
                failure = String(localized: "Pick shoots with both photos you kept and photos you didn’t.")
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
            training = nil
        }
    }

    private func useLook(_ style: PhotoStyle) {
        guard !savingLook else { return }
        savingLook = true
        lookMessage = nil
        Task {
            let saved = await styles.saveLook(for: style)
            lookMessage = saved
                ? String(localized: "Saved as a look named “\(style.name)”.")
                : String(localized: "Your keepers in these shoots have no Lightroom edits to take a look from.")
            savingLook = false
        }
    }

    // MARK: Bindings

    private func binding<T>(_ path: WritableKeyPath<PhotoStyle, T>, of style: PhotoStyle) -> Binding<T> {
        Binding {
            self.style?[keyPath: path] ?? style[keyPath: path]
        } set: { value in
            guard var current = self.style else { return }
            current[keyPath: path] = value
            styles.update(current)
        }
    }

    private func catalogBinding(_ style: PhotoStyle) -> Binding<URL> {
        Binding { self.style?.catalog ?? style.catalog } set: { setCatalog($0, for: style) }
    }

    private func includeBinding(_ id: Int, in style: PhotoStyle) -> Binding<Bool> {
        Binding {
            self.style?.collections.contains(id) ?? false
        } set: { on in
            guard var current = self.style else { return }
            current.collections.removeAll { $0 == id }
            if on { current.collections.append(id) }
            styles.update(current)
        }
    }
}
#endif
