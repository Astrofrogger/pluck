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
    @State private var targets: [Locale.Language] = []
    @AppStorage("subtitleTranslationTarget") private var lastTarget = ""
    private static let targetsKey = "subtitleFileTranslateTo"
    /// Languages the source can't be translated into on this Mac.
    @State private var unavailable: Set<String> = []
    @State private var configuration: TranslationSession.Configuration?
    /// Languages still to do; the first is the one being translated.
    @State private var queue: [Locale.Language] = []
    @State private var outputs: [URL] = []
    @State private var failures: [String] = []
    @State private var done = 0
    @State private var running = false
    @State private var problem: String?

    private var heading: String {
        files.count == 1
            ? String(localized: "Translate “\(files[0].lastPathComponent)”")
            : String(localized: "Translate \(files.count) Subtitle Files")
    }

    /// The chosen languages this Mac can translate into.
    private var validTargets: [Locale.Language] {
        targets.filter { $0.languageCode != source?.languageCode && !unavailable.contains($0.minimalIdentifier) }
    }

    private var total: Int { max(files.count * max(validTargets.count, 1), 1) }

    private var canStart: Bool {
        source != nil && !running && !validTargets.isEmpty
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
                TranslationTargetsMenu(title: "To", selection: $targets, languages: languages,
                                       source: source, unavailable: unavailable, allowsNone: false)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(running)

            if !targets.isEmpty, validTargets.isEmpty, !running {
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
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(width: 120)
                    Text(total > 1 ? String(localized: "Translating \(min(done + 1, total)) of \(total)…") : String(localized: "Translating…"))
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
        .task(id: source?.minimalIdentifier) { await checkPairs() }
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
        var remembered = TranslationTargetsMenu.load(Self.targetsKey)
        if remembered.isEmpty, !lastTarget.isEmpty { remembered = [Locale.Language(identifier: lastTarget)] }
        targets = remembered.compactMap(match).filter { $0.languageCode != source?.languageCode }
        if targets.isEmpty {
            targets = [Locale.current.language, Locale.Language(identifier: "en")]
                .compactMap(match)
                .filter { $0.languageCode != source?.languageCode }
                .prefix(1).map { $0 }
        }
    }

    private func checkPairs() async {
        guard let source else { return }
        let availability = LanguageAvailability()
        var blocked: Set<String> = []
        for language in languages where await availability.status(from: source, to: language) == .unsupported {
            blocked.insert(language.minimalIdentifier)
        }
        unavailable = blocked
    }

    private func start() {
        guard source != nil else { return }
        problem = nil
        outputs = []
        failures = []
        done = 0
        queue = validTargets
        TranslationTargetsMenu.save(targets, Self.targetsKey)
        running = true
        translateNext()
    }

    /// Asks for a session for the next language (macOS downloads it first if needed).
    private func translateNext() {
        guard let source, let target = queue.first else { finish(); return }
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func translate(with session: TranslationSession) async {
        guard let target = await MainActor.run(body: { queue.first }) else { return }
        for file in files {
            do {
                let output = try await SubtitleFiles.translate(file, to: target, session: session)
                await MainActor.run { outputs.append(output) }
            } catch {
                await MainActor.run { failures.append("\(TranslationTargetsMenu.name(of: target)): \(error.localizedDescription)") }
            }
            await MainActor.run { done += 1 }
        }
        await MainActor.run {
            if !queue.isEmpty { queue.removeFirst() }
            translateNext()
        }
    }

    private func finish() {
        running = false
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        if failures.isEmpty {
            dismiss()
        } else {
            problem = failures.joined(separator: "\n")
        }
    }
}
