import Foundation

extension PhotoSelfTest {
    /// The 4.1.0 Deliver gaps (part of reviewflow): transcript language, mentions of this Mac's person, the shared
    /// library, folder order, mail through the always-on Mac.
    static func deliverGapTest(store: DeliverStore, project: UUID, asset: UUID) async {
        // Transcripts: the project's spoken language wins over the name's guess; without one the guess stays.
        let chosen = DeliverCopies.spokenLanguage(project: "nl-BE", file: "/nowhere/Interview.mov", name: "The weather report today")
        let guessed = DeliverCopies.spokenLanguage(project: nil, file: "/nowhere/x.mov", name: "Le bulletin météo de ce soir à Paris")
        check("gap: transcript language (project first, guess as fallback)", chosen.identifier == "nl-BE" && guessed.language.languageCode?.identifier == "fr",
              "\(chosen.identifier) \(guessed.identifier)")
    }
}
