import SwiftUI

/// Where the Edit page's panel (the project's media and the libraries) sits.
enum EditPanelPosition: String, CaseIterable, Identifiable {
    /// Beside the timeline, under the viewer: the viewer gets the whole top row.
    case bottom
    /// Beside the viewer; the timeline runs under both.
    case top
    /// From the top of the window to the bottom, left of the viewer and the timeline.
    case fullHeight

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        case .fullHeight: "Full Height"
        }
    }

    var symbol: String {
        switch self {
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .fullHeight: "rectangle.leadinghalf.inset.filled"
        }
    }

    /// The position the panel's button moves to.
    var next: EditPanelPosition {
        switch self {
        case .bottom: .top
        case .top: .fullHeight
        case .fullHeight: .bottom
        }
    }
}

/// The panel's tabs: the project's own media, then the libraries.
enum EditLibraryTab: String, CaseIterable, Identifiable {
    case media, transitions, titles, effects, music

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .media: "Media"
        case .transitions: "Transitions"
        case .titles: "Titles"
        case .effects: "Effects"
        case .music: "Music"
        }
    }

    var symbol: String {
        switch self {
        case .media: "film.stack"
        case .transitions: "rectangle.righthalf.inset.filled.arrow.right"
        case .titles: "textformat"
        case .effects: "wand.and.stars"
        case .music: "music.note"
        }
    }

    var next: EditLibraryTab {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// How the Edit page shares out its room: the viewer is a 16:9 picture as large as fits, and side
/// panels give way before it gets small.
enum EditLayout {
    /// The least of the page's height the viewer keeps.
    static let minimumViewerShare = 0.4

    struct Fit: Equatable {
        var panelShown: Bool
        var inspectorShown: Bool
        var viewer: CGSize
        /// How tall the timeline's row may be (less than asked when the picture needs the room).
        var timeline: Double
    }

    /// Which side panels can stay (of those the person wants shown), how tall the timeline may be,
    /// and the viewer's size then. A panel only goes when that makes the picture bigger;
    /// `keepInspector` (just asked for: Export, ⌥⌘S) keeps the inspector whatever it costs.
    static func fit(page: CGSize, position: EditPanelPosition, panelWidth: Double, inspectorWidth: Double, timelineHeight: Double,
                    panelShown: Bool, inspectorShown: Bool, keepInspector: Bool = false) -> Fit {
        func viewer(panel: Bool, inspector: Bool, timeline: Double) -> CGSize {
            // At the bottom the panel shares the timeline's row, not the viewer's.
            let besidePanel = panel && position != .bottom ? panelWidth : 0
            let width = max(page.width - besidePanel - (inspector ? inspectorWidth : 0), 0)
            let height = max(page.height - timeline, 0)
            return width / max(height, 1) > 16.0 / 9 ? CGSize(width: height * 16 / 9, height: height) : CGSize(width: width, height: width * 9 / 16)
        }
        let least = page.height * minimumViewerShare
        var panel = panelShown, inspector = inspectorShown, timeline = timelineHeight
        var size = viewer(panel: panel, inspector: inspector, timeline: timeline)
        // The panel goes first (one click brings it back), then the inspector, each only if the picture gains.
        if size.height < least, panel {
            let trial = viewer(panel: false, inspector: inspector, timeline: timeline)
            if trial.height > size.height + 0.5 { panel = false; size = trial }
        }
        if size.height < least, inspector, !keepInspector {
            let trial = viewer(panel: panel, inspector: false, timeline: timeline)
            if trial.height > size.height + 0.5 { inspector = false; size = trial }
        }
        // Still small: the timeline gives up some height.
        if size.height < least {
            timeline = max(min(timeline, page.height - least), 0)
            size = viewer(panel: panel, inspector: inspector, timeline: timeline)
        }
        return Fit(panelShown: panel, inspectorShown: inspector, viewer: size, timeline: timeline)
    }
}
