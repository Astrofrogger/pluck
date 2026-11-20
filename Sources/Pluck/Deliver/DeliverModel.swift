import Foundation

/// Review projects on the Deliver page (docs/superpowers/plans/2026-11-15-pluck-review.md §1): projects,
/// folders, assets with their version stacks, comments, approvals and share links. Its own namespace, so
/// it doesn't clash with Edit Anywhere's `ReviewComment`.
enum Deliver {
    struct Project: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String                 // ≤ 80 chars
        var created = Date()
        var cover: UUID?                 // asset whose poster is the card; nil = first asset
        // §13 (all optional: missing = the old behaviour).
        var order: Int?                  // the sidebar order on the data host
        var deadline: Date?              // feedback deadline for its links (a link's own wins)
        var hidden: Bool?                // "Browse previews": not in the sidebar or the grid
        var rev: Int?, at: Date?, by: String?
    }

    struct ProjectContent: Codable, Hashable {
        var folders: [Folder] = []
        var assets: [Asset] = []
    }

    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String                 // ≤ 80 chars
        var parent: UUID?                // nil = project root; depth ≤ 8
        var rev: Int?, at: Date?, by: String?
    }

    enum Kind: String, Codable { case video, audio, image, document, other }   // document = PDF pages; other = download only

    /// A review status. The five built-ins keep their ids, so stored data and old wire values read unchanged; a custom
    /// one is "c:<short>" (workflow plan 5). Any string decodes: an unknown id is kept as it came.
    struct Status: RawRepresentable, Codable, Hashable {
        var rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        static let none = Status(rawValue: "none"), needsReview = Status(rawValue: "needsReview"), inProgress = Status(rawValue: "inProgress"),
                   needsChanges = Status(rawValue: "needsChanges"), approved = Status(rawValue: "approved")
        static let allCases = [none, needsReview, inProgress, needsChanges, approved]
        var isBuiltin: Bool { Self.allCases.contains(self) }
    }

    /// A custom status (workflow plan 5): `colour` is a token name (`colours`).
    struct StatusDef: Codable, Hashable, Identifiable {
        var id: String                   // "c:<short>"
        var name: String
        var colour: String
        static let colours = ["good", "bad", "warn", "quiet", "pink", "violet"]
    }

    /// A custom field (workflow plan 6). Values live on the asset as strings, parsed by kind; checkbox "1" or none.
    struct FieldDef: Codable, Hashable, Identifiable {
        var id: String                   // short; the wire name is "cf:<id>"
        var name: String
        var kind: String                 // text | number | date | select | person | checkbox
        var options: [String]?           // select
        static let kinds = ["text", "number", "date", "select", "person", "checkbox"]
        var wireName: String { "cf:" + id }
    }

    /// A saved filter across projects (workflow plan 4), Mac-only. Every part is optional: missing matches all.
    struct SavedView: Codable, Hashable, Identifiable {
        var v = 1
        var id = UUID()
        var name: String
        var statuses: [String]?          // status ids
        var assignee: String?            // a name; "me" = the owner's
        var due: String?                 // overdue | week
        var tag: String?                 // a keyword
        var openComments: Bool?
        var projects: [UUID]?            // nil = all projects
        var field: FieldRule?            // a custom field
        struct FieldRule: Codable, Hashable { var id: String; var op: String; var value: String }   // op: is | contains | set
    }

    /// The owner's custom statuses, fields and views, kept in the store's library.json.
    struct Library: Codable, Hashable {
        var v = 1
        var statuses: [StatusDef]?
        var fields: [FieldDef]?
        var views: [SavedView]?
    }

    struct Asset: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var folder: UUID?
        var kind: Kind
        var status: Status = .none
        var versions: [Version]          // ≥ 1; last = current
        var created = Date()
        var fields: Fields?
        var customFields: [String: String]?   // FieldDef id → value (workflow plan 6)
        var rev: Int?, at: Date?, by: String?

        var current: Version { versions[versions.count - 1] }
    }

    struct Version: Codable, Identifiable, Hashable {
        var id = UUID()
        var number: Int                  // 1, 2, 3… never reused within the stack
        var path: String                 // the original (never sent to a browser)
        var bookmark: Data?
        var size: Int64
        var added = Date()
        var probe: Probe?
        var copy: CopyState = .pending
        var pages: Int?                  // documents: page count
        var sha256: String?              // the original's (lowercase hex), for approval proofs (§13.8)
        var hostOriginal: String?        // a host's version: its bundle path of the original (sent back as it came)
    }

    /// An asset's metadata fields (§6.1); a link sends only those in its `fields`.
    struct Fields: Codable, Hashable {
        var rating: Int?                 // 0…5
        var keywords: [String]?
        var assignee: String?
        var due: String?                 // yyyy-MM-dd
        var notes: String?
        static let names = ["status", "rating", "keywords", "assignee", "due", "notes"]
        var isEmpty: Bool { self == Fields() }
    }

    struct Probe: Codable, Hashable {
        var duration: Double
        var fpsNum: Int, fpsDen: Int
        var width: Int, height: Int      // display size (rotation applied)
        var startTimecode: String
        var dropFrame: Bool
        var hasAudio: Bool
        var frames: Int                  // round(duration * fps)

        var fps: Double { Double(fpsNum) / Double(max(fpsDen, 1)) }
    }

    enum CopyState: Codable, Hashable { case pending, making(Double), ready([String]), failed(String) }

    struct Drawing: Codable, Hashable {
        var strokes: [Stroke]            // ≤ 64 strokes, ≤ 2,000 points in all
        struct Stroke: Codable, Hashable {
            var tool: Tool
            var colour: String           // one of `palette`
            var width: Double            // fraction of picture width, 0.002…0.02
            var points: [[Double]]       // [x, y] in 0…1 of the picture; arrow/rect/ellipse: 2 points
        }
        enum Tool: String, Codable, CaseIterable { case pen, arrow, line, rect, ellipse }
        static let palette = ["#E0605E", "#E0A15E", "#F2D14B", "#7CC294", "#6FA8DC", "#A98BD8", "#EDEBE6", "#111111"]

        /// Within §1's limits: stroke and point counts, palette colours, widths, points in 0…1.
        var isValid: Bool {
            strokes.count <= 64 && strokes.reduce(0) { $0 + $1.points.count } <= 2000 && strokes.allSatisfy { stroke in
                Self.palette.contains(stroke.colour) && (0.002...0.02).contains(stroke.width) && !stroke.points.isEmpty
                    && (stroke.tool == .pen || stroke.points.count == 2)
                    && stroke.points.allSatisfy { $0.count == 2 && $0.allSatisfy { (0...1).contains($0) } }
            }
        }
    }

    struct Comment: Codable, Identifiable, Hashable {
        var id = UUID()
        var asset: UUID
        var version: UUID
        var frame: Int?                  // nil = a general comment (no timecode)
        var endFrame: Int?
        var text: String
        var author: String
        var authorToken: String?         // base64url SHA-256 of the browser's token; nil = written on the Mac
        var link: UUID?
        var drawing: Drawing?
        var replies: [Reply] = []        // ≤ 100
        var completed = false
        var created = Date()
        var edited: Date?
        var page: Int?                   // documents (1-based)
        var anchor: [Double]?            // a pin, [x, y] in 0…1 of the picture
        var `internal`: Bool?            // only the owner and team links see it
        var reactions: [String: [String]]?   // emoji → author tokens ("owner" for the Mac)
        var attachments: [Attachment]?
        var mentions: [String]?          // ids from the link's `mentionable` (4.1.0); the text is never parsed for them
        var rev: Int?, at: Date?, by: String?
        var deletedReplies: [UUID]?      // sync only (§13.0 MC), never sent to browsers

        var isInternal: Bool { `internal` == true }
        /// The sort key: general comments first, then by frame (pages by page).
        var position: Int { frame ?? (page.map { $0 * 1_000_000 } ?? -1) }
        /// #hashtags in the text (§6.1: not stored, parsed on both sides).
        var tags: [String] { Comment.tags(text) }
        static func tags(_ text: String) -> [String] {
            text.matches(of: #/#([\p{L}\p{N}_-]{1,32})/#).map { String($0.1).lowercased() }
        }
        static let emoji = ["👍", "👎", "❤️", "😂", "😮", "🎉", "🔥", "👀", "✅", "❌", "🙏", "💯"]

        struct Attachment: Codable, Hashable, Identifiable {
            var id = UUID()
            var name: String
            var size: Int64
            var type: String
        }

        struct Reply: Codable, Identifiable, Hashable {
            var id = UUID()
            var text: String
            var author: String
            var authorToken: String?
            var created = Date()
            var `internal`: Bool? = nil  // team links and the owner only (the helper's flag; nil reads as false)
            var mentions: [String]? = nil
            var isInternal: Bool { `internal` == true }
        }
    }

    struct Approval: Codable, Identifiable, Hashable {
        var id = UUID()
        var asset: UUID, version: UUID
        var decision: Decision
        var author: String
        var link: UUID?
        var created = Date()
        // §13.8: what the proof shows.
        var email: String?
        var versionNumber: Int?
        var file: String?                // the original's file name
        var sha256: String?
        var hashOf: String?              // original | copy
        enum Decision: String, Codable { case approve, changes }
    }

    enum Scope: Codable, Hashable { case project(UUID), folder(UUID, project: UUID), asset(UUID, project: UUID), assets([UUID], project: UUID) }

    struct ShareLink: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var scope: Scope
        var roomID: String
        var mode: Mode = .review
        var allowDownload = false
        var latestOnly = false
        var expires: Date?
        var passwordHash: String?        // "pbkdf2-sha256$210000$<salt b64url>$<hash b64url>"
        var created = Date()
        var revoked: Date?
        var lastOpened: Date?
        // §6.1 (all optional: a missing one is the old behaviour).
        var description: String?
        var layout: String?              // grid | list | reel
        var requireName: Bool?
        var askEmail: Bool?
        var allowProxy: Bool?
        var audience: String?            // client | team
        var recipient: String?           // personal link
        var watermark: Watermark?
        var fields: [String]?
        var featuredField: String?       // status | rating | nil
        var uploads: Uploads?
        var paused: Bool?
        var muted: Bool?                 // no notifications for this link
        var notifyOpened: Bool?
        var notify: Notify?              // "Email updates" (4.1.0)
        // §13.
        var deadline: Date?              // feedback closes then (else the project's)
        var reminded: [String]?          // this Mac only: "3d", "1d", "closed"
        var madeOn: String?              // the device whose Keychain holds the key
        // Workflow plan 3, 5.
        var order: [UUID]?               // "As arranged": asset ids; missing ones sort last by name
        var customStatuses: Bool?        // send the custom statuses' names and colours
        var rev: Int?, at: Date?, by: String?
        enum Mode: String, Codable, CaseIterable { case review, presentation }
        var isLive: Bool { revoked == nil && (expires ?? .distantFuture) > Date() }
        var isTeam: Bool { audience == "team" }
        var isPaused: Bool { paused == true }
        var shownFields: [String] { fields ?? ["status"] }

        /// Email updates for this link; the mail code (the link's fragment) goes to the host only, in the manifest.
        struct Notify: Codable, Hashable {
            var email = false
            var recipientEmail: String?
        }

        struct Watermark: Codable, Hashable {
            var text = "{name} · {email} · {date}"
            var position = "center"      // center | topLeft | topRight | bottomLeft | bottomRight
            var opacity = 0.25
            var size = 0.03
            var burned = false
            static let positions = ["center", "topLeft", "topRight", "bottomLeft", "bottomRight"]
        }

        struct Uploads: Codable, Hashable {
            var folder: UUID?
            var maxBytes: Int64 = 21_474_836_480
            var types = ["video", "audio", "image", "document", "other"]
            /// Ask for Files (RemoteAskFiles): the files go straight into this folder of a NAS media root, not the project.
            var into: Into?
            struct Into: Codable, Hashable { var root: String; var folder: String }
        }

        var project: UUID { scope.project }
    }

    /// What happened on a link (§6.1): kept on this Mac, never in the Worker.
    struct Activity: Codable, Identifiable, Hashable {
        var id = UUID()
        var link: UUID
        var at = Date()
        var peer: String?
        var name: String?
        var email: String?
        var kind: String                 // opened | viewed | played | commented | downloaded | uploaded | approved
        var asset: UUID?
        var version: UUID?
        var detail: Detail?
        struct Detail: Codable, Hashable { var from: Int?; var to: Int?; var what: String?; var name: String?
            /// A NAS host writes an approval's decision here ("approve"/"changes"), Pluck in `what`.
            var decision: String? }
    }

    struct InboxItem: Codable, Identifiable, Hashable {
        var id = UUID()                  // = the comment or approval id
        var project: UUID, asset: UUID, version: UUID
        var kind: String                 // "comment" | "reply" | "approval"
        var summary: String              // first 120 chars
        var author: String
        var created = Date()
        var read = false
    }

    /// A review copy's byte-range index (§2), written next to its playlist as index.json.
    struct CopyIndex: Codable, Hashable {
        struct Piece: Codable, Hashable { var file: String; var offset: Int64; var length: Int64 }
        struct Segment: Codable, Hashable { var t: Double; var d: Double; var file: String; var offset: Int64; var length: Int64 }
        var codecs: String
        var duration: Double
        var fpsNum: Int, fpsDen: Int
        var width: Int, height: Int
        var `init`: Piece
        var segments: [Segment]
    }

    /// Where the Deliver page is (StudioNavigator.deliver).
    enum Selection: Hashable {
        case projects
        case project(UUID, folder: UUID?)
        case asset(UUID, version: UUID?, comment: UUID?)
        /// A project's shared links (they show only in their project), with one opened.
        case links(UUID, link: UUID?)
        case inbox, deliveryCheck, archiveProject, people
        case view(UUID)
        case nas(UUID)
        case browse(PlaceID)
    }

    /// A place Deliver › Browse lists (§13.16).
    enum PlaceID: Hashable { case local, nas(UUID), office(String) }

    /// A removed object, kept so the removal syncs (§13.1).
    struct Tombstone: Codable, Hashable {
        var kind: String                 // project | folder | asset | link
        var id: UUID
        var project: UUID?
        var rev: Int
        var at: Date
        var by: String
    }

    /// A §6 error code, thrown by the store and the server.
    struct Failure: Error, Equatable {
        let code: String
        var progress: Double?
        init(_ code: String, progress: Double? = nil) { self.code = code; self.progress = progress }
    }

    /// Names and labels: control characters out, trimmed, at most `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        String(String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
