import AppKit
import SwiftUI

/// A Finder tag on a file: its name, and its colour as Finder numbers them (0 none, 1 gray,
/// 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange).
struct FinderTagMark: Hashable, Sendable {
    let name: String
    let color: Int
}

/// Finder's colour tags, read and written where Finder keeps them (the file's tag list, each
/// tag with its colour), so Finder shows the same dots.
enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Finder's seven colours, in its menu's order.
    static let colors = [6, 7, 5, 2, 4, 3, 1]

    nonisolated static func name(_ color: Int) -> String {
        switch color {
        case 6: String(localized: "Red")
        case 7: String(localized: "Orange")
        case 5: String(localized: "Yellow")
        case 2: String(localized: "Green")
        case 4: String(localized: "Blue")
        case 3: String(localized: "Purple")
        default: String(localized: "Gray")
        }
    }

    /// A dot of the colour for menus (in colour: menus draw symbols in one colour).
    static func dot(_ color: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(swatch(color)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func swatch(_ color: Int) -> Color {
        switch color {
        case 6: .red
        case 7: .orange
        case 5: .yellow
        case 2: .green
        case 4: .blue
        case 3: .purple
        case 1: .gray
        default: .clear
        }
    }

    /// The colour of a tag listed by name only (Finder's own names, in English or as shown here).
    nonisolated private static func color(named name: String) -> Int {
        let english = ["gray": 1, "grey": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5, "red": 6, "orange": 7]
        if let number = english[name.lowercased()] { return number }
        return colors.first { Self.localized[$0] == name } ?? 0
    }

    /// (The names as shown, worked out once: read off the main thread.)
    nonisolated private static let localized: [Int: String] = Dictionary(uniqueKeysWithValues: colors.map { ($0, name($0)) })

    /// A file's tags (none: an empty list).
    nonisolated static func read(_ url: URL) -> [FinderTagMark] {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { tag in
            let parts = tag.split(separator: "\n", maxSplits: 1).map(String.init)
            let name = parts.first ?? tag
            return FinderTagMark(name: name, color: parts.count > 1 ? Int(parts[1]) ?? 0 : color(named: name))
        }
    }

    /// A colour tag put on these files, or (`on` false) taken off.
    static func set(_ color: Int, on: Bool, for urls: [URL]) throws {
        for url in urls {
            // (Only the plain colour tag: the user's own tags of that colour stay.)
            var tags = read(url).filter { $0.color != color || Self.color(named: $0.name) != color }
            if on { tags.append(FinderTagMark(name: name(color), color: color)) }
            try write(tags, to: url)
        }
    }

    /// Every tag taken off.
    static func clear(_ urls: [URL]) throws {
        for url in urls { try write([], to: url) }
    }

    nonisolated static func write(_ tags: [FinderTagMark], to url: URL) throws {
        if tags.isEmpty {
            if removexattr(url.path, attribute, 0) != 0, errno != ENOATTR { throw FileProblem(String(cString: strerror(errno))) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: tags.map { "\($0.name)\n\($0.color)" }, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw FileProblem(String(cString: strerror(errno))) }
    }
}

/// A file's tag colours as small dots, as Finder shows them beside a name.
struct FinderTagDots: View {
    let tags: [FinderTagMark]

    var body: some View {
        let colors = tags.map(\.color).filter { $0 > 0 }
        if !colors.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                    Circle().fill(FinderTags.swatch(color))
                        .overlay(Circle().strokeBorder(Design.Studio.panel, lineWidth: 1))
                        .frame(width: 9, height: 9)
                }
            }
            .accessibilityLabel(Text(tags.map(\.name).formatted(.list(type: .and))))
        }
    }
}

/// Tags ▸ the seven colours (a tick on those every chosen file has), and Remove Tags.
struct FinderTagMenu: View {
    let urls: [URL]
    let pane: FinderPane

    var body: some View {
        Menu("Tags") {
            let all = urls.map { Set(FinderTags.read($0).map(\.color)) }
            ForEach(FinderTags.colors, id: \.self) { color in
                let every = !all.isEmpty && all.allSatisfy { $0.contains(color) }
                Toggle(isOn: Binding(get: { every }, set: { on in
                    do { try FinderTags.set(color, on: on, for: urls) } catch { pane.problem = error.localizedDescription }
                    pane.reload()
                })) {
                    Label { Text(FinderTags.name(color)) } icon: { Image(nsImage: FinderTags.dot(color)) }
                }
            }
            Divider()
            Button("Remove Tags") {
                do { try FinderTags.clear(urls) } catch { pane.problem = error.localizedDescription }
                pane.reload()
            }
            .disabled(all.allSatisfy(\.isEmpty))
        }
    }
}
