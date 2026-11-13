import SwiftUI

// Photo → Cull, as in page 5 of the 2026-11-12 layout reference: the moments on the left, the photos of
// one moment side by side (1, 2, 4 or 6) with what the checks found, and the faces and keys underneath.
// Only culling here: no edit tools (owner, 2026-11-12).

/// One moment to cull: its photos in the order taken, and the one the ranking puts on top.
struct CullMoment: Identifiable, Equatable {
    let id: String
    let members: [String]
    let top: String

    /// Every photo in its moment (photos on their own are moments of one), in the photos' order.
    @MainActor static func all(_ photos: [String], listing: PhotoMoments.Listing) -> [CullMoment] {
        var seen: Set<String> = []
        var result: [CullMoment] = []
        // The top photo of each moment: the first of its photos the listing shows (moments closed).
        var tops: [String: String] = [:]
        for path in listing.paths {
            let key = listing.moment[path] ?? path
            if tops[key] == nil { tops[key] = path }
        }
        for path in photos {
            let key = listing.moment[path] ?? path
            guard seen.insert(key).inserted else { continue }
            let members = listing.members[key] ?? [path]
            result.append(CullMoment(id: key, members: members, top: tops[key] ?? members[0]))
        }
        return result
    }
}

/// The Cull page under the title row: moments, the photos side by side, faces and keys.
struct PhotoCullPage: View {
    let moments: [CullMoment]
    /// Every photo shown, in order (photos side by side run on through it when a moment has fewer).
    let all: [String]
    @Binding var focus: String?
    @Binding var selection: Set<String>
    let count: Int
    let sync: Bool
    let zoomed: Bool
    @Binding var anchor: UnitPoint
    @State private var catalog = PhotoCatalog.shared
    @State private var checks = PhotoChecks.shared
    @State private var reviewing = false

    private var current: CullMoment? { moments.first { $0.members.contains(focus ?? "") } ?? moments.first }

    /// The photos side by side: `count` of them, the page that holds the one in focus. Within a moment of
    /// several photos, its photos; otherwise the photos in order.
    private var shown: [String] {
        guard let focus else { return [] }
        if count <= 1 { return [focus] }
        let list = (current?.members.count ?? 0) > 1 ? current?.members ?? all : all
        let index = list.firstIndex(of: focus) ?? 0
        let start = (index / count) * count
        return Array(list[start..<min(start + count, list.count)])
    }

    /// What Pluck would reject, for one look: undecided photos that look soft or have closed eyes,
    /// and the photos of a moment that aren't its top pick.
    private var proposals: [(path: String, reason: String)] {
        var tops: [String: String] = [:]
        for moment in moments where moment.members.count > 1 { for path in moment.members { tops[path] = moment.top } }
        return all.compactMap { path in
            guard catalog.record(path).flag == .none else { return nil }
            if let check = checks.check(path) {
                if check.looksSoft { return (path, String(localized: "May be out of focus")) }
                if check.eyesClosed { return (path, String(localized: "Eyes may be closed")) }
            }
            if let top = tops[path], top != path { return (path, String(localized: "Not the top pick of its moment")) }
            return nil
        }
    }

    var body: some View {
        let panel = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
        HStack(spacing: Design.Studio.panelGap) {
            momentsPanel
                .frame(width: 232)
                .background(Design.Studio.panel, in: panel)
                .clipShape(panel)
            VStack(spacing: Design.Studio.panelGap) {
                tiles
                bottom
                    .frame(height: focus.flatMap { checks.check($0)?.faces.isEmpty == false ? true : nil } == true ? 64 : 44)
                    .background(Design.Studio.panel, in: panel)
                    .clipShape(panel)
            }
        }
    }

    // MARK: Moments

    private var momentsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Moments").font(Design.Studio.sectionTitle)
                Spacer()
                Text(verbatim: "\(moments.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(moments) { moment in
                            MomentRow(moment: moment, on: moment.id == current?.id,
                                      done: moment.members.allSatisfy { catalog.record($0).flag != .none },
                                      taken: checks.check(moment.top)?.taken) {
                                focus = moment.top
                                selection = [moment.top]
                            }
                            .id(moment.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: current?.id) { _, id in if let id { withAnimation { scroller.scrollTo(id, anchor: .center) } } }
            }
        }
    }

    // MARK: Photos side by side

    private var tiles: some View {
        let list = shown
        let columns = list.count <= 1 ? 1 : list.count == 2 || list.count == 4 ? 2 : 3
        let rows = Int((Double(list.count) / Double(columns)).rounded(.up))
        return GeometryReader { geometry in
            let gap = Design.Studio.panelGap
            let width = (geometry.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (geometry.size.height - gap * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap), count: columns), spacing: gap) {
                ForEach(list, id: \.self) { path in
                    CullTile(path: path, record: catalog.record(path), check: checks.check(path),
                             top: path == current?.top && (current?.members.count ?? 0) > 1,
                             on: path == focus, zoomed: zoomed && (sync || path == focus), anchor: $anchor) {
                        focus = path
                        selection = [path]
                    }
                    .frame(width: width, height: height)
                }
            }
        }
    }

    // MARK: Faces and keys

    private var bottom: some View {
        HStack(spacing: 12) {
            if let focus, let faces = checks.check(focus)?.faces, !faces.isEmpty {
                CullFaces(path: focus, faces: faces)
                Rectangle().fill(Design.Studio.line).frame(width: 1, height: 28)
            }
            let keys = Shortcuts.shared
            let hints: [(key: String, what: String)] = [
                (keys.shortcut(.photoPick).label, String(localized: "Keep")),
                (keys.shortcut(.photoReject).label, String(localized: "Reject")),
                ("T", String(localized: "Top pick, reject rest")),
                (keys.shortcut(.photoZoom).label, String(localized: "100 %")),
                ("↓", String(localized: "Next moment")),
                ("1–5", String(localized: "Stars")),
            ]
            // Narrow windows: fewer key hints, then none (the faces and Review stay).
            ViewThatFits(in: .horizontal) {
                FlowKeys(items: hints)
                FlowKeys(items: Array(hints.prefix(2)))
                Spacer(minLength: 0)
            }
            let count = proposals.count
            Button("Review proposals · \(count)") { reviewing = true }
                .buttonStyle(StudioFlatButtonStyle())
                .fixedSize()
                .disabled(count == 0)
                .help("The photos Pluck would reject, on one sheet: untick any to keep, then reject the rest")
        }
        .padding(.horizontal, 14)
        .sheet(isPresented: $reviewing) {
            CullReview(proposals: proposals) { rejected in
                if !rejected.isEmpty { catalog.update(Array(rejected)) { $0.flag = .reject } }
                reviewing = false
            } cancel: { reviewing = false }
        }
    }
}

/// Review proposals: the photos Pluck would reject, all ticked; untick to keep. Rejecting only flags them
/// (nothing is deleted).
private struct CullReview: View {
    let proposals: [(path: String, reason: String)]
    let apply: (Set<String>) -> Void
    let cancel: () -> Void
    @State private var ticked: Set<String> = []
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review proposals").font(Design.Studio.sectionTitle)
                Spacer()
                Text("\(ticked.count) of \(proposals.count) to reject").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(16)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                    ForEach(proposals, id: \.path) { item in
                        let on = ticked.contains(item.path)
                        Button { if on { ticked.remove(item.path) } else { ticked.insert(item.path) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CullThumb(path: item.path)
                                    .aspectRatio(3 / 2, contentMode: .fit)
                                    .opacity(on ? 1 : 0.45)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(on ? Design.Brand.pink : Design.Studio.textQuiet)
                                            .padding(6)
                                    }
                                Text(verbatim: PhotoCatalog.displayName(item.path)).font(Design.Studio.body).lineLimit(1)
                                Text(verbatim: item.reason).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Button(ticked.count == proposals.count ? "Untick All" : "Tick All") {
                    ticked = ticked.count == proposals.count ? [] : Set(proposals.map(\.path))
                }
                .buttonStyle(StudioFlatButtonStyle())
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Reject \(ticked.count)") { apply(ticked) }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 560)
        .background(Design.Studio.panel)
        .onAppear { if !started { started = true; ticked = Set(proposals.map(\.path)) } }
    }
}

/// How much of a picture is blown out or blocked up (from the camera's preview), kept per photo.
@MainActor
enum CullLight {
    private static var known: [String: (high: Double, low: Double)] = [:]

    static func clipped(_ path: String, _ image: NSImage) -> (high: Double, low: Double) {
        if let found = known[path] { return found }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (0, 0) }
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let made = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard made else { return (0, 0) }
        var high = 0, low = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let top = max(pixels[i], pixels[i + 1], pixels[i + 2])
            if top >= 250 { high += 1 } else if top <= 4 { low += 1 }
        }
        let total = Double(side * side)
        let result = (Double(high) / total, Double(low) / total)
        known[path] = result
        return result
    }
}

/// A moment in the list: two of its photos stacked, the time, how many, and a tick when every photo is decided.
private struct MomentRow: View {
    let moment: CullMoment
    let on: Bool
    let done: Bool
    let taken: Date?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if moment.members.count > 1 {
                        CullThumb(path: moment.members.first { $0 != moment.top } ?? moment.top)
                            .frame(width: 56, height: 38).opacity(0.45).offset(x: 6)
                    }
                    CullThumb(path: moment.top)
                        .frame(width: 56, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Design.Studio.panel, lineWidth: 2))
                        .offset(y: 4)
                }
                .frame(width: 62, height: 42, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: taken?.formatted(date: .omitted, time: .shortened) ?? PhotoCatalog.displayName(moment.top))
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Text("^[\(moment.members.count) photo](inflect: true)")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
                Spacer(minLength: 0)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).accessibilityLabel("Done")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 64)
            .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The camera's own preview of a photo (quick), filling its frame.
private struct CullThumb: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Color.black.opacity(0.35)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
            .task(id: path) {
                if let ready = CullCache.shared.image(path) { image = ready } else { image = await CullCache.shared.load(path) }
            }
    }
}

/// One photo side by side: on the neutral grey, with what the checks found, its flag and stars.
private struct CullTile: View {
    let path: String
    let record: PhotoRecord
    let check: PhotoCheck?
    let top: Bool
    let on: Bool
    let zoomed: Bool
    @Binding var anchor: UnitPoint
    let choose: () -> Void
    @State private var image: NSImage?
    @State private var light: (high: Double, low: Double)?
    @State private var dragFrom: UnitPoint?
    @AppStorage(Design.Photo.surroundKey) private var surroundWhite = 0.16

    private static let zoom = 3.0
    private static let warn = Color(red: 0xE0 / 255, green: 0xA1 / 255, blue: 0x5E / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
        GeometryReader { geometry in
            ZStack {
                Color(white: surroundWhite)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .scaleEffect(zoomed ? Self.zoom : 1, anchor: anchor)
                        .opacity(record.flag == .reject ? 0.4 : 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(.rect)
            .onTapGesture { location in
                if zoomed { anchor = UnitPoint(x: location.x / max(geometry.size.width, 1), y: location.y / max(geometry.size.height, 1)) }
                choose()
            }
            // Zoomed: drag to look around (all photos follow when they zoom together).
            .gesture(DragGesture(minimumDistance: 3).onChanged { drag in
                guard zoomed else { return }
                let from = dragFrom ?? anchor
                if dragFrom == nil { dragFrom = anchor }
                let w = max(geometry.size.width, 1) * Self.zoom, h = max(geometry.size.height, 1) * Self.zoom
                anchor = UnitPoint(x: min(max(from.x - drag.translation.width / w * Self.zoom / (Self.zoom - 1), 0), 1),
                                   y: min(max(from.y - drag.translation.height / h * Self.zoom / (Self.zoom - 1), 0), 1))
            }.onEnded { _ in dragFrom = nil })
        }
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                chip(Text(verbatim: PhotoCatalog.displayName(path)))
                if top {
                    Text("Top pick").font(Design.Studio.hint).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Design.Brand.deep, in: .rect(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if let check {
                HStack(spacing: 4) {
                    checkChip("Sharp", fine: !check.looksSoft)
                    if !check.faces.isEmpty { checkChip("Eyes", fine: !check.eyesClosed) }
                    if let light {
                        checkChip("Light", fine: light.high < 0.04 && light.low < 0.10)
                            .help("Blown out: \(Int((light.high * 100).rounded())) %. Blocked up: \(Int((light.low * 100).rounded())) %.")
                    }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                chip(Text(record.flag == .pick ? "Kept" : record.flag == .reject ? "Rejected" : "Not decided"),
                     colour: record.flag == .pick ? Design.Studio.text : Design.Studio.textQuiet)
                chip(Text(verbatim: String(repeating: "★", count: record.rating) + String(repeating: "☆", count: 5 - record.rating)))
                    .accessibilityLabel(Text("\(record.rating) stars"))
            }
            .padding(10)
        }
        .overlay { shape.strokeBorder(Design.Brand.gradient, lineWidth: 2).opacity(on ? 1 : 0) }
        .task(id: path) {
                if let ready = CullCache.shared.image(path) { image = ready } else { image = await CullCache.shared.load(path) }
                if let image { light = CullLight.clipped(path, image) }
            }
    }

    private func chip(_ text: Text, colour: Color = Design.Studio.text) -> some View {
        text.font(Design.Studio.hint).foregroundStyle(colour).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Design.rgb(0x0F0F11).opacity(0.78), in: .rect(cornerRadius: 6, style: .continuous))
    }

    private func checkChip(_ name: LocalizedStringKey, fine: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: fine ? "checkmark" : "xmark").font(.system(size: 9, weight: .semibold))
            Text(name)
        }
        .font(Design.Studio.hint)
        .foregroundStyle(fine ? Design.Studio.text : Self.warn)
        .padding(.horizontal, 7).frame(height: 20)
        .background(Design.rgb(0x0F0F11).opacity(0.78), in: .rect(cornerRadius: 6, style: .continuous))
    }
}

/// The faces in the photo in focus, close up, to check eyes and focus.
private struct CullFaces: View {
    let path: String
    let faces: [CGRect]
    @State private var crops: [CGImage] = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(crops.indices, id: \.self) { index in
                Image(decorative: crops[index], scale: 1).resizable().scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            }
        }
        .accessibilityHidden(true)
        .task(id: path) {
            var image = CullCache.shared.image(path)
            if image == nil { image = await CullCache.shared.load(path) }
            guard !faces.isEmpty, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { crops = []; return }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            crops = faces.prefix(4).compactMap { box in
                let side = max(box.width * w, box.height * h) * 1.5
                let centre = CGPoint(x: box.midX * w, y: (1 - box.midY) * h)
                let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h))
                return cg.cropping(to: rect.integral)
            }
        }
    }
}

/// The keys for culling, each in a small key cap with what it does.
private struct FlowKeys: View {
    let items: [(key: String, what: String)]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    Text(verbatim: items[index].key)
                        .font(Design.Studio.hint)
                        .foregroundStyle(Design.Studio.text)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: 4, style: .continuous))
                    Text(verbatim: items[index].what).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}
