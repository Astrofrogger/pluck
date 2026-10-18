import SwiftUI

/// An update being installed: what's coming, how far the download is, and then checking,
/// installing and relaunching. Cancel stops the download.
struct UpdateBar: View {
    @Environment(AppUpdater.self) private var updater
    /// On its own, as a card (else inside a row, as in Settings).
    var card = true

    var body: some View {
        HStack(spacing: 12) {
            if card {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(updater.forQuit ? "Getting \(updater.installing ?? Edition.name) ready" : "Installing \(updater.installing ?? Edition.name)")
                        .font(card ? .headline : .callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(step).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let fraction = updater.downloaded {
                    ProgressView(value: fraction).tint(Design.Brand.violet)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Design.Brand.violet)
                }
            }
            if updater.step == .downloading {
                Button("Cancel") { updater.cancelInstall() }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .help("Stops the download; what came in so far is kept for the next try")
            }
        }
        .padding(card ? 12 : 0)
        .background {
            if card { RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(.regularMaterial) }
        }
        .overlay {
            if card { RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        }
        .accessibilityElement(children: .combine)
    }

    private var step: String {
        switch updater.step {
        case .downloading:
            guard updater.expected > 0 else { return String(localized: "Downloading…") }
            let got = ByteCountFormatter.string(fromByteCount: updater.received, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: updater.expected, countStyle: .file)
            return String(localized: "\(got) of \(all)")
        case .checking: return String(localized: "Checking the download…")
        case .unpacking: return String(localized: "Installing…")
        case .relaunching: return String(localized: "Relaunching…")
        case nil: return ""
        }
    }
}
