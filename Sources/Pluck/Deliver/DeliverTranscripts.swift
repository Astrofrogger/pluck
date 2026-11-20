import Foundation

/// Transcripts for review copies, made by Pluck on this Mac (opt-in per project): the speech recognizer's real word
/// times and, on Apple silicon, who spoke. Written as captions.vtt (with <v Name> voice tags) and transcript.json
/// next to the copies; a NAS gets the two files in the bundle (it has no speech engine) and keeps them.
extension DeliverCopies {
    func wantsTranscript(_ asset: UUID) -> Bool {
        guard let (project, found) = store.find(asset), found.kind == .video || found.kind == .audio else { return false }
        return store.project(project)?.transcripts == true && LocalAI.canTranscribe
    }

    func enqueueTranscript(asset: UUID, version: UUID) {
        guard transcribing != version, !transcripts.contains(where: { $0.version == version }) else { return }
        transcripts.append((asset, version))
        if case .ready = store.find(asset)?.asset.versions.first(where: { $0.id == version })?.copy { next() }
    }

    /// Every ready version of the project's sound and video gets one (the switch just went on).
    func transcribeProject(_ project: UUID) {
        for asset in store.content(project).assets where asset.kind == .video || asset.kind == .audio {
            for version in asset.versions where version.transcribed == nil {
                if case .ready = version.copy { enqueueTranscript(asset: asset.id, version: version.id) }
            }
        }
    }

    /// The saved transcript of the original (made earlier in Pluck), else a new one; then the two files.
    func makeTranscript(asset: UUID, version id: UUID) async {
        guard #available(macOS 26, *), let (project, found) = store.find(asset), let version = found.versions.first(where: { $0.id == id }),
              let source = store.original(version), let ai = AppDelegate.shared?.ai else { return }
        var transcript = TranscriptStore.find(forFile: source.path)
        if transcript == nil || (transcript?.hasSpeakers == false && Speakers.isSupported) {
            guard let audio = try? await ai.extractAudio(from: source) else { return }
            defer { try? FileManager.default.removeItem(at: audio) }
            if transcript == nil {
                let language = Self.spokenLanguage(project: store.project(project)?.spokenLanguage, file: source.path, name: found.name)
                guard let words = try? await OnDeviceSpeech.transcribe(audio, locale: language, duration: version.probe?.duration, status: { _, _ in }),
                      !words.isEmpty else { return }
                transcript = Transcript(id: UUID().uuidString, title: found.name, filePath: source.path, sourceURL: nil, language: language.identifier,
                                        duration: version.probe?.duration, created: .now, words: words)
            }
            if Speakers.isSupported, let turns = try? await Speakers.turns(in: audio, progress: { _ in }), !turns.isEmpty { transcript?.speakerTurns = turns }
            if let transcript { TranscriptStore.save(transcript) }
        }
        guard let transcript else { return }
        Self.writeTranscript(transcript, into: store.copies(id))
        store.update(version: id, of: asset) { $0.transcribed = .now }   // (a change: the data NAS gets the files with it)
        store.tell(.assetChanged(asset))
        ReviewPublish.shared.resend(asset)
    }

    /// The language spoken in a file: the project's choice, else what the site said when Pluck downloaded it, else a guess
    /// from the asset's name (else this Mac's language).
    static func spokenLanguage(project: String?, file: String, name: String) -> Locale {
        if let project, !project.isEmpty { return Locale(identifier: project) }
        let item = AppDelegate.shared?.manager.items.first { $0.existingFile?.path == file }
        return LocalAI.guessLanguage(title: name, metadata: item?.spokenLanguage)
    }

    /// captions.vtt and transcript.json from a Pluck transcript (word times kept; speakers by the names set in Pluck).
    nonisolated static func writeTranscript(_ transcript: Transcript, into out: URL) {
        let files = transcriptFiles(transcript)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? files.vtt.write(to: out.appendingPathComponent("captions.vtt"), atomically: true, encoding: .utf8)
        try? files.json.write(to: out.appendingPathComponent("transcript.json"), options: .atomic)
    }

    /// `{"lang","speakers":[names],"words":[[start,end,"word",speakerIndex?],…]}` (speakers only when known: old clients
    /// read the first three) and WebVTT cues with `<v Name>` voice tags.
    nonisolated static func transcriptFiles(_ transcript: Transcript) -> (vtt: String, json: Data) {
        let speakers = transcript.wordSpeakers()
        let numbers = Array(Set(speakers.compactMap { $0 })).sorted()
        let names = numbers.map { transcript.speakerName($0) }
        func round(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }
        var words: [[Any]] = []
        for (n, word) in transcript.words.enumerated() {
            let text = word.t.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var item: [Any] = [round(word.s), round(word.e), text]
            if let speaker = speakers[n], let index = numbers.firstIndex(of: speaker) { item.append(index) }
            words.append(item)
        }
        var object: [String: Any] = ["lang": transcript.language, "words": words]
        if !names.isEmpty { object["speakers"] = names }
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let cues = transcript.cues().map { cue in
            let voice = cue.speaker.map { "<v \(escape(transcript.speakerName($0)))>" } ?? ""
            return "\(Transcript.timestamp(cue.start)) --> \(Transcript.timestamp(cue.end))\n\(voice)\(escape(Transcript.twoLines(cue.text)))\n"
        }
        return ("WEBVTT\n\n" + cues.joined(separator: "\n"), json)
    }
}
