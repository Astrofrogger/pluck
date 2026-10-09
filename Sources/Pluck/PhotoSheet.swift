import SwiftUI

/// Compress photos dropped on the window (or chosen in File → Convert Files…). The size
/// estimate is measured, not guessed: the photos are compressed in memory with the current
/// settings, and the result is what you'll get.
struct PhotoSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("photoFormat") private var format: Photos.Format = .jpeg
    @AppStorage("photoQuality") private var quality = 75
    @AppStorage("photoMaxPixel") private var maxPixel = 0
    @AppStorage("photoRemoveDetails") private var removeDetails = false
    @State private var estimate: (original: Int64, result: Int64)?
    let files: [URL]

    /// Measuring every photo of a big batch takes long; a sample gives the ratio for the rest.
    private static let sampleSize = 12

    private var settings: Photos.Settings {
        Photos.Settings(format: format, quality: Double(quality) / 100, maxPixel: maxPixel > 0 ? maxPixel : nil,
                        removeDetails: removeDetails)
    }

    private var heading: String {
        files.count == 1
            ? String(localized: "Compress “\(files[0].lastPathComponent)”")
            : String(localized: "Compress \(files.count) Photos")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: files.first?.path ?? ""))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Form {
                Picker("Format", selection: $format) {
                    Text("JPEG (works everywhere)").tag(Photos.Format.jpeg)
                    Text("HEIC (smaller, Apple devices)").tag(Photos.Format.heic)
                }
                LabeledContent("Quality") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 10...100, step: 5)
                            .accessibilityValue("\(quality)%")
                        Text("\(quality)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Maximum size", selection: $maxPixel) {
                    Text("Original").tag(0)
                    ForEach(Photos.sizes, id: \.self) { Text("\($0) px").tag($0) }
                }
                .help("The longest side of the photo")
                Toggle("Remove location and camera details", isOn: $removeDetails)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            calculator

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Compress") {
                    manager.compressPhotos(files, settings: settings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task(id: settings) { await measure() }
    }

    @ViewBuilder
    private var calculator: some View {
        if let estimate {
            let saved = max(estimate.original - estimate.result, 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.bytes(estimate.original)) → about \(Format.bytes(estimate.result))")
                    .font(.headline)
                    .contentTransition(.numericText())
                if estimate.result < estimate.original {
                    Text("Saves \(Format.bytes(saved)) (\(Int((Double(saved) / Double(max(estimate.original, 1)) * 100).rounded()))%)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("These settings make the photos bigger. Lower the quality or the size.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 4)
        }
    }

    /// Compresses a sample in memory with the current settings. Runs again (and the previous run
    /// is cancelled) whenever a setting changes.
    private func measure() async {
        try? await Task.sleep(for: .milliseconds(250))   // let the slider settle
        guard !Task.isCancelled else { return }
        let settings = settings
        let files = files
        let sample = Array(files.prefix(Self.sampleSize))
        let result = await Task.detached(priority: .userInitiated) { () -> (Int64, Int64)? in
            let sizes = files.map { DownloadManager.size(of: $0) ?? 0 }
            var sampleOriginal: Int64 = 0, sampleResult: Int64 = 0
            for (index, file) in sample.enumerated() {
                if Task.isCancelled { return nil }
                guard let data = Photos.compress(file, settings) else { continue }
                sampleOriginal += sizes[index]
                sampleResult += Int64(data.count)
            }
            let total = sizes.reduce(0, +)
            guard sampleOriginal > 0 else { return (total, total) }
            return (total, Int64(Double(total) * Double(sampleResult) / Double(sampleOriginal)))
        }.value
        guard !Task.isCancelled, let result else { return }
        withAnimation(.snappy) { estimate = result }
    }
}
