import SwiftUI

/// The places down the left of a file browser's panel, as in Finder (Edit Anywhere › Browse,
/// Deliver › Browse; the Library could use it too): groups under small grey headings, the place
/// shown in a plum tint, a right-click menu per place. Choosing one starts the browser there.
struct FinderSidebar: View {
    struct Place: Identifiable {
        var id: String
        var symbol: String
        var title: String
        /// Quiet, on the right (free space, a role).
        var detail: String?
        var dimmed = false
        /// A tooltip (a status, say).
        var help: String?
        var menu: AnyView?
    }

    struct Places: Identifiable {
        var id: String { key ?? title }
        var title: String
        var places: [Place]
        /// A status dot after the heading (a server: online, offline), with its tooltip.
        var dot: Color? = nil
        var help: String? = nil
        /// A right-click menu on the heading (a server's own menu).
        var menu: AnyView? = nil
        /// Its identity when two headings may read the same (two servers named alike).
        var key: String? = nil
    }

    static let width: CGFloat = 172

    /// Free space short enough for the row: "191 GB", "18.4 TB".
    static func size(_ bytes: Int64) -> String {
        // Short, like Finder's sidebar: whole gigabytes ("184 GB"), terabytes with one decimal ("18,4 TB").
        let gb = Double(bytes) / 1e9
        let (value, unit): (Double, UnitInformationStorage) = gb >= 1000 ? ((gb / 100).rounded() / 10, .terabytes) : (gb.rounded(), .gigabytes)
        return Measurement(value: value, unit: unit).formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                                          numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    let groups: [Places]
    let selection: String?
    /// Which browser it's in: its width, dragged, is kept per place.
    var place = "browse"
    let choose: (Place) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                let shown = groups.filter { !$0.places.isEmpty }
                ForEach(shown) { group in
                    let first = group.id == shown.first?.id
                    HStack(spacing: 5) {
                        Text(verbatim: group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Design.Studio.textQuiet)
                            .lineLimit(1)
                        if let dot = group.dot { Circle().fill(dot).frame(width: 6, height: 6) }
                        Spacer(minLength: 0)
                        // The server's menu (Invite a Teammate…) visible, not only on right-click.
                        if let menu = group.menu {
                            Menu { menu } label: {
                                Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .help(String(localized: "Server: invite a teammate, change folders, pair again"))
                        }
                    }
                        .contentShape(.rect)
                        .help(group.help ?? "")
                        .contextMenu { if let menu = group.menu { menu } }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Text(verbatim: group.help ?? ""))
                        .padding(.horizontal, 6)
                        // The first heading centred on the browser's toolbar beside it, as in Finder.
                        .padding(.top, first ? 0 : 12)
                        .padding(.bottom, first ? 0 : 3)
                        .frame(height: first ? FinderPaneView.toolbarHeight : nil)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.places) { row($0) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        // A touch darker than the folders beside it.
        .background { ZStack { Design.Studio.panel; Design.Studio.backdrop.opacity(0.55) } }
        .finderResizable("finderSidebarWidth." + place, width: Self.width, range: 140...320)
    }

    private func row(_ place: Place) -> some View {
        let on = place.id == selection
        return Button { choose(place) } label: {
            HStack(spacing: 5) {
                Image(systemName: place.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Design.Brand.pink : Design.Studio.textQuiet)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(verbatim: place.title)
                    .font(Design.Studio.body)
                    .foregroundStyle(Design.Studio.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let detail = place.detail {
                    Text(verbatim: detail).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(on ? Design.Brand.chosenFill : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: Design.Radius.small, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(place.dimmed ? 0.45 : 1)
        .help(place.help ?? "")
        .contextMenu { if let menu = place.menu { menu } }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
