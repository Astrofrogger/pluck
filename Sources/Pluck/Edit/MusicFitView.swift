import SwiftUI

/// Fit Music to Length: a song in, the same song at an exact length out, cut on phrases with
/// its intro and real ending kept.
struct MusicFitView: View {
    @Environment(AIStudio.self) private var studio
    @State private var song: URL?
    @State private var minutes = 1
    @State private var seconds = 0
    @State private var status: String?
    @State private var problem: String?
    @State private var done: (file: URL, edit: MusicFit.Edit)?
    @State private var task: Task<Void, Never>?

    private var target: Double { Double(minutes * 60 + seconds) }

    var body: some View {
        ToolPage(maxWidth: 680) {
            ToolWelcome(symbol: "music.note.list", title: Text("Fit Music to Length"),
                        subtitle: Text("Shortens or lengthens a song on its phrases, keeping the intro and the real ending."))
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    FileCapsule(file: song, symbol: "music.note", placeholder: Text("Choose a song"))
                    Button(song == nil ? "Choose…" : "Change…", action: choose)
                        .buttonStyle(GlassCapsuleButtonStyle())
                    HStack(spacing: 2) {
                        Image(systemName: "timer").foregroundStyle(.secondary).accessibilityHidden(true)
                            .padding(.trailing, 4)
                        TextField("Minutes", value: $minutes, format: .number)
                            .frame(width: 28).multilineTextAlignment(.trailing)
                        Text(verbatim: ":")
                        TextField("Seconds", value: $seconds, format: .number.precision(.integerLength(2)))
                            .frame(width: 28)
                    }
                    .textFieldStyle(.plain)
                    .font(Design.Typography.control.monospacedDigit())
                    .labelsHidden()
                    .barControl()
                    .fixedSize()
                    .help("The new length, in minutes and seconds")
                    Button("Fit", systemImage: "scissors", action: fit)
                        .buttonStyle(BarCapsuleButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(song == nil || target < 5 || task != nil)
                }
            }
            .disabled(task != nil)
            if let status, let song {
                ItemRow(symbol: "music.note", title: Text(song.lastPathComponent), subtitle: Text(status)) {
                    ProgressView().progressViewStyle(.linear).padding(.top, 4)
                } actions: {
                    EmptyView()
                }
            }
            if let problem { ProblemLabel(text: problem) }
            if let done {
                ItemRow(symbol: "checkmark", tint: .green, title: Text(done.file.lastPathComponent), subtitle: Text(describe(done.edit))) {
                    EmptyView()
                } actions: {
                    RowButton(symbol: "magnifyingglass", label: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([done.file])
                    }
                }
            }
            PageNote(text: Text("Runs on this Mac."), symbol: "desktopcomputer")
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func describe(_ edit: MusicFit.Edit) -> String {
        func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
        var parts: [String] = []
        if let first = edit.pieces.first, first.lowerBound > 0 {
            parts.append(String(localized: "Starts at \(time(first.lowerBound))."))
        }
        if edit.pieces.count > 1, let first = edit.pieces.first, let second = edit.pieces.last {
            if second.lowerBound > first.upperBound {
                parts.append(String(localized: "Skips \(time(first.upperBound))–\(time(second.lowerBound))."))
            } else {
                let times = edit.pieces.count - 1
                parts.append(String(AttributedString(localized: "Repeats \(time(second.lowerBound))–\(time(first.upperBound)) ^[\(times) time](inflect: true).").characters))
            }
        }
        if edit.fadeOut != nil { parts.append(String(localized: "Too short for the real ending, so it fades out.")) }
        let change = (edit.tempo - 1) * 100
        if abs(change) >= 0.1 {
            parts.append(String(localized: "Tempo \(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) % (pitch unchanged)."))
        }
        return parts.joined(separator: " ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        song = url
        done = nil
    }

    private func fit() {
        guard let song, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        problem = nil
        done = nil
        let target = target
        status = String(localized: "Finding the beat and the phrases…")
        task = Task {
            do {
                let features = AudioFeatures(samples: try await AudioFeatures.samples(of: song, ffmpeg: ffmpeg))
                let map = MusicMap(features: features)
                guard let edit = MusicFit.plan(map: map, features: features, duration: features.duration, target: target) else {
                    throw MusicFit.problem(map: map, target: target)
                }
                status = String(localized: "Writing the new version…")
                let label = Duration.seconds(target).formatted(.time(pattern: .minuteSecond)).replacingOccurrences(of: ":", with: "m") + "s"
                let ext = ["wav", "aif", "aiff", "flac"].contains(song.pathExtension.lowercased()) ? "wav" : "m4a"
                let output = song.deletingLastPathComponent()
                    .appendingPathComponent(song.deletingPathExtension().lastPathComponent + " (\(label))")
                    .appendingPathExtension(ext)
                try await MusicFit.render(edit, input: song, output: output, ffmpeg: ffmpeg)
                done = (output, edit)
            } catch {
                problem = error.localizedDescription
            }
            status = nil
            task = nil
        }
    }
}
