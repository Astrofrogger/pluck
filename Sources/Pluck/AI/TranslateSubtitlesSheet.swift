import SwiftUI
import Translation

/// Shown when .srt or .vtt files are dropped on the window: translate them to another language
/// with local AI. The translations are saved next to the originals.
struct TranslateSubtitlesSheet: View {
    let files: [URL]

    var body: some View {
        if #available(macOS 15, *) {
            TranslateSubtitlesForm(files: files)
        } else {
            UnavailableTranslation()
        }
    }
}

private struct UnavailableTranslation: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Translating subtitles needs macOS 15 or later.", systemImage: "character.bubble")
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

@available(macOS 15, *)
private struct TranslateSubtitlesForm: View {
    @Environment(\.dismiss) private var dismiss
    let files: [URL]

    @State private var languages: [Locale.Language] = []
    @State private var source: Locale.Language?
    @State private var target: Locale.Language?
    @AppStorage("subtitleTranslationTarget") private var lastTarget = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var done = 0
    @State private var running = false
    @State private var problem: String?
    @State private var unsupported = false

    private var heading: String {
        files.count == 1
            ? String(localized: "Translate “\(files[0].lastPathComponent)”")
            : String(localized: "Translate \(files.count) Subtitle Files")
    }

    private var canStart: Bool {
        guard let source, let target else { return false }
        return !running && !unsupported && source.languageCode != target.languageCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "character.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if files.count > 1 {
                        Text(files.map(\.lastPathComponent).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Form {
                Picker("From", selection: $source) {
                    if languages.isEmpty { Text("Loading…").tag(Locale.Language?.none) }
                    ForEach(languages, id: \.minimalIdentifier) { Text(name(of: $0)).tag(Optional($0)) }
                }
                Picker("To", selection: $target) {
                    if languages.isEmpty { Text("Loading…").tag(Locale.Language?.none) }
                    ForEach(languages, id: \.minimalIdentifier) { Text(name(of: $0)).tag(Optional($0)) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(running)

            if unsupported {
                Label("This Mac can’t translate between these languages.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Translated on this Mac with local AI: Apple’s on-device translation. Nothing is uploaded. The translation is saved next to the original.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if running {
                    ProgressView(value: Double(done), total: Double(files.count))
                        .frame(width: 120)
                    Text(files.count > 1 ? String(localized: "Translating \(done + 1) of \(files.count)…") : String(localized: "Translating…"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Translate", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await load() }
        .task(id: "\(source?.minimalIdentifier ?? "")>\(target?.minimalIdentifier ?? "")") { await checkPair() }
        // macOS asks to download the languages first if they aren't on this Mac yet.
        .translationTask(configuration) { session in
            await translate(with: session)
        }
    }

    private func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func load() async {
        let supported = await LanguageAvailability().supportedLanguages
        languages = supported.sorted { name(of: $0) < name(of: $1) }
        let detected = files.lazy.compactMap { try? SubtitleFiles.cues(in: $0) }.first.flatMap(SubtitleFiles.language(of:))
        func match(_ language: Locale.Language?) -> Locale.Language? {
            guard let language else { return nil }
            return languages.first { $0.minimalIdentifier == language.minimalIdentifier }
                ?? languages.first { $0.languageCode == language.languageCode }
        }
        source = match(detected) ?? match(Locale.Language(identifier: "en"))
        let preferred = lastTarget.isEmpty ? nil : Locale.Language(identifier: lastTarget)
        target = [preferred, Locale.current.language, Locale.Language(identifier: "en")]
            .compactMap(match)
            .first { $0.languageCode != source?.languageCode }
    }

    private func checkPair() async {
        guard let source, let target else { return }
        unsupported = await LanguageAvailability().status(from: source, to: target) == .unsupported
    }

    private func start() {
        guard let source, let target else { return }
        problem = nil
        lastTarget = target.minimalIdentifier
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func translate(with session: TranslationSession) async {
        guard let target else { return }
        await MainActor.run { running = true; done = 0 }
        var outputs: [URL] = []
        var failures: [String] = []
        for file in files {
            do {
                outputs.append(try await SubtitleFiles.translate(file, to: target, session: session))
            } catch {
                failures.append(error.localizedDescription)
            }
            await MainActor.run { done += 1 }
        }
        await MainActor.run {
            running = false
            if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            if failures.isEmpty {
                dismiss()
            } else {
                problem = failures.joined(separator: "\n")
            }
        }
    }
}
