import Foundation

/// A file in the media panel, or a range of one.
struct MediaSource: Hashable, Codable {
    let path: String
    /// The range of the file (seconds), or the whole file.
    let span: ClosedRange<Double>?
}

/// The media row that is selected in the Edit page's media panel (a click selects, a
/// double-click or Return opens).
@MainActor
@Observable
final class MediaSelection {
    static let shared = MediaSelection()
    var source: MediaSource?
}
