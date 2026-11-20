import CryptoKit
import Foundation

/// Archive's projects: which client and project each file on a share belongs to, found from the
/// folders (client = the first folder at the share's top, then past category folders such as
/// Video or Production to the first folder with its own name; workflow folders such as Rushes or
/// 002_Proxies mean the client folder is the project), with the owner's own corrections kept per
/// share. Also the space report (survey): per project what's rushes, proxies and caches,
/// deliveries and other, the big files left alone, kept on disk so it needn't be read again.
extension ShrinkFolders {
    /// Folders that hold projects of one kind: gone into.
    static let categoryNames: Set<String> = ["video", "videos", "photo", "photos", "foto", "fotos", "film", "films", "projects", "project", "projecten",
                                             "production", "productions", "productie", "producties", "post", "postproductie", "post-production",
                                             "postproduction", "edit", "edits", "montage", "jobs", "opdrachten", "clients", "klanten", "projets", "vidéo", "vidéos"]
    /// Folders a project's work is sorted in (a project has these; it isn't one).
    static let workflowNames: Set<String> = ["rushes", "rush", "rushs", "footage", "opnames", "video-opnames", "videoopnames", "media", "raw", "audio", "sound",
                                             "geluid", "son", "proxies", "proxy", "proxymedia", "render", "renders", "export", "exports", "graphics", "graphic", "gfx",
                                             "grafisch", "music", "muziek", "musique", "sfx", "cache", "cacheclip", "optimizedmedia", "optimized media", "font",
                                             "fonts", "import", "imports", "clusters", "assets", "ae", "after effects", "premiere", "resolve", "davinci",
                                             "project files", "dcim", "private", "xdroot", "m4root", "avchd", "clip", "stills", "lut", "luts", "titles",
                                             "subtitles", "ondertitels", "temp", "tmp", "old", "oud", "documents", "docs", "voice over", "vo", "camera", "cards",
                                             "final", "finals", "masters", "output", "client", "upload", "uploads", "social", "levering", "eindversie", "livraison"]
    /// Proxy and cache folders: moved with the originals once a project's masters are made.
    static let proxyNames: Set<String> = ["proxy", "proxies", "proxymedia", "optimizedmedia", "optimized media", "cacheclip", "cache", "render cache", "rendercache"]

    /// A folder name tidied for matching: lowercased, a leading number ("002_") and "_" / "#" taken off.
    static func plain(_ name: String) -> String {
        var name = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let range = name.range(of: #"^\d{2,3}[_ \-.]+"#, options: .regularExpression) { name.removeSubrange(range) }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "_# "))
    }

    static func numbered(_ name: String) -> Bool { name.range(of: #"^\d{2,3}[_ \-.]"#, options: .regularExpression) != nil }

    static func category(_ name: String) -> Bool { categoryNames.contains(plain(name)) }

    /// A workflow folder: by name, by its start (Deliveries, Imports video, BACKUP ANIMATIE…) or a numbered one.
    static func workflow(_ name: String) -> Bool {
        let tidy = plain(name)
        if workflowNames.contains(tidy) || numbered(name) { return true }
        for start in ["deliver", "import", "backup", "export", "render", "card", "a-cam", "b-cam", "c-cam", "cam ", "proxy", "audio", "rushes", "footage"]
        where tidy.hasPrefix(start) { return true }
        return tidy.contains("auto-save") || tidy.contains("autosave") || tidy.contains("cache")
    }

    static func proxyFolder(_ name: String) -> Bool { proxyNames.contains(plain(name)) }

    /// Folders that hold clients ("_Small clients"): their folders are clients.
    static func container(_ name: String) -> Bool {
        let tidy = plain(name)
        return !tidy.contains("new") && (tidy.hasSuffix("clients") || tidy.hasSuffix("klanten") || tidy.hasSuffix("clienten") || tidy.hasSuffix("cliënten"))
    }

    /// Templates and the like ("_New project", "_Map Structure Davinci"): never looked in.
    static func template(_ name: String) -> Bool {
        let tidy = plain(name)
        return tidy.contains("template") || tidy.hasPrefix("new client") || tidy.hasPrefix("new project") || tidy.hasPrefix("nieuw")
            || tidy.hasPrefix("map structure") || tidy.hasPrefix("mappenstructuur") || tidy.hasPrefix("nouveau")
    }

    /// The owner's corrections, kept per share: a folder is a project, or part of its parent; a project's name.
    struct Rules: Codable, Sendable {
        enum Mark: String, Codable, Sendable { case project, part }
        var marks: [String: Mark] = [:]
        var names: [String: String] = [:]
        /// A project's own size: Keep 4K, or Skip (never archived). (Optional: older files have none.)
        enum Choice: String, Codable, Sendable { case k4, skip }
        var sizes: [String: Choice]?

        static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Shrink/projects.json")
        }
        static func load() -> Rules { (try? JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))) ?? Rules() }
        func save() {
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        }
        /// A folder's key: its share (the NAS folder, whatever it's mounted as) and its path there.
        static func key(_ path: String, share: String) -> String {
            let base = OfficeGroup.nasKey(URL(fileURLWithPath: share)) ?? share
            return base + "|" + (path.hasPrefix(share + "/") ? String(path.dropFirst(share.count + 1)) : "")
        }
    }

    /// Where a file belongs: its client, its project's name and folder (nil: in a folder never
    /// looked in at the share's top).
    static func detect(_ path: String, share: String, rules: Rules = Rules()) -> (client: String, project: String, folder: String)? {
        let below = path.hasPrefix(share + "/") ? Array(path.dropFirst(share.count + 1).split(separator: "/").dropLast().map(String.init)) : []
        let shareName = (share as NSString).lastPathComponent
        guard !below.isEmpty else { return (shareName, shareName, share) }
        var client = 0
        if below[0].hasPrefix("_") || below[0].hasPrefix("#") {
            guard container(below[0]), below.count > 1 else { return nil }
            client = 1
        }
        func folder(_ index: Int) -> String { share + "/" + below[...index].joined(separator: "/") }
        var index = client + 1
        while index < below.count, category(below[index]) { index += 1 }
        var project = index < below.count && !workflow(below[index]) && !category(below[index]) ? index : client
        if let marked = (client..<below.count).reversed().first(where: { rules.marks[Rules.key(folder($0), share: share)] == .project }) { project = marked }
        while project > client, rules.marks[Rules.key(folder(project), share: share)] == .part {
            project -= 1
            while project > client, category(below[project]) { project -= 1 }
        }
        let place = folder(project)
        return (below[client], rules.names[Rules.key(place, share: share)] ?? below[project], place)
    }

    /// "Client – Project", or the client alone when the project is the client.
    static func title(client: String, project: String) -> String { client == project ? client : "\(client) – \(project)" }

    /// The share a chosen folder is on (the top its originals' folder goes in).
    static func shareRoot(of folder: URL) -> String { holding(for: folder).deletingLastPathComponent().path }

    // MARK: The survey

    /// One project's space.
    struct Project: Codable, Hashable, Identifiable, Sendable {
        var id: String { folder }
        var folder: String
        var client: String
        var name: String
        var share: String
        var rushes: Int64 = 0
        var proxies: Int64 = 0
        var deliveries: Int64 = 0
        var other: Int64 = 0
        /// Files that aren't video (counted into `other`).
        var loose: Int64 = 0
        var newest = Date.distantPast
        /// Its proxy and cache folders (moved with the originals once it's archived).
        var proxyFolders: [String] = []
        var total: Int64 { rushes + proxies + deliveries + other }
        var title: String { ShrinkFolders.title(client: client, project: name) }
    }

    /// A big file that isn't a video: for the list of what's left alone.
    struct Big: Codable, Hashable, Sendable {
        var path: String
        var size: Int64
        var project: String
        var reason: String
    }

    struct Survey: Codable, Sendable {
        var folders: [String]
        var date = Date.now
        var files: [File] = []
        var projects: [String: Project] = [:]
        var big: [Big] = []
    }

    /// Big files are those from this size.
    static let bigSize: Int64 = 100_000_000

    static func surveyURL(_ folders: [String]) -> URL {
        let id = SHA256.hash(data: Data(folders.sorted().joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Shrink/survey-\(id).json")
    }

    static func savedSurvey(_ folders: [String]) -> Survey? {
        (try? Data(contentsOf: surveyURL(folders))).flatMap { try? JSONDecoder().decode(Survey.self, from: $0) }
    }

    static func save(_ survey: Survey) {
        let url = surveyURL(survey.folders)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(survey).write(to: url, options: .atomic)
    }

    /// The projects' video sizes from the files, and each file's project age.
    static func tally(_ survey: inout Survey) {
        survey.projects = survey.projects.mapValues { project in
            var project = project
            (project.rushes, project.deliveries, project.other) = (0, 0, project.loose)
            return project
        }
        for file in survey.files {
            var project = survey.projects[file.project] ?? Project(folder: file.project, client: file.client, name: file.projectName,
                                                                  share: (file.project as NSString).deletingLastPathComponent)
            switch file.kind {
            case .rushes: project.rushes += file.size
            case .deliveries: project.deliveries += file.size
            case .other: project.other += file.size
            }
            project.newest = max(project.newest, file.modified)
            survey.projects[file.project] = project
        }
        for index in survey.files.indices { survey.files[index].projectChanged = survey.projects[survey.files[index].project]?.newest }
    }

    /// The survey again with new corrections, without reading the share again: each project and
    /// file placed anew (a split-off project's proxies and other files stay with the folder they
    /// were counted in until the next look).
    static func regroup(_ survey: Survey, rules: Rules) -> Survey {
        var result = survey
        result.projects = [:]
        for old in survey.projects.values {
            guard let place = detect(old.folder + "/x", share: old.share, rules: rules) else { continue }
            var project = result.projects[place.folder] ?? Project(folder: place.folder, client: place.client, name: place.project, share: old.share)
            project.name = place.project
            project.proxies += old.proxies
            project.loose += old.loose
            project.newest = max(project.newest, old.newest)
            project.proxyFolders += old.proxyFolders
            result.projects[place.folder] = project
        }
        for index in result.files.indices {
            let share = survey.projects[result.files[index].project]?.share ?? shareRoot(of: URL(fileURLWithPath: result.files[index].folder))
            guard let place = detect(result.files[index].path, share: share, rules: rules) else { continue }
            result.files[index].project = place.folder
            result.files[index].client = place.client
            result.files[index].projectName = place.project
            if result.projects[place.folder] == nil {
                result.projects[place.folder] = Project(folder: place.folder, client: place.client, name: place.project, share: share)
            }
        }
        tally(&result)
        return result
    }
}
