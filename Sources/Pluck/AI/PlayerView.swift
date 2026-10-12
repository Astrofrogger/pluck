import AVKit
import SwiftUI

/// What the Pluck Player window shows: a file, its transcript, and where to start.
/// A file to open at a moment, on a part of the Editor's sidebar: what used to open Pluck Player.
struct PlayerTarget: Codable, Hashable {
    var filePath: String
    var transcriptID: String?
    var start: Double?
    /// "transcript", "summary" or "chapters": the side panel to open on.
    var tab: String?
}

extension PlayerTarget {
    /// Opens the file in the Editor at the moment, showing the transcript, summary or chapters.
    @MainActor func open(_ openWindow: OpenWindowAction) {
        let defaults = UserDefaults.standard
        switch tab {
        case "summary":
            defaults.set(EditorSidebar.Tab.transcript.rawValue, forKey: "editorSidebarTab")
            defaults.set("summary", forKey: "editorTranscriptView")
        case "chapters":
            defaults.set(EditorSidebar.Tab.marks.rawValue, forKey: "editorSidebarTab")
        case "transcript":
            defaults.set(EditorSidebar.Tab.transcript.rawValue, forKey: "editorSidebarTab")
            defaults.set("words", forKey: "editorTranscriptView")
        default: break
        }
        defaults.set(true, forKey: "editorSidebar")
        StudioNavigator.shared.open(EditorTarget(path: filePath), at: start)
        AppDelegate.openMainWindow?()
    }
}
