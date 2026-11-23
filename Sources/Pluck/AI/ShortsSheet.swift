import AVKit
import SwiftUI

/// Make Shorts: how many vertical clips, how long, and how they're captioned. For one video the
/// moments are found first and shown to go through (keep or drop, move the in and out, swap for
/// another), then made; several videos are made straight away.
struct ShortsSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    /// Only from this part of the video (the Editor's range or a best moment).
    var range: ClosedRange<Double>?
    @AppStorage("shortsCount") private var count = 3
    @AppStorage("shortsLength") private var length: Shorts.Length = .medium
    @AppStorage("shortsCaptionsOn") private var captionsOn = true
    @State private var design = CaptionDesign.load(CaptionDesign.shortsKey)
    @AppStorage("shortsFraming") private var framing: Shorts.FramingChoice = .automatic
    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var review: Review?
    @State private var finding = false
    @State private var problem: String?
    @State private var task: Task<Void, Never>?

    init(item: DownloadItem, range: ClosedRange<Double>? = nil) {
        items = [item]
        self.range = range
    }

    init(items: [DownloadItem]) {
        self.items = items
    }

    /// The moments found, as they're being gone through.
    struct Review {
        struct Row: Identifiable {
            let id = UUID()
            var moment: Shorts.Moment
            var keep = true
        }
        var rows: [Row]
        /// Other good moments, to swap in.
        var others: [Shorts.Moment]
        var duration: Double
    }

    private var item: DownloadItem { items[0] }

    /// Shorts need a transcript; without one yet, ask which language is spoken.
    private var needsLanguage: Bool {
        LocalAI.canTranscribe && items.contains { $0.transcriptID.flatMap(TranscriptStore.load)?.filePath != $0.existingFile?.path }
    }

    /// The picked range is short enough to be one short as it is.
    private var rangeIsOneShort: Bool {
        range.map { $0.upperBound - $0.lowerBound <= length.range.upperBound } ?? false
    }

    private var options: Shorts.Options {
        Shorts.Options(count: rangeIsOneShort ? 1 : count, length: length, captions: captionsOn ? design : nil,
                       framing: framing, language: needsLanguage ? language : nil, range: range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "rectangle.portrait.on.rectangle.portrait.angled", title: Text("Make Shorts"),
                        subtitle: Text(AIStudio.Batch(items).title))
            if let review {
                ShortsReview(file: item.existingFile, review: Binding(get: { review }, set: { self.review = $0 }))
            } else {
                settings
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            buttons
        }
        .padding(Design.Spacing.sheet)
        .frame(width: review == nil ? 460 : 560)
        .onDisappear { task?.cancel() }
        .task {
            // Screenshots: -PluckScreenshotShortsReview YES finds the moments straight away.
            if ScreenshotMode.scene == "shorts", UserDefaults.standard.bool(forKey: "PluckScreenshotShortsReview") { find() }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            Form {
                if needsLanguage {
                    SpokenLanguagePicker(item: item, languages: $languages, language: $language)
                }
                if let range {
                    LabeledContent("Part") {
                        Text(Format.duration(range.lowerBound) + "–" + Format.duration(range.upperBound)).monospacedDigit()
                    }
                }
                if !rangeIsOneShort {
                    Stepper(value: $count, in: 1...5) {
                        LabeledContent("Number of shorts") { Text("\(count)").monospacedDigit() }
                    }
                    Picker("Length", selection: $length) {
                        ForEach(Shorts.Length.allCases) { Text($0.label).tag($0) }
                    }
                }
                Picker(selection: $framing) {
                    ForEach(Shorts.FramingChoice.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Framing")
                    Text(framing.detail)
                }
                Section {
                    Toggle("Captions", isOn: $captionsOn)
                    if captionsOn {
                        CaptionDesignEditor(design: $design, forShorts: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if finding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(item.aiStatus ?? String(localized: "Choosing the best moments…")).foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Label(LocalAI.canSummarize
                      ? "Local AI on this Mac picks the best moments from what’s said, keeps the subject in frame and captions every word. Nothing is uploaded."
                      : "Pluck picks the busiest moments, keeps the subject in frame and captions every word, all on this Mac. With Apple Intelligence on, local AI picks moments by what’s said.",
                      systemImage: "lock.shield")
                    .noteStyle()
            }
        }
    }

    private var buttons: some View {
        HStack {
            if review != nil {
                Button("Back") { review = nil }
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                task?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if let review {
                let kept = review.rows.filter(\.keep).map(\.moment)
                Button(kept.count == 1 ? "Make 1 Short" : "Make \(kept.count) Shorts") {
                    studio.makeShorts(item, options: options, reviewed: kept.sorted { $0.start < $1.start })
                    design.save(CaptionDesign.shortsKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(kept.isEmpty)
            } else if items.count == 1 {
                Button("Find Moments", action: find)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(finding || item.aiStatus != nil)
            } else {
                Button("Make Shorts") {
                    studio.makeShorts(items, options: options)
                    design.save(CaptionDesign.shortsKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The transcript (made now if there's none), then the moments to go through.
    private func find() {
        guard #available(macOS 26, *), let file = item.existingFile else { return }
        let options = options
        finding = true
        problem = nil
        task = Task {
            do {
                let transcript = try await studio.existingOrNewTranscript(for: item, file: file, language: options.language)
                item.aiStatus = String(localized: "Choosing the best moments…")
                item.aiProgress = nil
                let all = await Shorts.candidates(in: transcript, options: options)
                item.aiStatus = nil
                guard !all.isEmpty else { throw LocalAI.Failure.noSpeech }
                let picks = all.prefix(options.count).sorted { $0.start < $1.start }
                review = Review(rows: picks.map { Review.Row(moment: $0) }, others: Array(all.dropFirst(options.count)),
                                duration: transcript.duration ?? item.duration ?? transcript.words.last?.e ?? 0)
            } catch is CancellationError {
                item.aiStatus = nil
            } catch {
                item.aiStatus = nil
                problem = error.localizedDescription
            }
            item.aiProgress = nil
            finding = false
        }
    }
}

/// The moments found: each one seen (a click plays it), kept or dropped, its in and out moved,
/// its title (the file's name) changed, or swapped for another good moment.
private struct ShortsReview: View {
    let file: URL?
    @Binding var review: ShortsSheet.Review
    @State private var player: AVPlayer?
    @State private var playing: UUID?
    @State private var stopper: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($review.rows) { $row in
                        line($row)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .onAppear {
            if let file { player = AVPlayer(url: file) }
        }
        .onDisappear { player?.pause() }
    }

    private func line(_ row: Binding<ShortsSheet.Review.Row>) -> some View {
        let moment = row.wrappedValue.moment
        return HStack(spacing: 10) {
            Toggle("", isOn: row.keep)
                .labelsHidden()
                .help("Make this short")
            Button { play(row.wrappedValue) } label: {
                ZStack {
                    MomentThumbnail(file: file, time: moment.start)
                    Image(systemName: playing == row.wrappedValue.id ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .buttonStyle(.plain)
            .help("Play this moment")
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: row.moment.title)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    nudge(row, start: true)
                    Text(Format.duration(moment.start) + "–" + Format.duration(moment.end))
                        .monospacedDigit()
                    nudge(row, start: false)
                    Text(verbatim: "· \(Int((moment.end - moment.start).rounded())) s").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !review.others.isEmpty {
                Menu {
                    ForEach(Array(review.others.enumerated()), id: \.offset) { index, other in
                        Button(Format.duration(other.start) + "  " + other.title) { swap(row, with: index) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Swap for another moment")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.fill.quaternary))
        .opacity(row.wrappedValue.keep ? 1 : 0.5)
    }

    /// −/+ a second on the in (start) or the out.
    private func nudge(_ row: Binding<ShortsSheet.Review.Row>, start: Bool) -> some View {
        HStack(spacing: 0) {
            Button { move(row, start: start, by: -1) } label: { Image(systemName: "minus") }
                .help(start ? "Start a second earlier" : "End a second earlier")
            Button { move(row, start: start, by: 1) } label: { Image(systemName: "plus") }
                .help(start ? "Start a second later" : "End a second later")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
    }

    private func move(_ row: Binding<ShortsSheet.Review.Row>, start: Bool, by delta: Double) {
        row.wrappedValue.moment = Shorts.nudged(row.wrappedValue.moment, start: start, by: delta, duration: review.duration)
    }

    private func swap(_ row: Binding<ShortsSheet.Review.Row>, with index: Int) {
        let old = row.wrappedValue.moment
        row.wrappedValue.moment = review.others[index]
        review.others[index] = old
    }

    /// Plays the moment from its in to its out (a second click stops it).
    private func play(_ row: ShortsSheet.Review.Row) {
        guard let player else { return }
        if let stopper { player.removeTimeObserver(stopper) }
        stopper = nil
        if playing == row.id {
            player.pause()
            playing = nil
            return
        }
        playing = row.id
        player.seek(to: CMTime(seconds: row.moment.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        stopper = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: row.moment.end, preferredTimescale: 600))], queue: .main) {
            MainActor.assumeIsolated {
                player.pause()
                playing = nil
            }
        }
        player.play()
    }
}

/// A frame from the start of a moment.
private struct MomentThumbnail: View {
    let file: URL?
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(.rect(cornerRadius: Design.Radius.small))
        .task(id: time) {
            guard let file else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            image = try? await generator.image(at: CMTime(seconds: time + 0.5, preferredTimescale: 600)).image
        }
    }
}
