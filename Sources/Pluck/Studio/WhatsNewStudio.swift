import AppKit
import SwiftUI

/// What's New for Pluck Studio's own features: kept here so basic Pluck isn't built with them
/// (it would count as a change to basic Pluck). Merged into WhatsNew.releases by version.
/// Only the big features, five to seven at most; fixes go in the GitHub notes.
extension WhatsNew {
    static var studioReleases: [Release] {
        [
            Release(version: "4.0.7", items: [
                Item(symbol: "envelope", title: String(localized: "Email updates and @mentions"),
                     detail: String(localized: "Clients and your team get an email about new comments; @name reaches the right person.")),
                Item(symbol: "text.bubble", title: String(localized: "Transcripts and 4K HDR copies"),
                     detail: String(localized: "Transcripts with speaker names, and 4K and HDR review copies when you want them.")),
                Item(symbol: "checkmark.circle", title: String(localized: "Your own workflow"),
                     detail: String(localized: "Your own statuses, fields and views. Green markers in Resolve complete comments.")),
                Item(symbol: "slider.horizontal.below.rectangle", title: String(localized: "Share Builder"),
                     detail: String(localized: "Build a link with a live preview of the real review page before you save it.")),
                Item(symbol: "archivebox", title: String(localized: "Archive"),
                     detail: String(localized: "Shrink old rushes into checked 1080p masters and free space on the NAS. Originals wait in a folder for you to delete.")),
                Item(symbol: "scissors", title: String(localized: "Only what you use"),
                     detail: String(localized: "Pull just the parts of the originals your edit uses, with handles.")),
                Item(symbol: "camera.on.rectangle", title: String(localized: "Sync after the offload"),
                     detail: String(localized: "Sync the cameras of an offload in one click, with bins, recorder sound and multicam angles for Resolve. RED and Blackmagic RAW included.")),
                Item(symbol: "photo.on.rectangle.angled", title: String(localized: "Photo import and client picks"),
                     detail: String(localized: "Camera clocks set right, RAW and JPEG as one, Safe to format. Share photos with a client and their picks come back.")),
                Item(symbol: "checkmark.seal", title: String(localized: "Delivered and signed off"),
                     detail: String(localized: "Masters first when a project is delivered, a sign-off sheet of every approval, and one page per client.")),
                Item(symbol: "archivebox.circle", title: String(localized: "Archive you can trust"),
                     detail: String(localized: "Hold, close and keep originals per client, an optional second copy, a searchable catalogue and Restore.")),
                Item(symbol: "rectangle.portrait.on.rectangle.portrait", title: String(localized: "Cutdowns and Shorts for Resolve"),
                     detail: String(localized: "Reframes kept, captions in the right language, ProRes, and a Resolve timeline with the reframe as keyframes. Pick each short's moment.")),
                Item(symbol: "waveform.badge.magnifyingglass", title: String(localized: "AI tools ready for Resolve"),
                     detail: String(localized: "Clean Up Audio keeps every channel, copies keep timecode, several videos at once, a blur matte, and correct a misheard word.")),
            ]),
            Release(version: "4.0.6", items: [
                Item(symbol: "folder.badge.plus", title: String(localized: "Footage straight into the client folder"),
                     detail: String(localized: "Pick any folder on the NAS share; this Mac copies the original there. No extra folder needed.")),
                Item(symbol: "link", title: String(localized: "Links you can change"),
                     detail: String(localized: "Edit any link, turn on downloads later and save your usual settings as the default.")),
                Item(symbol: "square.stack.3d.up", title: String(localized: "New versions on the same link"),
                     detail: String(localized: "Drop the new render on the asset; it reaches the NAS and your clients by itself.")),
            ]),
            Release(version: "4.0.5", items: [
                Item(symbol: "server.rack", title: String(localized: "Clients watch from your NAS"),
                     detail: String(localized: "Review links come from your NAS, never from the Mac you edit on.")),
                Item(symbol: "externaldrive.badge.plus", title: String(localized: "Footage goes to the NAS"),
                     detail: String(localized: "Pick the NAS folder when you add footage; files already there stay put.")),
                Item(symbol: "person.2.badge.key", title: String(localized: "Roles"),
                     detail: String(localized: "Admins and Editors for people and Macs, and Transfer Admin.")),
            ]),
            Release(version: "4.0.4", items: [
                Item(symbol: "person.badge.plus", title: String(localized: "Invite your team"),
                     detail: String(localized: "Send a teammate a link; they join and sign in with a passkey.")),
                Item(symbol: "building.2", title: String(localized: "Office group"),
                     detail: String(localized: "Several office Macs for Edit Anywhere, with the proxies on your NAS.")),
                Item(symbol: "play.rectangle", title: String(localized: "Play from the NAS"),
                     detail: String(localized: "Deliver streams straight from your NAS, like the browser, without downloading.")),
                Item(symbol: "arrow.up.doc", title: String(localized: "Uploads during an outage"),
                     detail: String(localized: "Your backup NAS takes client uploads and hands them to the main one later.")),
                Item(symbol: "film", title: String(localized: "RED clips in Edit Anywhere"),
                     detail: String(localized: "Browse and preview RED clips, in panels you can resize.")),
                Item(symbol: "link", title: String(localized: "Shorter, safer review links"),
                     detail: String(localized: "Short links that are harder to guess and can't be reused once deleted.")),
            ]),
            Release(version: "4.0.3", items: []),
            Release(version: "4.0.2", items: [
                Item(symbol: "globe.europe.africa", title: String(localized: "Edit Anywhere, simpler"),
                     detail: String(localized: "Macs, Folders, Proxies and Renders, and a Finder sidebar to browse the other Mac.")),
                Item(symbol: "speedometer", title: String(localized: "Streaming on slow connections"),
                     detail: String(localized: "Light 720p proxies when the office line is slow, or download them with one click.")),
                Item(symbol: "server.rack", title: String(localized: "Review links from the faster server"),
                     detail: String(localized: "Clients watch from your backup NAS when its upload is faster.")),
            ]),
            Release(version: "4.0.1", items: []),
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
    /// The newest release with feature cards (a fixes-only release, like 4.0.1, has none of its own).
    private var featured: WhatsNew.Release? { releases.first { !$0.items.isEmpty } }

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
                    if releases.contains(where: { $0.id != featured?.id && !$0.items.isEmpty }) { earlier }
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
        let items = featured?.items ?? []
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
                ForEach(releases.filter { $0.id != featured?.id }) { release in
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
