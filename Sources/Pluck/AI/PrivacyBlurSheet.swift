import SwiftUI

/// Privacy Blur: finds the faces first, then lets the user keep chosen people sharp.
struct PrivacyBlurSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("blurStyle") private var style: PrivacyBlur.Style = .blur
    @AppStorage("blurText") private var blurText = false
    @State private var analysis: PrivacyBlur.Analysis?
    @State private var progress = 0.0
    @State private var problem: String?
    @State private var keepSharp: Set<Int> = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "eye.slash", title: Text("Privacy Blur"), subtitle: Text(item.title))

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let analysis {
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
                    studio.privacyBlur(item, analysis: analysis, keepSharp: keepSharp, blurText: blurText, style: style)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(analysis == nil || (analysis?.faces.count == keepSharp.count && !blurText))
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 540)
        .onAppear(perform: analyze)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private func faces(_ analysis: PrivacyBlur.Analysis) -> some View {
        if analysis.faces.isEmpty {
            Label("No faces found in this video.", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Faces found: click the people who should stay sharp.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                        ForEach(analysis.faces) { face in
                            faceButton(face)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
    }

    private func faceButton(_ face: PrivacyBlur.Track) -> some View {
        let sharp = keepSharp.contains(face.id)
        return Button {
            if sharp { keepSharp.remove(face.id) } else { keepSharp.insert(face.id) }
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
                            Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
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
                let found = try await Task.detached(priority: .userInitiated) {
                    try await PrivacyBlur.analyze(file) { value in
                        Task { @MainActor in progress = value }
                    }
                }.value
                analysis = found
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
