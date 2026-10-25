import SwiftUI

/// The voice-over bar of a project: choose the microphone, then Record; a 3-2-1; the level and
/// the clock while it records; Stop. It sits in the page above the timeline.
struct VoiceOverBar: View {
    var recorder: VoiceOverRecorder
    var model: ProjectModel
    @Binding var muteTimeline: Bool
    var close: () -> Void

    var body: some View {
        HStack(spacing: Design.Spacing.controls) {
            switch recorder.state {
            case .idle: idle
            case .countingDown(let number): counting(number)
            case .recording: recording
            case .failed(let message): failed(message)
            }
        }
        .frame(minHeight: Design.Size.control)
        .padding(.horizontal, Design.Spacing.inset)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Design.Radius.card))
        .onAppear { recorder.refreshInputs() }
    }

    // MARK: - States

    private var idle: some View {
        Group {
            inputPicker
            muteToggle
            Spacer(minLength: 8)
            Button { record() } label: { Label("Record", systemImage: "circle.fill") }
                .buttonStyle(BarCapsuleButtonStyle(tint: .red))
                .help("Record a voice-over from the playhead; the timeline plays while you speak (Space or Esc stops)")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(BarButtonStyle())
                .help("Close")
        }
    }

    private func counting(_ number: Int) -> some View {
        Group {
            Text(verbatim: "\(number)")
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .foregroundStyle(Design.Brand.pink)
                .frame(width: Design.Size.control)
                .contentTransition(.numericText())
                .animation(.snappy, value: number)
            Text("Get ready").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            stopButton
        }
    }

    private var recording: some View {
        Group {
            Circle().fill(Design.Brand.gradient).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(model.timecode(max(context.date.timeIntervalSince(recorder.startedAt), 0), full: true))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
            }
            .fixedSize()
            LevelMeter(level: recorder.level)
            stopButton
        }
    }

    private func failed(_ message: String) -> some View {
        Group {
            ProblemLabel(text: message)
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(BarButtonStyle())
                .help("Close")
        }
    }

    // MARK: - Pieces

    private var inputPicker: some View {
        BarPicker(symbol: "mic", label: Text("Microphone"),
                  selection: Binding(get: { recorder.input }, set: { recorder.input = $0 }),
                  current: Text(recorder.input?.name ?? String(localized: "No microphone"))) {
            ForEach(recorder.inputs) { Text($0.name).tag(Optional($0)) }
        }
        .help("The microphone to record from")
    }

    private var muteToggle: some View {
        Button { muteTimeline.toggle() } label: {
            Image(systemName: muteTimeline ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(BarButtonStyle())
        .help(muteTimeline ? "The timeline is silent while you record (on headphones, leave it playing)" : "The timeline plays while you record (use headphones, or the microphone hears it)")
    }

    private var stopButton: some View {
        Button { Task { await recorder.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
            .buttonStyle(BarCapsuleButtonStyle(tint: .red))
            .help("Stop recording (Space or Esc)")
    }

    private func record() {
        recorder.start(at: model.time, in: model, muteTimeline: muteTimeline)
    }
}

/// The input's level as a bar.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Design.Brand.gradient)
                    .frame(width: max(proxy.size.width * CGFloat(level), 6))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Level")
    }
}
