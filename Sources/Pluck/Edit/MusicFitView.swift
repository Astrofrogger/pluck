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
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "music.note.list", title: Text("Fit Music to Length"), subtitle: Text("Shortens or lengthens a song on its phrases, keeping the intro and the real ending."), subtitleIsName: false)
            Form {
                LabeledContent("Song") {
                    HStack {
                        Text(song?.lastPathComponent ?? String(localized: "None")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(song == nil ? "Choose…" : "Change…", action: choose)
                    }
                }
                LabeledContent("Length") {
                    HStack(spacing: 4) {
                        TextField("Minutes", value: $minutes, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                        Text(":")
                        TextField("Seconds", value: $seconds, format: .number.precision(.integerLength(2))).frame(width: 44)
                    }
                    .labelsHidden()
                }
            }
            .formStyle(.grouped)
            .disabled(task != nil)

            if let status {
                HStack { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let done {
                VStack(alignment: .leading, spacing: 4) {
                    Label(done.file.lastPathComponent, systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text(describe(done.edit)).font(.callout).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done.file]) }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Label("Runs on this Mac.", systemImage: "lock.shield").noteStyle()
                Spacer()
                Button("Fit", action: fit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(song == nil || target < 5 || task != nil)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(minWidth: 520, minHeight: 380)
    }

    private func describe(_ edit: MusicFit.Edit) -> String {
        func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
        var parts: [String] = []
        if edit.pieces.count > 1, let first = edit.pieces.first, let second = edit.pieces.last {
            parts.append(second.lowerBound > first.upperBound
                ? String(localized: "Skips \(time(first.upperBound))–\(time(second.lowerBound)).")
                : String(localized: "Repeats \(time(second.lowerBound))–\(time(first.upperBound))."))
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
                    throw FitFailure()
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

    private struct FitFailure: LocalizedError {
        var errorDescription: String? {
            String(localized: "Couldn’t find a steady beat in this song, or the length is too far from the original to cut on its phrases.")
        }
    }
}
