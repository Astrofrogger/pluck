import Foundation

/// Edits cut in Premiere Pro or Final Cut Pro with Edit Anywhere's proxies, rendered by Resolve on the office Mac: the
/// home Mac reads the exported XML (FCPXML from Final Cut Pro, Final Cut Pro 7 XML from Premiere), says what won't
/// translate (titles, effects, grades), and sends it with which local proxy stands for which original. The office
/// rewrites the proxy paths to its originals, imports it into its Resolve (MediaPool.ImportTimelineFromFile) and runs
/// the usual conform check and render (RemoteRenderQueue, an item with `xml`). Cuts, speed, simple transitions and
/// audio levels are the useful part.
enum RemoteXML {
    static let action = "resolveRenderXML"

    enum Kind: String { case fcpxml, xmeml }

    static func kind(_ text: String) -> Kind? {
        if text.contains("<fcpxml") { return .fcpxml }
        if text.contains("<xmeml") { return .xmeml }
        return nil
    }

    /// The XML of an export: a .fcpxml or .xml file, or the Info.fcpxml inside a .fcpxmld bundle.
    static func read(_ url: URL) throws -> String {
        let file = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        let text = try String(contentsOf: file, encoding: .utf8)
        guard kind(text) != nil else { throw OfficeLink.Failure.office(String(localized: "That isn’t an XML from Premiere Pro or Final Cut Pro.")) }
        return text
    }

    /// The sequence's (project's) name, for the timeline in Resolve.
    static func timeline(_ text: String) -> String? {
        if kind(text) == .fcpxml { return text.firstMatch(of: #/<project[^>]*\sname="([^"]+)"/#).map { unescape(String($0.1)) } }
        guard let sequence = text.range(of: "<sequence") else { return nil }
        return text[sequence.upperBound...].firstMatch(of: #/<name>([^<]+)</name>/#).map { unescape(String($0.1)) }
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Paths

    /// Every media file the XML points at (file URLs, as paths).
    static func files(_ text: String) -> [String] {
        Array(Set(text.matches(of: #/file://(?:localhost)?(/[^"<\s]+)/#).compactMap { unescape(String($0.1)).removingPercentEncoding })).sorted()
    }

    /// The XML with each known path swapped (`map`: path → new path), and the paths it points at that aren't in `map`
    /// (left as they are, and reported).
    static func rewrite(_ text: String, map: [String: String]) -> (text: String, unknown: [String]) {
        var unknown = Set<String>()
        var out = text
        for match in text.matches(of: #/file://(localhost)?(/[^"<\s]+)/#).reversed() {
            guard let path = unescape(String(match.2)).removingPercentEncoding else { continue }
            guard let target = map[path] ?? map[(path as NSString).standardizingPath] else { unknown.insert(path); continue }
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.replacingOccurrences(of: "&", with: "&amp;") ?? target
            out.replaceSubrange(match.range, with: "file://" + (match.1 == nil ? "" : "localhost") + encoded)
        }
        return (out, unknown.sorted())
    }

    // MARK: - What doesn't translate

    /// What Resolve won't bring over as it looked: titles and generators, effects, grades, other transitions (one line each, counted).
    static func untranslated(_ text: String) -> [String] {
        var found: [String: Int] = [:]
        func add(_ line: String) { found[line, default: 0] += 1 }
        let simple: Set<String> = ["cross dissolve", "dissolve", "additive dissolve", "fade in fade out dissolve", "dip to black", "constant power", "constant gain"]
        switch kind(text) {
        case .fcpxml:
            for match in text.matches(of: #/<title\b[^>]*\sname="([^"]*)"/#) { add(String(localized: "Title: \(unescape(String(match.1)))")) }
            for match in text.matches(of: #/<filter-video\b[^>]*\sname="([^"]*)"/#) {
                let name = unescape(String(match.1))
                add(name.localizedCaseInsensitiveContains("color") || name.localizedCaseInsensitiveContains("colour")
                    ? String(localized: "Grade: \(name)") : String(localized: "Effect: \(name)"))
            }
            for match in text.matches(of: #/<transition\b[^>]*\sname="([^"]*)"/#) where !simple.contains(unescape(String(match.1)).lowercased()) {
                add(String(localized: "Transition: \(unescape(String(match.1)))"))
            }
        case .xmeml:
            if text.contains("<generatoritem") { for _ in text.matches(of: #/<generatoritem\b/#) { add(String(localized: "Title or generator")) } }
            for match in text.matches(of: #/<effect>\s*<name>([^<]*)</name>(?:(?!</effect>)[\s\S])*?<effecttype>(filter|transition)</effecttype>/#) {
                let name = unescape(String(match.1))
                if match.2 == "transition" {
                    if !simple.contains(name.lowercased()) { add(String(localized: "Transition: \(name)")) }
                } else if !["basic motion", "opacity", "audio levels", "volume", "time remap", "crop"].contains(name.lowercased()) {
                    add(name.localizedCaseInsensitiveContains("lumetri") || name.localizedCaseInsensitiveContains("color")
                        ? String(localized: "Grade: \(name)") : String(localized: "Effect: \(name)"))
                }
            }
        case nil:
            break
        }
        return found.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
    }

    // MARK: - Office

    @MainActor
    static func register() {
        // {name, timeline, preset, xml (text), proxies [{file, share, path}]} → the queued render, and the paths that weren't proxies.
        OfficeActions.register(action) { arguments, device in
            try OfficeActions.require(\.render, device)
            let text = try OfficeActions.text(arguments["xml"], 30_000_000)
            guard kind(text) != nil else { throw OfficeActions.incomplete() }
            let name = try OfficeActions.text(arguments["name"], 300), timeline = try OfficeActions.text(arguments["timeline"], 300)
            let preset = try OfficeActions.text(arguments["preset"], 300)
            var map: [String: String] = [:], share: String?
            for value in (arguments["proxies"] as? [[String: Any]] ?? []).prefix(20_000) {
                guard let file = value["file"] as? String, let id = value["share"] as? String, let path = value["path"] as? String,
                      let root = try? RemoteEditHost.share(id),
                      let original = try? OfficeActions.require(\.render, device, share: root, path: path) else { continue } // a folder it can't render from stays unknown
                map[file] = original.path
                share = share ?? root.id
            }
            let (rewritten, unknown) = rewrite(text, map: map)
            let folder = RemoteRenderQueue.support.appendingPathComponent("XML", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString + (kind(text) == .fcpxml ? ".fcpxml" : ".xml"))
            try rewritten.write(to: file, atomically: true, encoding: .utf8)
            var item = RemoteRenderQueue.Item(project: UUID(), projectName: name, version: 1, timeline: timeline, preset: preset, share: share,
                                              proxies: [], device: device.name, deviceID: device.id)
            item.xml = file.path
            let queue = RemoteRenderQueue.shared
            let added = queue.add(item)
            return ["job": added.summary(for: device.id, position: queue.position(added.id)), "unknown": Array(unknown.prefix(50))]
        }
    }
}
