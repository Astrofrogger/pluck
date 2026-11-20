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

        // "You were mentioned": this Mac's person by the comment name; only what's new mentions it.
        let team = [Deliver.Person(id: "p1", name: "Sam", role: "owner"), Deliver.Person(id: "p2", name: "Alex", role: "editor")]
        var comment = Deliver.Comment(asset: asset, version: UUID(), text: "Look @Sam", author: "Client")
        comment.mentions = ["p1"]
        var replied = comment
        replied.replies.append(.init(text: "@Alex too", author: "Client", mentions: ["p2"]))
        var again = replied
        again.replies.append(.init(text: "and @Sam", author: "Client 2", mentions: ["p1"]))
        check("gap: mention of this Mac's person", DeliverNotify.me(team: team, name: " sam ".trimmingCharacters(in: .whitespaces)) == "p1"
              && DeliverNotify.me(team: team, name: "Editor") == nil
              && DeliverNotify.newMention(of: "p1", before: nil, after: comment)?.text == "Look @Sam"
              && DeliverNotify.newMention(of: "p1", before: comment, after: comment) == nil
              && DeliverNotify.newMention(of: "p1", before: comment, after: replied) == nil
              && DeliverNotify.newMention(of: "p2", before: comment, after: replied)?.author == "Client"
              && DeliverNotify.newMention(of: "p1", before: replied, after: again)?.author == "Client 2")
    }
}
