import SwiftUI

/// Pull the originals a timeline uses: per clip its part plus handles, or whole with why, and how much that is against
/// the whole files. Opened from the Resolve pane on the editor's Mac.
struct RemotePiecesSheet: View {
    let timeline: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RemotePieces.handlesKey) private var handles = 2.0
    @State private var items: [RemotePieces.Item] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var shares: [OfficeRenderClient.RemoteShare] = []
    @State private var loading = true
    @State private var problem: String?

    private var whole: Int64 { items.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }
    private var parts: Int64 { items.reduce(0) { $0 + RemotePieces.estimate($1, size: sizes[$1.id] ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: Text("Pull originals"), subtitle: Text("Only the parts of each clip this timeline uses, plus a little extra either side.")) {
                if loading { PlumSpinner() }
            }
            StudioField(label: "Extra") {
                Stepper(value: $handles, in: 0...10, step: 1) { Text("\(Int(handles)) s either side") }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.hint).foregroundStyle(Design.Studio.bad)
            } else if !loading {
                Text(items.isEmpty ? String(localized: "None of this timeline’s clips are proxies from the office Mac.")
                     : String(localized: "\(items.count) clips · \(Self.bytes(parts)) instead of \(Self.bytes(whole))"))
                    .font(Design.Studio.body)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            HStack {
                                Text((item.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(item.whole.map { String(localized: "Whole file (\($0))") } ?? String(localized: "Range"))
                                    .foregroundStyle(item.whole == nil ? Design.Studio.textQuiet : Design.Studio.warn)
                            }
                            .font(Design.Studio.hint)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle(height: 32))
                Button("Pull") { pull() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || items.isEmpty)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .task(id: handles) { await load() }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await RemoteResolve.shared.usedParts(timeline: timeline)
            shares = try await OfficeRenderClient.shared.shares()
            for item in items where sizes[item.id] == nil {
                sizes[item.id] = (try? await OfficeRenderClient.shared.fileData(share: item.share, path: item.path, kind: .original, offset: 0, length: 1))?.size
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func pull() {
        let pulls = RemotePullManager.shared
        for share in shares {
            let mine = items.filter { $0.share == share.id }
            guard !mine.isEmpty, let root = pulls.root(for: share) else { continue }
            pulls.pullPieces(share: share, items: mine, sizes: Dictionary(mine.map { ($0.path, sizes[$0.id] ?? 0) }) { a, _ in a }, into: root)
        }
        dismiss()
    }
}
