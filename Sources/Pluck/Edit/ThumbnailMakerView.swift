import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail Maker: a video in, its best frames picked, and a thumbnail designed on one in the
/// brand's style (layout, title, logo, size per platform, a gentle touch-up), saved as PNG or JPEG.
struct ThumbnailMakerView: View {
    /// A video to open when the page appears (self-test).
    @MainActor static var openFile: URL?
    @State private var video: URL?
    @State private var picks: [ThumbnailMaker.Sample] = []
    @State private var chosen: ThumbnailMaker.Sample?
    @State private var frame: CGImage?
    @State private var design = ThumbnailMaker.Design()
    @State private var size = ThumbnailMaker.Size.youtube
    @State private var format = ThumbnailMaker.Format.png
    /// nil: Brand Pack's colours and font.
    @State private var brandID: UUID?
    @State private var preview: ThumbnailMaker.Rendered?
    @State private var progress: Double?
    @State private var problem: String?
    @State private var saved: [URL] = []
    @State private var dropping = false
    @State private var showSafe = true
    @State private var profiles = BrandProfiles.shared

    private var ffmpeg: String? { AppDelegate.shared?.manager.tool("ffmpeg") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Thumbnail Maker").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                if let video {
                    header(video)
                    if let progress { StudioProgress(share: progress) }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                    }
                    if !picks.isEmpty { strip }
                    if frame != nil { designer }
                } else {
                    StudioEmptyState(symbol: "photo.artframe", title: "Drop a video here",
                                     line: "Pluck picks the best frames and adds a title in the brand’s style.",
                                     targeted: dropping, button: "Choose Video…", action: choose)
                        .padding(.vertical, 48)
                        .studioDropZone(targeted: dropping)
                        .onTapGesture(perform: choose)
                }
                StudioFootnote(text: "Runs on this Mac")
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .studioPanel()
        .onAppear { if let url = Self.openFile { Self.openFile = nil; video = url } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                guard let url = await providers.first?.load(URL.self), UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { return }
                video = url
            }
            return true
        }
        .task(id: video) { await analyse() }
        .task(id: RenderKey(design: design, size: size, brandID: brandID, time: chosen?.time, hasFrame: frame != nil)) { await renderPreview() }
    }

    private struct RenderKey: Hashable {
        var design: ThumbnailMaker.Design, size: ThumbnailMaker.Size, brandID: UUID?, time: Double?, hasFrame: Bool
    }

    private func header(_ video: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 14)).foregroundStyle(Design.Brand.pink).accessibilityHidden(true)
            Text(video.lastPathComponent).font(.system(size: 15)).foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Change…", action: choose).buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .studioBox(outline: Design.rgb(0x8E4C64))
    }

    /// The picked frames, the best first.
    private var strip: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(picks) { sample in
                let on = sample.time == chosen?.time
                Button { choose(sample) } label: {
                    Image(decorative: sample.image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Design.Studio.line), lineWidth: on ? 2 : 1)
                        }
                        .overlay(alignment: .topLeading) {
                            if sample.time == picks.first?.time {
                                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Design.Studio.text).padding(5)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Duration.seconds(sample.time).formatted(.time(pattern: .minuteSecond)))
                .accessibilityLabel(Text(Duration.seconds(sample.time).formatted(.time(pattern: .minuteSecond))))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var designer: some View {
        HStack(alignment: .top, spacing: 20) {
            canvas.frame(maxWidth: .infinity)
            inspector.frame(width: 280)
        }
    }

    /// The thumbnail as it'll be saved, the safe zone dashed over it.
    private var canvas: some View {
        let pixels = size.pixels
        return ZStack {
            if let preview {
                Image(decorative: preview.image, scale: 1).resizable()
            } else {
                Design.Studio.backdrop
            }
        }
        .aspectRatio(pixels.width / pixels.height, contentMode: .fit)
        .overlay {
            if showSafe {
                GeometryReader { g in
                    let k = g.size.width / pixels.width
                    let safe = size.safeRect(pixels)
                    Rectangle().strokeBorder(Design.Studio.text.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: safe.width * k, height: safe.height * k)
                        .offset(x: safe.minX * k, y: safe.minY * k)
                }
                .accessibilityHidden(true)
            }
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .frame(maxHeight: 520)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSegmented(options: ThumbnailMaker.Layout.allCases.map { ($0, LocalizedStringKey(String(localized: $0.name))) },
                            selection: $design.layout, symbols: ThumbnailMaker.Layout.allCases.map(\.symbol), fill: true)
            field("Title", text: $design.title)
            if design.layout == .titleSubtitle || design.layout == .split { field("Subtitle", text: $design.subtitle) }
            StudioField(label: "Brand") {
                Menu {
                    Button("Brand Pack") { brandID = nil }
                    if !profiles.all.isEmpty { Divider() }
                    ForEach(profiles.all) { profile in Button(profile.name) { brandID = profile.id } }
                } label: {
                    StudioMenuLabel(title: profiles.profile(brandID)?.name ?? String(localized: "Brand Pack"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            StudioField(label: "Size") {
                Menu {
                    ForEach(ThumbnailMaker.Size.allCases) { option in
                        Button { size = option } label: { Text(sizeTitle(option)) }
                    }
                } label: {
                    StudioMenuLabel(title: sizeTitle(size))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            slider("Exposure", $design.exposure, -1...1)
            slider("Saturation", $design.saturation, -1...1)
            slider("Sharpen", $design.sharpen, 0...1)
            slider("Vignette", $design.vignette, 0...1)
            StudioSwitchRow(title: "Safe zone", isOn: $showSafe)
            StudioField(label: "Format") {
                StudioSegmented(options: [(ThumbnailMaker.Format.png, "PNG"), (.jpeg, "JPEG")], selection: $format)
            }
            HStack(spacing: 8) {
                Button("Save…", systemImage: "square.and.arrow.down", action: saveOne)
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                Menu {
                    Button("All Sizes…", systemImage: "square.grid.2x2", action: saveAllSizes)
                    Button("Same Design on Other Videos…", systemImage: "square.stack", action: batch)
                } label: {
                    StudioMenuLabel(title: String(localized: "More"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            .padding(.top, 6)
            .disabled(preview == nil || progress != nil)
            if !saved.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(saved) } label: {
                    StudioChip(text: Text("Saved \(saved.count)"), symbol: "checkmark", colour: Design.Studio.good, tinted: true)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
    }

    private func sizeTitle(_ option: ThumbnailMaker.Size) -> String {
        "\(String(localized: option.name)) · \(Int(option.pixels.width))×\(Int(option.pixels.height))"
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title).foregroundStyle(Design.Studio.textQuiet))
            .textFieldStyle(.plain)
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .studioBox()
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        StudioField(label: title) { StudioSlider(value: value, range: range, label: title).frame(width: 150) }
    }

    // MARK: - Work

    private func analyse() async {
        picks = []; chosen = nil; frame = nil; preview = nil; problem = nil; saved = []
        guard let video else { return }
        guard let ffmpeg else { problem = String(localized: "Pluck needs its helper tools for this."); return }
        progress = 0
        do {
            let found = try await ThumbnailMaker.candidates(video, ffmpeg: ffmpeg) { p in Task { @MainActor in if progress != nil { progress = p } } }
            guard !Task.isCancelled else { return }
            picks = found
            progress = nil
            if let best = found.first { choose(best) } else { problem = String(localized: "No usable frame in this video.") }
        } catch {
            progress = nil
            if !Task.isCancelled { problem = error.localizedDescription }
        }
    }

    private func choose(_ sample: ThumbnailMaker.Sample) {
        chosen = sample
        guard let video else { return }
        Task {
            let full = await ThumbnailMaker.frame(video, at: sample.time)
            if chosen?.time == sample.time { frame = full ?? sample.image }
        }
    }

    private var brand: ThumbnailMaker.Brand { ThumbnailMaker.Brand(profile: profiles.profile(brandID)) }

    private func renderPreview() async {
        guard let frame, let chosen else { return }
        let design = design, size = size, brand = brand
        // Half size while designing: everything in the layout scales with the picture.
        let canvas = CGSize(width: size.pixels.width / 2, height: size.pixels.height / 2)
        let rendered = await Task.detached { ThumbnailMaker.render(frame, focus: chosen.focus, design: design, brand: brand, size: size, canvas: canvas) }.value
        if !Task.isCancelled { preview = rendered }
    }

    private func render(_ size: ThumbnailMaker.Size) -> ThumbnailMaker.Rendered? {
        guard let frame, let chosen else { return nil }
        return ThumbnailMaker.render(frame, focus: chosen.focus, design: design, brand: brand, size: size)
    }

    private func saveOne() {
        guard let video, let rendered = render(size) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ThumbnailMaker.fileName(video, size, format)
        panel.allowedContentTypes = [format.type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThumbnailMaker.write(rendered.image, to: url, format: format)
            saved = [url]
        } catch { problem = error.localizedDescription }
    }

    private func saveAllSizes() {
        guard let video, let folder = pickFolder() else { return }
        saved = ThumbnailMaker.Size.allCases.compactMap { option in
            let url = folder.appendingPathComponent(ThumbnailMaker.fileName(video, option, format))
            guard let rendered = render(option), (try? ThumbnailMaker.write(rendered.image, to: url, format: format)) != nil else { return nil }
            return url
        }
    }

    private func batch() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        panel.message = String(localized: "Videos to give the same design")
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let folder = pickFolder(), let ffmpeg else { return }
        let videos = panel.urls, design = design, brand = brand, size = size, format = format
        progress = 0
        Task {
            saved = await ThumbnailMaker.batch(videos, design: design, brand: brand, sizes: [size], format: format, to: folder, ffmpeg: ffmpeg) { p in
                Task { @MainActor in if progress != nil { progress = p } }
            }
            progress = nil
        }
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url { video = url }
    }
}
