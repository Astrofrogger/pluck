import AppKit
import Foundation
import SwiftUI

/// The three shelves of the asset library.
enum AssetCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sfx, music, graphics
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .sfx: "SFX"
        case .music: "Music"
        case .graphics: "Graphics"
        }
    }

    var folder: String {
        switch self {
        case .sfx: "SFX"
        case .music: "Music"
        case .graphics: "Graphics"
        }
    }
}

/// What Pluck makes itself: each a generator with variations per seed.
enum AssetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Sound effects
    case whoosh, swish, swoosh, riser, downer, impact, boom, glitch, click, pop, reverse, tapeStop, shutter, typing, ambience
    // Music (generated, kept simple)
    case pad, pulse, beat, stinger
    // Graphics (alpha)
    case lightLeak, filmBurn, grain, dust, bokeh, flare, counter, shape, frame, gradient, lowerThird, arrow

    var id: String { rawValue }

    var category: AssetCategory {
        switch self {
        case .pad, .pulse, .beat, .stinger: .music
        case .lightLeak, .filmBurn, .grain, .dust, .bokeh, .flare, .counter, .shape, .frame, .gradient, .lowerThird, .arrow: .graphics
        default: .sfx
        }
    }

    /// Its name in the list and in the file's name.
    var name: String {
        switch self {
        case .whoosh: String(localized: "Whoosh")
        case .swish: String(localized: "Swish")
        case .swoosh: String(localized: "Swoosh")
        case .riser: String(localized: "Riser")
        case .downer: String(localized: "Downer")
        case .impact: String(localized: "Impact")
        case .boom: String(localized: "Boom")
        case .glitch: String(localized: "Glitch")
        case .click: String(localized: "Click")
        case .pop: String(localized: "Pop")
        case .reverse: String(localized: "Reverse")
        case .tapeStop: String(localized: "Tape Stop")
        case .shutter: String(localized: "Shutter")
        case .typing: String(localized: "Typing")
        case .ambience: String(localized: "Ambience")
        case .pad: String(localized: "Pad")
        case .pulse: String(localized: "Pulse")
        case .beat: String(localized: "Beat")
        case .stinger: String(localized: "Stinger")
        case .lightLeak: String(localized: "Light Leak")
        case .filmBurn: String(localized: "Film Burn")
        case .grain: String(localized: "Grain")
        case .dust: String(localized: "Dust")
        case .bokeh: String(localized: "Bokeh")
        case .flare: String(localized: "Flare")
        case .counter: String(localized: "Counter")
        case .shape: String(localized: "Shape")
        case .frame: String(localized: "Frame")
        case .gradient: String(localized: "Gradient")
        case .lowerThird: String(localized: "Lower Third")
        case .arrow: String(localized: "Arrow")
        }
    }

    /// Extra words to find it by (English, as typed in a search).
    var tags: [String] {
        switch self {
        case .whoosh: ["transition", "air", "pass by"]
        case .swish: ["fast", "transition", "air"]
        case .swoosh: ["transition", "sweep"]
        case .riser: ["build", "tension", "uplifter"]
        case .downer: ["drop", "fall", "downlifter"]
        case .impact: ["hit", "punch", "cinematic"]
        case .boom: ["sub", "drop", "cinematic", "hit"]
        case .glitch: ["digital", "error", "stutter"]
        case .click: ["ui", "button", "tap"]
        case .pop: ["bubble", "ui", "appear"]
        case .reverse: ["swell", "reverse", "build"]
        case .tapeStop: ["slow down", "stop", "vinyl"]
        case .shutter: ["camera", "photo", "snap"]
        case .typing: ["keyboard", "keys", "office"]
        case .ambience: ["room tone", "bed", "wind", "air", "loop"]
        case .pad: ["bed", "loop", "ambient", "chords", "generated"]
        case .pulse: ["loop", "arpeggio", "synth", "generated"]
        case .beat: ["drums", "loop", "percussion", "generated"]
        case .stinger: ["logo", "sting", "hit", "generated"]
        case .lightLeak: ["overlay", "warm", "film", "leak"]
        case .filmBurn: ["overlay", "transition", "film"]
        case .grain: ["overlay", "film", "texture", "noise"]
        case .dust: ["overlay", "scratches", "film", "texture"]
        case .bokeh: ["overlay", "lights", "blur"]
        case .flare: ["overlay", "lens", "light"]
        case .counter: ["numbers", "count up", "text"]
        case .shape: ["circle", "ring", "star", "triangle"]
        case .frame: ["border", "letterbox", "viewfinder"]
        case .gradient: ["vignette", "fade", "colour"]
        case .lowerThird: ["name", "title", "bar"]
        case .arrow: ["pointer", "callout"]
        }
    }

    var symbol: String {
        switch category {
        case .sfx: "waveform"
        case .music: "music.note"
        case .graphics: animated ? "sparkles" : "square.on.circle"
        }
    }

    /// Graphics that move (a movie); the rest are stills (a picture, and a short still movie for the timeline).
    var animated: Bool { [.lightLeak, .filmBurn, .grain, .dust, .bokeh, .flare, .counter].contains(self) }
}

/// The picture sizes graphics are made at.
enum AssetCanvas: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, ultra, vertical
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .ultra: CGSize(width: 3840, height: 2160)
        case .vertical: CGSize(width: 1080, height: 1920)
        }
    }
    var label: String { "\(Int(size.width))×\(Int(size.height))" }
}

/// One asset: a file in the asset folder, made by Pluck or from a CC0 pack.
struct AssetItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var category: AssetCategory
    /// A generator's kind (AssetKind's raw value), or a pack's own word.
    var kind: String
    var tags: [String] = []
    /// Relative to the asset folder.
    var file: String
    /// A still graphic as a short movie (what the Edit page takes); relative too.
    var still: String?
    /// Made by Pluck: the variation (its seed); nil for pack files.
    var variation: Int?
    var canvas: AssetCanvas?
    var duration: Double?
    var bpm: Int?
    var key: String?
    var loops: Bool?
    /// The pack it came from (nil: Made by Pluck).
    var pack: String?
    /// "Made by Pluck", or the pack file's SPDX licence ("CC0-1.0").
    var licence: String
    var sourcePage: String?
    var author: String?

    static let madeByPluck = "Made by Pluck"

    var url: URL { AssetStore.root.appendingPathComponent(file) }
    /// What goes on a timeline: the movie of a still, else the file itself.
    var timelineFile: URL { still.map { AssetStore.root.appendingPathComponent($0) } ?? url }
    var generated: AssetKind? { pack == nil ? AssetKind(rawValue: kind) : nil }
    var kindName: String { generated?.name ?? kind.capitalized }

    /// "0:02 · 120 BPM · A minor", what's known.
    var detail: String {
        var parts: [String] = []
        if let duration {
            parts.append(duration < 1 ? Duration.milliseconds(Int(duration * 1000)).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
                                      : Format.duration(duration))
        }
        if let bpm { parts.append("\(bpm) BPM") }
        if let key { parts.append(key) }
        if let canvas, category == .graphics { parts.append(canvas.label) }
        return parts.joined(separator: " · ")
    }

    /// Lowercased, without accents: everything to find it by.
    var words: String {
        MediaPanel.fold(([title, kindName, kind, licence, author ?? "", key ?? ""] + tags).joined(separator: " "))
    }
}

/// The asset library: what's been made or fetched (an index beside the files, under Application
/// Support/Pluck/Assets so the app stays small), favourites, and making more.
@MainActor
@Observable
final class AssetStore {
    static let shared = AssetStore()

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Assets", isDirectory: true)
    }
    nonisolated static var indexFile: URL { root.appendingPathComponent("index.json") }

    private(set) var items: [AssetItem] = []
    var favourites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "assetFavourites") ?? []) {
        didSet { UserDefaults.standard.set(Array(favourites).sorted(), forKey: "assetFavourites") }
    }
    /// What's being made now (its name), and how far (0…1).
    var making: String?
    var share = 0.0
    var problem: String?

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: Self.indexFile), let list = try? JSONDecoder().decode([AssetItem].self, from: data) else { items = []; return }
        // (A file deleted in Finder leaves the list.)
        items = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(items).write(to: Self.indexFile, options: .atomic)
    }

    /// Adds or replaces (by id).
    func add(_ new: [AssetItem]) {
        for item in new {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        }
        save()
    }

    func toggleFavourite(_ item: AssetItem) {
        if favourites.contains(item.id) { favourites.remove(item.id) } else { favourites.insert(item.id) }
    }

    func nextVariation(of kind: AssetKind) -> Int {
        (items.filter { $0.pack == nil && $0.kind == kind.rawValue }.compactMap(\.variation).max() ?? 0) + 1
    }

    /// Makes `count` more variations of each kind (graphics at `canvas`), off the main thread.
    func make(_ kinds: [AssetKind], count: Int = 1, canvas: AssetCanvas = .landscape, movie: LogoFile = .prores) async {
        guard making == nil, !kinds.isEmpty else { return }
        problem = nil
        let jobs = kinds.flatMap { kind in (0..<count).map { (kind, nextVariation(of: kind) + $0) } }
        let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg")
        for (index, job) in jobs.enumerated() {
            making = job.0.name
            share = Double(index) / Double(jobs.count)
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try await AssetMaker.make(job.0, variation: job.1, canvas: canvas, movie: movie, into: AssetStore.root, ffmpeg: ffmpeg)
                }.value
                add([item])
            } catch {
                problem = String(localized: "Couldn’t make \(job.0.name): \(error.localizedDescription)")
                break
            }
        }
        making = nil
        share = 0
    }

    /// The first set: two of each sound, one of each graphic.
    func makeStarter(_ category: AssetCategory, canvas: AssetCanvas = .landscape, movie: LogoFile = .prores) async {
        let kinds = AssetKind.allCases.filter { $0.category == category }
        await make(kinds, count: category == .graphics ? 1 : 2, canvas: canvas, movie: movie)
    }
}

/// Making one asset: its file named with its category, kind and variation.
enum AssetMaker {
    struct Failure: LocalizedError {
        var errorDescription: String? { String(localized: "The video tools aren’t ready yet.") }
    }

    /// The seed of a kind's variation: the same every time, on every Mac.
    static func seed(_ kind: AssetKind, _ variation: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(kind.rawValue)#\(variation)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// Graphics' movies: ProRes 4444 (for any editor) or HEVC (much smaller; Apple's apps), both with alpha.
    static func make(_ kind: AssetKind, variation: Int, canvas: AssetCanvas, movie: LogoFile = .prores, into root: URL, ffmpeg: String?) async throws -> AssetItem {
        let category = kind.category
        let base = "\(category.folder) \(kind.name) \(String(format: "%02d", variation))"
        let folder = "Made by Pluck/\(category.folder)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        var item = AssetItem(id: "pluck.\(kind.rawValue).\(variation)" + (category == .graphics ? ".\(canvas.rawValue)" + (movie == .hevc ? ".hevc" : "") : ""),
                             title: "\(kind.name) \(variation)", category: category, kind: kind.rawValue, tags: kind.tags,
                             file: "", variation: variation, licence: AssetItem.madeByPluck)
        switch category {
        case .sfx, .music:
            let sound = AssetSound.make(kind, seed: seed(kind, variation))
            item.file = "\(folder)/\(base).wav"
            try AssetSound.writeWAV(sound, to: root.appendingPathComponent(item.file))
            item.duration = Double(sound.left.count) / AssetSound.rate
            item.bpm = sound.bpm
            item.key = sound.key
            item.loops = sound.loops
        case .graphics:
            guard let ffmpeg else { throw Failure() }
            let name = "\(base) \(canvas.label)" + (movie == .hevc ? " HEVC" : "")
            item.canvas = canvas
            if kind.animated {
                item.file = "\(folder)/\(name).mov"
                item.duration = AssetGraphics.length(kind)
                item.loops = AssetGraphics.loops(kind)
                try await AssetGraphics.writeMovie(kind, seed: seed(kind, variation), size: canvas.size, movie: movie, to: root.appendingPathComponent(item.file), ffmpeg: ffmpeg)
            } else {
                item.file = "\(folder)/\(name).png"
                item.still = "\(folder)/\(name).mov"
                item.duration = AssetGraphics.stillLength
                try AssetGraphics.writePNG(kind, seed: seed(kind, variation), size: canvas.size, to: root.appendingPathComponent(item.file))
                try await AssetGraphics.writeMovie(kind, seed: seed(kind, variation), size: canvas.size, movie: movie, to: root.appendingPathComponent(item.still!), ffmpeg: ffmpeg)
            }
        }
        return item
    }
}
