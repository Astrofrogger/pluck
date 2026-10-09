import Foundation

/// Adds finished downloads to Apple Music by copying them into Music's "Automatically Add to
/// Music" folder: Music imports whatever lands there (and moves it into its library), so it
/// needs no permission prompts. The original file stays where Pluck saved it.
enum MusicLibrary {
    /// File types Apple Music can import, in the order Settings lists them.
    static let types: [(ext: String, label: String)] = [
        ("m4a", "M4A (AAC, ALAC)"), ("mp3", "MP3"), ("wav", "WAV"), ("aiff", "AIFF"),
        ("mp4", String(localized: "MP4 video")), ("m4v", String(localized: "M4V video")), ("mov", String(localized: "MOV video")),
    ]
    static let defaultTypes = "m4a,mp3"
    private static let musicTypes: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif"]

    /// What gets added: every song (made importable when needed), or only the chosen file types.
    enum Rule: Sendable {
        case allMusic
        case types(Set<String>)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.musicImport) }

    /// The rule for one finished download, or nil when it shouldn't be added.
    static func currentRule(isMusic: Bool) -> Rule? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Prefs.musicImportAll) { return isMusic ? .allMusic : nil }
        let types = Set((defaults.string(forKey: Prefs.musicImportTypes) ?? defaultTypes).split(separator: ",").map(String.init))
        return .types(types)
    }

    /// Music creates this folder the first time it opens; its exact name and place vary a little.
    static var folder: URL? {
        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let usual = music.appendingPathComponent("Music/Media.localized/Automatically Add to Music.localized")
        if FileManager.default.fileExists(atPath: usual.path) { return usual }
        guard let walker = FileManager.default.enumerator(at: music, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            if url.lastPathComponent.hasPrefix("Automatically Add to Music") { return url }
        }
        return nil
    }

    /// Adds the file (or each file in a chapter folder) the rule allows. Under "all music",
    /// formats Music can't import get an importable copy: FLAC becomes Apple Lossless, anything
    /// else AAC. Returns whether anything was added.
    static func add(_ url: URL, rule: Rule, ffmpeg: String?) async -> Bool {
        guard let folder else { return false }
        return await Task.detached {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return false }
            let files = isFolder.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                : [url]
            var added = false
            for file in files {
                let ext = file.pathExtension.lowercased()
                let name = file.deletingPathExtension().lastPathComponent
                switch rule {
                case .types(let types) where types.contains(ext):
                    added = copy(file, to: folder, name: name) || added
                case .allMusic where musicTypes.contains(ext):
                    added = copy(file, to: folder, name: name) || added
                case .allMusic:
                    // Converted next to the file, then moved in whole, so Music never sees a half-written one.
                    guard let ffmpeg else { continue }
                    let temp = file.deletingLastPathComponent().appendingPathComponent(".pluck-music-\(UUID().uuidString).m4a")
                    let codec = ext == "flac" ? ["-c:a", "alac"] : ["-c:a", "aac", "-b:a", "256k"]
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: ffmpeg)
                    p.arguments = ["-y", "-v", "error", "-i", file.path, "-map", "0:a:0", "-map", "0:v?", "-c:v", "copy",
                                   "-disposition:v", "attached_pic", "-map_metadata", "0"] + codec + [temp.path]
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    guard (try? p.run()) != nil else { continue }
                    p.waitUntilExit()
                    let target = Converting.outputURL(folder: folder.path, name: name, fileExtension: "m4a")
                    if p.terminationStatus == 0, (try? FileManager.default.moveItem(at: temp, to: target)) != nil {
                        added = true
                    } else {
                        try? FileManager.default.removeItem(at: temp)
                    }
                default:
                    continue
                }
            }
            return added
        }.value
    }

    private static func copy(_ file: URL, to folder: URL, name: String) -> Bool {
        let target = Converting.outputURL(folder: folder.path, name: name, fileExtension: file.pathExtension)
        return (try? FileManager.default.copyItem(at: file, to: target)) != nil
    }
}
