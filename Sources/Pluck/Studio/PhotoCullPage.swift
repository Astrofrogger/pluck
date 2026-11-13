import SwiftUI
import Vision

// Photo → Cull, as in page 5 of the 2026-11-12 layout reference: the moments on the left, the photos of
// one moment side by side (1, 2, 4 or 6) with what the checks found, and the faces and keys underneath.
// Only culling here: no edit tools (owner, 2026-11-12).

/// One moment to cull: its photos in the order taken, and the one the ranking puts on top.
struct CullMoment: Identifiable, Equatable {
    let id: String
    let members: [String]
    let top: String
    /// The ranking's strongest quarter (at least one), best first.
    var onTop: [String] = []

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
        // The listing shows each closed moment's top quarter, best first.
        var shownOnTop: [String: [String]] = [:]
        for path in listing.paths { shownOnTop[listing.moment[path] ?? path, default: []].append(path) }
        for path in photos {
            let key = listing.moment[path] ?? path
            guard seen.insert(key).inserted else { continue }
            let members = listing.members[key] ?? [path]
            let top = tops[key] ?? members[0]
            result.append(CullMoment(id: key, members: members, top: top, onTop: shownOnTop[key] ?? [top]))
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
    var peaking = false
    @Binding var anchor: UnitPoint
    @State private var catalog = PhotoCatalog.shared
    @State private var checks = PhotoChecks.shared
    @State private var reviewing = false
    @State private var autoCulling = false

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
                             on: path == focus, zoomed: zoomed && (sync || path == focus), peaking: peaking, anchor: $anchor) {
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
                // A moment of several photos: the biggest face in each of them, side by side; one photo: its faces.
                if let moment = current, moment.members.count > 1 {
                    CullFaceStrip(members: moment.members, focus: focus) { path in
                        self.focus = path
                        selection = [path]
                    }
                } else {
                    CullFaces(path: focus, faces: faces)
                }
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
            Button("Auto Cull…") { autoCulling = true }
                .buttonStyle(StudioFlatButtonStyle())
                .fixedSize()
                .help("Keep the best of each moment and reject the rest, how strictly you choose: you see it all before anything changes")
            let count = proposals.count
            Button("Review proposals · \(count)") { reviewing = true }
                .buttonStyle(StudioFlatButtonStyle())
                .fixedSize()
                .disabled(count == 0)
                .help("The photos Pluck would reject, on one sheet: untick any to keep, then reject the rest")
        }
        .padding(.horizontal, 14)
        .sheet(isPresented: $autoCulling) {
            CullAuto(moments: moments, checks: checks) { keep, reject in
                if !keep.isEmpty { catalog.update(Array(keep)) { $0.flag = .pick } }
                if !reject.isEmpty { catalog.update(Array(reject)) { $0.flag = .reject } }
                autoCulling = false
            } cancel: { autoCulling = false }
        }
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
    var peaking = false
    @Binding var anchor: UnitPoint
    let choose: () -> Void
    @State private var image: NSImage?
    /// Zoomed: the photo at full size (true 100 %), once it's read.
    @State private var full: CGImage?
    /// Focus peaking on what's shown: the sharp edges in green, and the sharpest spot (shares from the top left).
    @State private var peaks: (overlay: CGImage, sharpest: CGPoint)?
    @Environment(\.displayScale) private var displayScale
    @State private var light: (high: Double, low: Double)?
    @State private var dragFrom: UnitPoint?
    @AppStorage(Design.Photo.surroundKey) private var surroundWhite = 0.16

    /// How far to zoom for true 100 % (one of the photo's pixels to one of the screen's) in a frame this size; 3× when
    /// the photo's size isn't known.
    private func zoom(in frame: CGSize) -> Double {
        guard let px = CullCache.pixelSize(of: path), px.width > 0, px.height > 0 else { return 3 }
        let fit = min(frame.width / px.width, frame.height / px.height)
        return max(1.5, 1 / (fit * max(displayScale, 1)))
    }
    private static let warn = Color(red: 0xE0 / 255, green: 0xA1 / 255, blue: 0x5E / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
        GeometryReader { geometry in
            let zoom = zoom(in: geometry.size)
            ZStack {
                Color(white: surroundWhite)
                if let image {
                    ZStack {
                        if zoomed, let full { Image(decorative: full, scale: 1).resizable().interpolation(.none).scaledToFit() }
                        else { Image(nsImage: image).resizable().scaledToFit() }
                        if peaking, let peaks {
                            Image(decorative: peaks.overlay, scale: 1).resizable().scaledToFit().allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(zoomed ? zoom : 1, anchor: anchor)
                    .opacity(record.flag == .reject ? 0.4 : 1)
                    if peaking, let peaks, !zoomed, let size = CullCache.pixelSize(of: path) {
                        // The sharpest spot, ringed.
                        let fit = min(geometry.size.width / size.width, geometry.size.height / size.height)
                        let w = size.width * fit, h = size.height * fit
                        Circle().stroke(Design.Studio.good, lineWidth: 2).frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .position(x: (geometry.size.width - w) / 2 + peaks.sharpest.x * w, y: (geometry.size.height - h) / 2 + peaks.sharpest.y * h)
                            .allowsHitTesting(false)
                            .help("The sharpest spot")
                    }
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
                let w = max(geometry.size.width, 1) * zoom, h = max(geometry.size.height, 1) * zoom
                anchor = UnitPoint(x: min(max(from.x - drag.translation.width / w * zoom / (zoom - 1), 0), 1),
                                   y: min(max(from.y - drag.translation.height / h * zoom / (zoom - 1), 0), 1))
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
        .task(id: "\(path)|\(zoomed)") {
            full = nil
            if zoomed { full = await CullCache.shared.full(path) }
        }
        .task(id: "\(path)|\(peaking)|\(full != nil)") {
            guard peaking, let source = full ?? image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { peaks = nil; return }
            peaks = await Task.detached(priority: .userInitiated) { CullPeaking.find(source) }.value
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

/// Focus peaking: where a picture is sharp (its strongest fine edges, against its own sharpest), as a green overlay, and the
/// sharpest spot. Camera-independent: it shows where focus landed, whatever the camera says.
enum CullPeaking {
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    /// For small measurements elsewhere in Cull.
    nonisolated(unsafe) static let plain = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    /// The absolute Laplacian of the brightness (in the picture's own steps).
    nonisolated(unsafe) private static let edgeKernel = CIKernel(source: """
        kernel vec4 laplace(sampler s) {
            vec2 p = destCoord();
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            float c = dot(sample(s, samplerTransform(s, p)).rgb, w);
            float n = dot(sample(s, samplerTransform(s, p + vec2(0.0, 1.0))).rgb, w) + dot(sample(s, samplerTransform(s, p - vec2(0.0, 1.0))).rgb, w)
                    + dot(sample(s, samplerTransform(s, p + vec2(1.0, 0.0))).rgb, w) + dot(sample(s, samplerTransform(s, p - vec2(1.0, 0.0))).rgb, w);
            float v = abs(4.0 * c - n);
            return vec4(v, v, v, 1.0);
        }
        """)
    nonisolated(unsafe) private static let peakKernel = CIColorKernel(source: """
        kernel vec4 peak(__sample e, float level) {
            float a = smoothstep(level * 0.8, level * 1.15, e.r);
            return vec4(0.36 * a, 0.95 * a, 0.45 * a, 0.9 * a);
        }
        """)

    nonisolated static func find(_ picture: CGImage) -> (overlay: CGImage, sharpest: CGPoint)? {
        // (On a 1200-pixel copy: the threshold and the overlay measured at the same size, and pixel noise averaged away.)
        let source = CIImage(cgImage: picture), k = min(1, 1200 / max(source.extent.width, source.extent.height))
        let image = source.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let e = image.extent.integral
        // Fine edges: the absolute Laplacian of the brightness, a touch blurred (single pixels of noise don't count).
        guard let laplace = edgeKernel,
              let raw = laplace.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -1, dy: -1) }, arguments: [image.clampedToExtent()]) else { return nil }
        let edges = raw.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: e)
        // The picture's sharpest (its 99th percentile edge), and the green where edges are over 45% of it.
        let small = edges
        let s = e
        let w = Int(s.width), h = Int(s.height)
        guard w > 2, h > 2 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: s, format: .RGBAf, colorSpace: nil)
        let values = stride(from: 0, to: px.count, by: 4).map { px[$0] }
        let top = values.sorted()[Int(Double(values.count - 1) * 0.99)]
        guard top > 1e-4 else { return nil }
        // The sharpest spot: the 40×40 block with the most edge.
        var best = (score: Float(-1), x: 0, y: 0)
        for by in stride(from: 0, to: h - 40, by: 10) { for bx in stride(from: 0, to: w - 40, by: 10) {
            var sum: Float = 0
            for y in stride(from: by, to: by + 40, by: 2) { for x in stride(from: bx, to: bx + 40, by: 2) { sum += values[y * w + x] } }
            if sum > best.score { best = (sum, bx + 20, by + 20) }
        } }
        // Green where an edge is over 45% of the sharpest (softly), see-through elsewhere.
        guard let kernel = peakKernel, let green = kernel.apply(extent: e, arguments: [edges, Float(top) * 0.45]) else { return nil }
        guard let overlay = context.createCGImage(green, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        // (The small copy's rows are from the top in the bitmap.)
        return (overlay, CGPoint(x: Double(best.x) / Double(w), y: Double(best.y) / Double(h)))
    }
}

/// The same face through a moment: the biggest face in the photo in focus, found again in each photo of its moment (the
/// nearest face to where it was), close up, with whether its eyes are open and how sharp it is; the sharpest with open
/// eyes ringed. A click shows that photo.
struct CullFaceStrip: View {
    let members: [String]
    let focus: String
    let choose: (String) -> Void
    @State private var faces: [(path: String, crop: CGImage, open: Bool?, sharpness: Double)] = []
    @State private var checks = PhotoChecks.shared

    var body: some View {
        let best = faces.filter { $0.open != false }.max { $0.sharpness < $1.sharpness }?.path
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(faces, id: \.path) { face in
                    Button { choose(face.path) } label: {
                        Image(decorative: face.crop, scale: 1).resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous)
                                    .strokeBorder(face.path == focus ? Design.Studio.text : face.path == best ? Design.Studio.good : .clear, lineWidth: 2)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if face.open == false {
                                    Image(systemName: "eye.slash.fill").font(.system(size: 9)).foregroundStyle(Design.Studio.bad)
                                        .padding(2).background(.black.opacity(0.6), in: .circle).padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(face.path == best ? "Sharpest with open eyes" : face.open == false ? "Eyes closed" : PhotoCatalog.displayName(face.path))
                }
            }
        }
        .frame(maxWidth: 360)
        .task(id: members.joined() + focus) {
            var made: [(String, CGImage, Bool?, Double)] = []
            guard let target = checks.check(focus)?.faces.max(by: { $0.width * $0.height < $1.width * $1.height }) else { faces = []; return }
            for path in members.prefix(12) {
                guard let boxes = checks.check(path)?.faces, !boxes.isEmpty,
                      let box = boxes.min(by: { hypot($0.midX - target.midX, $0.midY - target.midY) < hypot($1.midX - target.midX, $1.midY - target.midY) }),
                      hypot(box.midX - target.midX, box.midY - target.midY) < 0.2 else { continue }
                var image = CullCache.shared.image(path)
                if image == nil { image = await CullCache.shared.load(path) }
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                if let measured = await Task.detached(priority: .userInitiated, operation: { CullFaceStrip.measure(cg, box: box) }).value {
                    made.append((path, measured.crop, measured.open, measured.sharpness))
                }
            }
            faces = made
        }
    }

    /// A face's crop (half again its size), whether its eyes are open (nil: no eyes found), and its sharpness (the mean
    /// squared Laplacian of the crop at 160 pixels).
    nonisolated static func measure(_ cg: CGImage, box: CGRect) -> (crop: CGImage, open: Bool?, sharpness: Double)? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = max(box.width * w, box.height * h) * 1.5
        let centre = CGPoint(x: box.midX * w, y: (1 - box.midY) * h)
        let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let crop = cg.cropping(to: rect.integral) else { return nil }
        let landmarks = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: crop).perform([landmarks])
        var open: Bool?
        if let face = landmarks.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye {
            open = !(PhotoChecks.openness(l) < 0.16 && PhotoChecks.openness(r) < 0.16)
        }
        let picture = CIImage(cgImage: crop), k = 160 / max(picture.extent.width, 1)
        let small = picture.transformed(by: CGAffineTransform(scaleX: k, y: k)).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let edges = small.applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0])
        let squared = edges.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: edges])
        let average = squared.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent.insetBy(dx: 3, dy: 3))])
        var pixel = [Float](repeating: 0, count: 4)
        CullPeaking.plain.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (crop, open, Double(pixel[0]))
    }
}

/// How strictly Auto Cull keeps.
enum CullStrictness: String, CaseIterable {
    /// Each moment's top quarter kept; of the rest only soft photos and closed eyes rejected.
    case gentle
    /// Each moment's top quarter kept, the rest rejected.
    case balanced
    /// Only each moment's top pick kept, the rest rejected.
    case strict
}

/// Auto Cull's decisions for photos not decided yet (decided ones are never changed): the ranking's best of each moment
/// (the learned style when one is chosen) kept by `strictness`, the rest rejected; a photo on its own kept unless it looks
/// soft or has closed eyes.
@MainActor
func autoCull(_ moments: [CullMoment], strictness: CullStrictness, checks: PhotoChecks, catalog: PhotoCatalog) -> (keep: [String], reject: [String]) {
    var keep: [String] = [], reject: [String] = []
    for moment in moments {
        let open = moment.members.filter { catalog.record($0).flag == .none }
        guard !open.isEmpty else { continue }
        let flawed = Set(open.filter { checks.check($0)?.possibleReject == true })
        if moment.members.count == 1 {
            if flawed.contains(moment.top) { reject.append(moment.top) } else { keep.append(moment.top) }
            continue
        }
        let best = strictness == .strict ? [moment.top] : moment.onTop
        for path in open {
            if best.contains(path), !flawed.contains(path) { keep.append(path) }
            else if strictness != .gentle || flawed.contains(path) { reject.append(path) }
        }
    }
    return (keep, reject)
}

/// Auto Cull: choose how strict, see what would be kept and rejected (untick any to leave it undecided), then apply.
private struct CullAuto: View {
    let moments: [CullMoment]
    let checks: PhotoChecks
    let apply: (Set<String>, Set<String>) -> Void
    let cancel: () -> Void
    @AppStorage("cullStrictness") private var strictness = CullStrictness.balanced.rawValue
    @State private var left: Set<String> = []

    var body: some View {
        let level = CullStrictness(rawValue: strictness) ?? .balanced
        let decisions = autoCull(moments, strictness: level, checks: checks, catalog: PhotoCatalog.shared)
        let keep = decisions.keep.filter { !left.contains($0) }, reject = decisions.reject.filter { !left.contains($0) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Auto Cull").font(Design.Studio.sectionTitle)
                Spacer()
                StudioSegmented(ground: Design.Studio.panel, options: [(CullStrictness.gentle.rawValue, LocalizedStringKey("Gentle")),
                                                                        (CullStrictness.balanced.rawValue, LocalizedStringKey("Balanced")),
                                                                        (CullStrictness.strict.rawValue, LocalizedStringKey("Strict"))],
                                selection: $strictness)
                    .fixedSize()
            }
            .padding(16)
            Text(level == .gentle ? "Keeps the best quarter of each moment; rejects only soft photos and closed eyes."
                 : level == .balanced ? "Keeps the best quarter of each moment; rejects the rest."
                 : "Keeps only the best photo of each moment; rejects the rest.")
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 12) {
                    ForEach(decisions.keep + decisions.reject, id: \.self) { path in
                        CullAutoTile(path: path, keeping: decisions.keep.contains(path), out: left.contains(path)) {
                            if left.contains(path) { left.remove(path) } else { left.insert(path) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text("\(keep.count) to keep · \(reject.count) to reject").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(Set(keep), Set(reject)) }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(keep.isEmpty && reject.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 780, height: 580)
        .background(Design.Studio.panel)
    }
}

/// One photo in Auto Cull: what would happen to it; a click leaves it undecided (or takes it back).
private struct CullAutoTile: View {
    let path: String
    let keeping: Bool
    let out: Bool
    let toggle: () -> Void

    private var label: LocalizedStringKey { out ? "Leave" : keeping ? "Keep" : "Reject" }
    private var colour: Color { out ? Design.Studio.raised : keeping ? Design.Brand.pink : Design.Studio.bad.opacity(0.85) }

    var body: some View {
        Button(action: toggle) {
            CullThumb(path: path)
                .aspectRatio(3 / 2, contentMode: .fit)
                .opacity(out ? 0.35 : 1)
                .overlay(alignment: .topTrailing) {
                    Text(label).font(Design.Studio.hint).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(colour, in: .rect(cornerRadius: 5, style: .continuous))
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
        .help("Click to leave this one undecided")
    }
}
