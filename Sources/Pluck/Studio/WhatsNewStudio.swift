import AppKit
import SwiftUI

/// What's New for Pluck Studio's own features: kept here so basic Pluck isn't built with them
/// (it would count as a change to basic Pluck). Merged into WhatsNew.releases by version.
/// Only the big features, five to seven at most; fixes go in the GitHub notes.
extension WhatsNew {
    static var studioReleases: [Release] {
        [
            Release(version: "4.0.0", items: [
                Item(symbol: "paperplane", title: String(localized: "Deliver"),
                     detail: String(localized: "Review links for clients, hosted on your Mac or NAS, with comments on the frame."),
                     image: "deliver"),
                Item(symbol: "globe.europe.africa", title: String(localized: "Edit Anywhere"),
                     detail: String(localized: "Edit in DaVinci Resolve from anywhere on proxies, and render on the Mac with the originals.")),
                Item(symbol: "checkmark.seal", title: String(localized: "Delivery Check with brand books"),
                     detail: String(localized: "Every export checked against your brand book before it goes out."),
                     image: "deliverycheck"),
                Item(symbol: "timeline.selection", title: String(localized: "New editing tools"),
                     detail: String(localized: "Sync Cameras, Fit Music, Social Cutdowns, Thumbnail Maker, keyframes and transitions."),
                     image: "edittools"),
                Item(symbol: "camera.aperture", title: String(localized: "A deeper Photo page"),
                     detail: String(localized: "AI Remove, Liquify, HDR and panorama merges, Super Resolution and Auto Cull."),
                     image: "photo"),
                Item(symbol: "macwindow", title: String(localized: "A new look"),
                     detail: String(localized: "Every page redesigned, a Finder-style Library and a new app icon."),
                     image: "newlook"),
            ]),
        ]
    }
}

/// Pluck Studio's What's New, like a pro app's update screen: a header with the version, the big
/// features as cards with a picture, and the fixes one link away.
struct StudioWhatsNewView: View {
    let releases: [WhatsNew.Release]
    let onClose: () -> Void

    private var newest: WhatsNew.Release? { releases.first }

    /// "4.0" for 4.0.0; other versions as they are.
    private var shortVersion: String {
        let parts = (newest?.version ?? "").split(separator: ".")
        return parts.count == 3 && parts[2] == "0" ? parts.prefix(2).joined(separator: ".") : newest?.version ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                    cards
                    if releases.count > 1 { earlier }
                }
                .padding(24)
            }
            bottomBar
        }
        .frame(width: 880, height: 668)
        .background(Design.Studio.backdrop.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var hero: some View {
        HStack(spacing: 20) {
            StudioMark().frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 2) {
                Text("What’s new in this version")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.Studio.textQuiet)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: Edition.name).font(.system(size: 40, weight: .semibold)).foregroundStyle(Design.Studio.text)
                    Text(verbatim: shortVersion).font(.system(size: 40, weight: .light)).foregroundStyle(Design.Brand.gradient)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background {
            ZStack {
                Design.Studio.panel
                LinearGradient(colors: [Design.Brand.pink.opacity(0.28), Design.Brand.violet.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()  // up under the see-through title bar
        }
        .overlay(alignment: .bottom) { Design.Studio.line.frame(height: 1) }
    }

    /// Three cards a row, each row as tall as its tallest card.
    private var cards: some View {
        let items = newest?.items ?? []
        return Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(items[start..<min(start + 3, items.count)]) { card($0) }
                }
            }
        }
    }

    private func card(_ item: WhatsNew.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            picture(item)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Design.Studio.text)
                Text(item.detail).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Studio.raised, in: RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous).strokeBorder(Design.Studio.line))
        .accessibilityElement(children: .combine)
    }

    /// The card's screenshot, or its symbol on a brand tile when there is none.
    private func picture(_ item: WhatsNew.Item) -> some View {
        let image = item.image
            .flatMap { Bundle.main.url(forResource: $0, withExtension: "jpg", subdirectory: "WhatsNew") }
            .flatMap(NSImage.init(contentsOf:))
        return Color.clear
            .frame(height: 124)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Design.Brand.pink.opacity(0.35), Design.Brand.violet.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: item.symbol).font(.system(size: 52, weight: .light)).foregroundStyle(Design.Studio.text)
                    }
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Design.Studio.panelRadius, topTrailingRadius: Design.Studio.panelRadius,
                                              style: .continuous))
            .accessibilityHidden(true)
    }

    /// Older versions since the one that last ran, folded away.
    private var earlier: some View {
        DisclosureGroup("Earlier versions") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(releases.dropFirst()) { release in
                    ForEach(release.items) { item in
                        Label(item.title, systemImage: item.symbol).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    }
                }
            }
            .padding(.top, 8)
        }
        .foregroundStyle(Design.Studio.text)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Design.Studio.textQuiet).accessibilityHidden(true)
            Text("Bug fixes and improvements").foregroundStyle(Design.Studio.text)
            if let newest {
                Text(verbatim: "·").foregroundStyle(Design.Studio.textFaint)
                Link("All changes on GitHub", destination: WhatsNew.releasePage(newest.version)).foregroundStyle(Design.Brand.pink)
            }
            Spacer()
            Button("Continue", action: onClose)
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Design.Studio.panel)
        .overlay(alignment: .top) { Design.Studio.line.frame(height: 1) }
    }
}
