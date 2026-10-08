import SwiftUI

enum SupportLinks {
    static let buyMeACoffee: URL? = URL(string: "https://buymeacoffee.com/astrofrogger")
    static let gitHub = URL(string: "https://github.com/Astrofrogger/pluck")!
}

/// The Support tab: an optional coffee, or a GitHub star.
struct SupportSettings: View {
    @Environment(\.openURL) private var openURL

    /// Pluck's app icon gradient.
    private let brand = LinearGradient(
        colors: [Color(red: 1.00, green: 0.36, blue: 0.42), Color(red: 0.93, green: 0.13, blue: 0.36),
                 Color(red: 0.55, green: 0.10, blue: 0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(brand, in: .circle)
                    .shadow(color: Color(red: 0.93, green: 0.13, blue: 0.36).opacity(0.35), radius: 10, y: 4)
                    .accessibilityHidden(true)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    Text("Help Pluck keep growing")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Pluck is free, independent and built in my spare time. If you’d like to chip in, a coffee directly helps me keep improving it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)

                Button {
                    if let url = SupportLinks.buyMeACoffee { openURL(url) }
                } label: {
                    Label("Support on Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .glassProminentButtonStyle()
                .help(SupportLinks.buyMeACoffee?.absoluteString ?? String(localized: "Buy Me a Coffee link not set up yet"))

                starCard

                Text("Thank you for using Pluck. \u{2665}\u{FE0E}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var starCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
                .frame(width: 40, height: 40)
                .background(.yellow.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Money is never expected. A star on GitHub helps more people discover Pluck and makes a real difference too.")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openURL(SupportLinks.gitHub)
                } label: {
                    Label("Star Pluck on GitHub", systemImage: "star")
                }
                .glassButtonStyle()
                .help(SupportLinks.gitHub.absoluteString)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.fill.quaternary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}
