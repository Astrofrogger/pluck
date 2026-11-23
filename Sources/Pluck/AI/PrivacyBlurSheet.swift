import AVFoundation
import CoreImage
import SwiftUI

/// Privacy Blur: finds the faces first, shows the result on a frame to scrub through, lets the
/// user keep chosen people sharp, draw a region it missed (followed from there) or take one away,
/// and saves the blurred video, a matte for Resolve, or both.
struct PrivacyBlurSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("blurStyle") private var style: PrivacyBlur.Style = .blur
    @AppStorage("blurText") private var blurText = false
    @AppStorage("blurOutput") private var output: Output = .video
    @State private var analysis: PrivacyBlur.Analysis?
    @State private var progress = 0.0
    @State private var problem: String?
    @State private var keepSharp: Set<Int> = []
    @State private var task: Task<Void, Never>?
    /// The preview: where it is, how long the video is, the frame as it comes out.
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var preview: CGImage?
    /// Bumped when regions are added or taken away (the analysis is a class).
    @State private var revision = 0
    @State private var drawing: CGRect?
    @State private var following = false

    enum Output: String, CaseIterable, Identifiable {
        case video, both, matte
        var id: String { rawValue }
        var label: String {
            switch self {
            case .video: String(localized: "Blurred video")
            case .both: String(localized: "Video and matte")
            case .matte: String(localized: "Matte")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "eye.slash", title: Text("Privacy Blur"), subtitle: Text(item.title))

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let analysis {
                previewView(analysis)
                faces(analysis)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Looking for faces…").foregroundStyle(.secondary)
                    ProgressView(value: progress)
                }
                .padding(.vertical, 8)
            }

            Form {
                Picker("Style", selection: $style) {
                    ForEach(PrivacyBlur.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $blurText) {
                    Text("Also blur text")
                    Text("Licence plates, name tags, screens and signs. Titles and captions in the video are blurred too.")
                }
                Picker(selection: $output) {
                    ForEach(Output.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Save")
                    Text("A matte is white where it blurs, to finish the blur in DaVinci Resolve.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Runs entirely on this Mac with local AI. Check the result before sharing it: a face that’s turned away or very small can be missed. The original isn’t changed.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Blur") {
                    guard let analysis else { return }
                    if output != .matte {
                        studio.privacyBlur(item, analysis: analysis, keepSharp: keepSharp, blurText: blurText, style: style)
                    }
                    if output != .video {
                        studio.privacyMatte(item, analysis: analysis, keepSharp: keepSharp, blurText: blurText)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(analysis == nil || following || (analysis?.faces.count == keepSharp.count && !blurText))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
        .onAppear(perform: analyze)
        .onDisappear { task?.cancel() }
        .task(id: "\(time)-\(revision)-\(keepSharp.count)-\(blurText)-\(style.rawValue)-\(analysis == nil)") { await renderPreview() }
    }

    // MARK: - Preview

    /// The frame as it will come out, with the regions outlined: click one to keep it sharp (or
    /// blur it again), drag over something missed to add it.
    private func previewView(_ analysis: PrivacyBlur.Analysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)
                    } else {
                        Rectangle().fill(.black)
                    }
                    ForEach(regions(analysis), id: \.id) { region in
                        let rect = viewRect(region.box, in: size)
                        let sharp = keepSharp.contains(region.id)
                        Rectangle()
                            .strokeBorder(sharp ? Color.green : Color.white, style: StrokeStyle(lineWidth: 1.5, dash: sharp ? [4] : []))
                            .contentShape(.rect)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { toggle(region.id) }
                            .help(sharp ? "Stays sharp. Click to blur." : "Blurred. Click to keep sharp.")
                    }
                    if let drawing {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: drawing.width, height: drawing.height)
                            .offset(x: drawing.minX, y: drawing.minY)
                    }
                    if following {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Following…")
                        }
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: .capsule)
                        .padding(8)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { drawing = CGRect(origin: $0.startLocation, size: .zero).union(CGRect(origin: $0.location, size: .zero)) }
                    .onEnded { _ in
                        if let drawing { add(drawing, in: size, analysis: analysis) }
                        drawing = nil
                    })
            }
            // (A set size: in a sheet a GeometryReader would otherwise be squeezed to nothing.)
            .frame(width: 512, height: 512 / previewAspect)
            .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
            .disabled(following)
            HStack(spacing: 8) {
                Slider(value: $time, in: 0...max(duration, 0.1))
                    .controlSize(.small)
                Text(Format.duration(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Drag over anything missed to blur it too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewAspect: CGFloat {
        guard let preview, preview.height > 0 else { return 16 / 9 }
        return CGFloat(preview.width) / CGFloat(preview.height)
    }

    /// The regions on screen now.
    private func regions(_ analysis: PrivacyBlur.Analysis) -> [(id: Int, box: CGRect)] {
        _ = revision
        return analysis.faces.compactMap { face in face.box(at: time, hold: face.manual ? analysis.step : 0.4).map { (face.id, $0) } }
    }

    /// A box (0…1, origin bottom left) on the preview (points, origin top left).
    private func viewRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    private func toggle(_ id: Int) {
        if keepSharp.contains(id) { keepSharp.remove(id) } else { keepSharp.insert(id) }
    }

    /// A region drawn on the preview, followed through the video from here.
    private func add(_ drawn: CGRect, in size: CGSize, analysis: PrivacyBlur.Analysis) {
        guard let file = item.existingFile, drawn.width > 8, drawn.height > 8, size.width > 0, size.height > 0 else { return }
        let clipped = drawn.intersection(CGRect(origin: .zero, size: size))
        let box = CGRect(x: clipped.minX / size.width, y: 1 - clipped.maxY / size.height,
                         width: clipped.width / size.width, height: clipped.height / size.height)
        let id = (analysis.faces.map(\.id).max() ?? 0) + 1
        let at = time, step = analysis.step
        following = true
        Task {
            let track = await Task.detached(priority: .userInitiated) {
                await PrivacyBlur.follow(file, box: box, at: at, step: step, id: id)
            }.value
            analysis.faces.append(track)
            revision += 1
            following = false
        }
    }

    private func renderPreview() async {
        guard let analysis, let file = item.existingFile else { return }
        // A moment's pause while scrubbing.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        let painter = PrivacyBlur.Painter(analysis: analysis, keepSharp: keepSharp, blurText: blurText, style: style)
        let at = time
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1024, height: 1024)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let frame = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image else { return nil }
            let painted = painter.paint(CIImage(cgImage: frame), at: at)
            return CIContext().createCGImage(painted, from: painted.extent)
        }.value
        if !Task.isCancelled, let image { preview = image }
    }

    // MARK: - Faces

    @ViewBuilder
    private func faces(_ analysis: PrivacyBlur.Analysis) -> some View {
        let all = { _ = revision; return analysis.faces }()
        if all.isEmpty {
            Label("No faces found in this video.", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Faces found: click the people who should stay sharp.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                        ForEach(all) { face in
                            faceButton(face, analysis: analysis)
                        }
                    }
                }
                .frame(height: 112)
            }
        }
    }

    private func faceButton(_ face: PrivacyBlur.Track, analysis: PrivacyBlur.Analysis) -> some View {
        let sharp = keepSharp.contains(face.id)
        return Button {
            toggle(face.id)
            time = face.start
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let thumbnail = face.thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: sharp ? 0 : 6)
                        } else {
                            Image(systemName: face.manual ? "rectangle.dashed" : "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
                    Image(systemName: sharp ? "eye.circle.fill" : "eye.slash.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, sharp ? Color.green : Color.secondary)
                        .padding(3)
                }
                .overlay(alignment: .topLeading) {
                    if face.manual {
                        Button {
                            analysis.faces.removeAll { $0.id == face.id }
                            keepSharp.remove(face.id)
                            revision += 1
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .help("Take this region away")
                    }
                }
                Text(Format.duration(face.start) + "–" + Format.duration(face.end))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(sharp ? "Stays sharp. Click to blur." : "Blurred. Click to keep sharp.")
        .accessibilityLabel(sharp ? "Face from \(Format.duration(face.start)), kept sharp" : "Face from \(Format.duration(face.start)), blurred")
    }

    private func analyze() {
        guard let file = item.existingFile else { return }
        task = Task {
            do {
                duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
                let found = try await Task.detached(priority: .userInitiated) {
                    try await PrivacyBlur.analyze(file) { value in
                        Task { @MainActor in progress = value }
                    }
                }.value
                analysis = found
                // Screenshots: -PluckScreenshotBlurAt <seconds> shows the preview there.
                if let at = UserDefaults.standard.string(forKey: "PluckScreenshotBlurAt").flatMap(Double.init) { time = at }
                else if let first = found.faces.first { time = first.start }
                // Screenshots: -PluckScreenshotBlurDraw <x,y,w,h> (0…1 of the picture, from the top left) draws a region.
                if let box = UserDefaults.standard.string(forKey: "PluckScreenshotBlurDraw")?.split(separator: ",").compactMap({ Double($0) }), box.count == 4 {
                    add(CGRect(x: box[0] * 1000, y: box[1] * 1000, width: box[2] * 1000, height: box[3] * 1000),
                        in: CGSize(width: 1000, height: 1000), analysis: found)
                }
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
