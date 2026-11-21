import AppKit
import Foundation
import os
import SwiftUI

/// "Keep on This Mac" (plan 2026-11-20 §3): a folder of a share whose proxies (or originals) stay on this Mac, kept up
/// to date from its manifest every 5 minutes, so it can be edited offline. Limits per pin and for all pins together
/// (500 GB), and 20 GB always free on the volume; when full it stops adding and says so, never evicting anything. A file
/// gone from the office is marked, and only goes (to the Trash) when its folder is unpinned. The drive serves a pinned
/// proxy from its copy here when its size and SHA-256 match the manifest (`localCopy`), and mounts with the pins alone
/// when the office can't be reached (`offlineManifest`).
@MainActor
@Observable
final class RemotePins {
    static let shared = RemotePins()
    nonisolated static let key = "editAnywherePins", totalKey = "editAnywherePinsTotalGB"
    static let every: TimeInterval = 5 * 60
    /// While the office can't be reached: looked at this often, so pins catch up as soon as it answers again.
    static let away: TimeInterval = 30
    /// At most this many pinned files at once, so the live drive stays fast.
    static let parallel = 2
    nonisolated(unsafe) static var freeFloor: Int64 = 20_000_000_000

    struct Pin: Codable, Identifiable, Hashable {
        var id = UUID()
        var share: String
        var shareName: String
        var path: String
        var originals: Bool
        /// Bytes at most for this pin.
        var limit: Int64
        var destination: String
        var checked: Date?
        /// What's kept here (by the manifest as it was): also what the drive lists offline.
        var here: [RemoteManifestEntry] = []
        /// Kept files no longer on the office Mac (their proxy paths).
        var gone: [String] = []
        /// Files still to come: the pin was full, or they failed.
        var waiting: [String] = []
        var full = false
        var problem: String?

        var bytes: Int64 { here.reduce(0) { $0 + $1.size } }
        var title: String { path.isEmpty ? shareName : (path as NSString).lastPathComponent }
    }

    private(set) var pins: [Pin] = []
    /// Files being fetched now (proxy paths).
    private(set) var current: Set<String> = []
    /// For all pins together.
    var totalLimit: Int64 {
        get { Int64(UserDefaults.standard.object(forKey: Self.totalKey) as? Int ?? 500) * 1_000_000_000 }
        set { UserDefaults.standard.set(Int(newValue / 1_000_000_000), forKey: Self.totalKey) }
    }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var passing: Set<UUID> = []
    func isPassing(_ id: UUID) -> Bool { passing.contains(id) }
    /// The last look at the office failed (it's away): the next one comes sooner.
    @ObservationIgnored private var unreachable = false
    @ObservationIgnored var client: OfficeRenderClient = .shared

    /// share|proxy path|size|checksum → the copy here, for the drive's reads from any thread.
    nonisolated static let copies = OSAllocatedUnfairLock(initialState: [String: String]())

    private init() {
        pins = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Pin].self, from: $0) } ?? []
        index()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: Self.key) }
        index()
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kept from the Office", isDirectory: true)
    }

    // MARK: - Pinning

    /// Pins a folder: asks the office first, so a Mac without the right (Downloader there for originals) hears so now.
    func pin(share: OfficeRenderClient.RemoteShare, path: String, originals: Bool, limit: Int64 = 100_000_000_000) async throws {
        guard ProxySync.isSafe(path) || path.isEmpty else { throw OfficeLink.Failure.garbled }
        let entries = try await RemotePullClient.manifest(share: share.id, path: path, format: .light).entries
        if originals, let first = entries.first {
            _ = try await client.fileData(share: share.id, path: first.path, kind: .original, offset: 0, length: 1)
        }
        let folder = Self.defaultFolder.appendingPathComponent(Folders.sanitize(share.name.isEmpty ? share.id : share.name), isDirectory: true)
            .appendingPathComponent(originals ? String(localized: "Originals") : String(localized: "Proxies"), isDirectory: true)
        pins.removeAll { $0.share == share.id && $0.path == path && $0.originals == originals }
        pins.append(Pin(share: share.id, shareName: share.name, path: path, originals: originals, limit: limit, destination: folder.path))
        save()
        start()
        if let pin = pins.last { await pass(pin.id) }
    }

    /// Unpins: its files go to the Trash (never deleted outright), the pin goes.
    func unpin(_ pin: Pin) {
        let root = URL(fileURLWithPath: pin.destination, isDirectory: true)
        // (Another pin of the same files keeps them.)
        let others = Set(pins.filter { $0.id != pin.id && $0.destination == pin.destination }.flatMap { $0.here.map(\.proxy) })
        for entry in pin.here where !others.contains(entry.proxy) && ProxySync.isSafe(entry.proxy) {
            try? FileManager.default.trashItem(at: root.appendingPathComponent(entry.proxy), resultingItemURL: nil)
        }
        pins.removeAll { $0.id == pin.id }
        save()
    }

    func setLimit(_ limit: Int64, for pin: Pin) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        pins[index].limit = limit
        save()
        Task { await pass(pin.id) }
    }

    // MARK: - Keeping up to date

    /// Every 5 minutes (and when a pin is added): each pin checked against the office; on reconnect (the office answering
    /// again after it was away) at once, within `away`.
    func start() {
        guard loop == nil, !pins.isEmpty, ScreenshotMode.scene == nil else { return }
        loop = Task {
            while !Task.isCancelled, !pins.isEmpty {
                unreachable = false
                for pin in pins { await pass(pin.id) }
                try? await Task.sleep(for: .seconds(unreachable ? Self.away : Self.every))
            }
            loop = nil
        }
    }

    /// One pin: its manifest now, new and changed files fetched within the limits, gone ones marked.
    func pass(_ id: UUID) async {
        // (One pass of a pin at a time: two would fetch the same files.)
        guard !passing.contains(id), var pin = pins.first(where: { $0.id == id }) else { return }
        passing.insert(id)
        defer { passing.remove(id) }
        pin.problem = nil
        let entries: [RemoteManifestEntry]
        do {
            entries = try await wanted(pin)
        } catch {
            unreachable = true
            pin.problem = error.localizedDescription
            return update(pin)
        }
        let root = URL(fileURLWithPath: pin.destination, isDirectory: true)
        let byProxy = Set(entries.map(\.proxy))
        pin.gone = pin.here.map(\.proxy).filter { !byProxy.contains($0) }
        let known = Dictionary(pin.here.map { ($0.proxy, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = entries.filter { RemotePullManager.isHere($0, in: root) && Self.unchanged(known[$0.proxy], $0) }
        let keptSet = Set(kept.map(\.proxy))
        let todo = entries.filter { !keptSet.contains($0.proxy) }
        // Within the limits, in order; the first that doesn't fit stops the rest (nothing is evicted).
        let others = pins.filter { $0.id != pin.id }.reduce(Int64(0)) { $0 + $1.bytes }
        let mine = kept.reduce(Int64(0)) { $0 + $1.size } + pin.here.filter { pin.gone.contains($0.proxy) }.reduce(Int64(0)) { $0 + $1.size }
        let free = Self.freeSpace(root)
        let plan = Self.fit(todo, used: mine, limit: pin.limit, others: others, total: totalLimit, free: free, floor: Self.freeFloor)
        pin.full = plan.full
        pin.waiting = plan.later.map(\.proxy)
        pin.here = kept + pin.here.filter { pin.gone.contains($0.proxy) }
        update(pin)
        var failed: [String] = []
        await withTaskGroup(of: (RemoteManifestEntry, Error?).self) { group in
            var queue = plan.now[...]
            func next() {
                guard let entry = queue.popFirst() else { return }
                group.addTask { @MainActor in
                    do { try await self.fetch(entry, of: pin, to: root.appendingPathComponent(entry.proxy)); return (entry, nil) } catch { return (entry, error) }
                }
            }
            for _ in 0..<Self.parallel { next() }
            while let (entry, error) = await group.next() {
                if let error { failed.append(entry.proxy); pin.problem = error.localizedDescription } else {
                    pin.here.append(entry)
                    // (Saved as each arrives: the drive serves it, and a quit loses nothing.)
                    update(pin, keepingProblem: true)
                }
                next()
            }
        }
        pin.waiting += failed
        pin.checked = .now
        update(pin, keepingProblem: true)
    }

    /// Whether a file kept here is still the one the office has: by SHA-256 and size where the manifest has a checksum
    /// (proxies); else by size and modification date (originals: the manifest has no checksum of them). A file here with no
    /// record counts only when there's no checksum to compare; one kept before dates were noted takes its date now.
    nonisolated static func unchanged(_ here: RemoteManifestEntry?, _ now: RemoteManifestEntry) -> Bool {
        guard let here else { return now.checksum == nil }
        if let checksum = now.checksum { return here.checksum?.lowercased() == checksum.lowercased() && here.size == now.size }
        return here.size == now.size && (here.modified == nil || now.modified == nil || here.modified == now.modified)
    }

    /// What the pin wants, as manifest entries (proxies: the share's light proxies under its folder; originals: those
    /// clips' originals with their size and date at the office, one listing per folder each pass).
    private func wanted(_ pin: Pin) async throws -> [RemoteManifestEntry] {
        let entries = try await RemotePullClient.manifest(share: pin.share, path: pin.path, format: .light).entries
            .filter { ProxySync.isSafe($0.proxy) && ProxySync.isSafe($0.path) && (pin.path.isEmpty || $0.path == pin.path || $0.path.hasPrefix(pin.path + "/")) }
        guard pin.originals else { return entries }
        var listings: [String: [String: OfficeRenderClient.RemoteEntry]] = [:]
        var out: [RemoteManifestEntry] = []
        for entry in entries {
            let folder = (entry.path as NSString).deletingLastPathComponent, name = (entry.path as NSString).lastPathComponent
            if listings[folder] == nil {
                listings[folder] = Dictionary((try await client.browse(share: pin.share, path: folder)).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            }
            let listed = listings[folder]?[name]
            let size = if let listed, !listed.folder { listed.size } else {
                try await client.fileData(share: pin.share, path: entry.path, kind: .original, offset: 0, length: 1).size
            }
            out.append(RemoteManifestEntry(share: pin.share, path: entry.path, proxy: entry.path, reel: entry.reel, timecode: entry.timecode,
                                           duration: entry.duration, fps: entry.fps, audioChannels: entry.audioChannels, size: size,
                                           modified: listed.map { $0.modified.timeIntervalSince1970.rounded() }))
        }
        return out
    }

    /// The files to fetch now and the ones that wait: in path order until one would pass the pin's limit, all pins'
    /// limit, or the floor of free space.
    nonisolated static func fit(_ todo: [RemoteManifestEntry], used: Int64, limit: Int64, others: Int64, total: Int64, free: Int64?,
                                floor: Int64) -> (now: [RemoteManifestEntry], later: [RemoteManifestEntry], full: Bool) {
        var used = used, free = free ?? 0
        let sorted = todo.sorted { $0.proxy.localizedStandardCompare($1.proxy) == .orderedAscending }
        for (index, entry) in sorted.enumerated() {
            if used + entry.size > limit || others + used + entry.size > total || free - entry.size < floor {
                return (Array(sorted[..<index]), Array(sorted[index...]), true)
            }
            used += entry.size
            free -= entry.size
        }
        return (sorted, [], false)
    }

    nonisolated static func freeSpace(_ folder: URL) -> Int64? {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func update(_ pin: Pin, keepingProblem: Bool = false) {
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        var pin = pin
        if keepingProblem, pin.problem == nil { pin.problem = pins[index].problem }
        // (A limit set while this pass ran stays; the pass's copy is older.)
        pin.limit = pins[index].limit
        pins[index] = pin
        save()
    }

    /// One file in pieces, resumed from a `.part` beside it, checked against its SHA-256 when the manifest has one.
    private func fetch(_ entry: RemoteManifestEntry, of pin: Pin, to target: URL) async throws {
        current.insert(entry.proxy)
        defer { current.remove(entry.proxy) }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = Self.partial(target, for: entry)
        // A part of another version of the file (replaced at the office since), or from before parts were tagged: started over.
        let folder = target.deletingLastPathComponent(), prefix = target.lastPathComponent + "."
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name != partial.lastPathComponent && name.hasPrefix(prefix) && name.hasSuffix(".part") {
            let tag = name.dropFirst(prefix.count).dropLast(".part".count)
            if name == prefix + "part" || (!tag.isEmpty && !tag.contains(".")) { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: partial.path) else {
            throw OfficeLink.Failure.office(String(localized: "The file couldn’t be saved on this Mac."))
        }
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset > entry.size { try handle.truncate(atOffset: 0); offset = 0 }
        while offset < entry.size {
            guard pins.contains(where: { $0.id == pin.id }) else { throw CancellationError() }
            let piece = try await client.fileData(share: pin.share, path: entry.path, kind: pin.originals ? .original : .proxy, format: .light,
                                                  offset: offset, length: OfficeLink.fileChunk)
            guard piece.size == entry.size else {
                try handle.truncate(atOffset: 0)
                throw OfficeLink.Failure.office(String(localized: "The file changed on the host Mac."))
            }
            guard !piece.data.isEmpty else { throw OfficeLink.Failure.garbled }
            try handle.write(contentsOf: piece.data)
            offset += Int64(piece.data.count)
        }
        try handle.synchronize()
        if let checksum = entry.checksum?.lowercased() {
            guard await Task.detached(operation: { RemotePullManager.sha256(partial) }).value == checksum else {
                try? fm.removeItem(at: partial)
                throw OfficeLink.Failure.office(String(localized: "A file arrived damaged and is fetched again."))
            }
        }
        // (A changed file: the new one in its place, the old one to the Trash.)
        if fm.fileExists(atPath: target.path) { try? fm.trashItem(at: target, resultingItemURL: nil) }
        try fm.moveItem(at: partial, to: target)
    }

    /// The part a file is fetched into, named for the version it's of (checksum, else size and date at the office), so a
    /// part is only ever resumed with bytes of that same version.
    nonisolated static func partial(_ target: URL, for entry: RemoteManifestEntry) -> URL {
        let tag = entry.checksum.map { String($0.lowercased().prefix(16)) } ?? "\(entry.size)-\(Int64((entry.modified ?? 0).isFinite ? entry.modified ?? 0 : 0))"
        return target.appendingPathExtension("\(tag).part")
    }

    // MARK: - The drive

    nonisolated static func copyKey(share: String, proxy: String, size: Int64, checksum: String) -> String {
        "\(share)|\(proxy)|\(size)|\(checksum.lowercased())"
    }

    private func index() {
        var map: [String: String] = [:]
        for pin in pins where !pin.originals {
            let root = URL(fileURLWithPath: pin.destination, isDirectory: true)
            for entry in pin.here {
                guard let checksum = entry.checksum, ProxySync.isSafe(entry.proxy) else { continue }
                map[Self.copyKey(share: entry.share, proxy: entry.proxy, size: entry.size, checksum: checksum)] = root.appendingPathComponent(entry.proxy).path
            }
        }
        Self.copies.withLock { $0 = map }
    }

    /// The copy here of a drive file, when a pin keeps that very proxy (same size and SHA-256); nil: from the network.
    nonisolated static func localCopy(_ entry: RemoteManifestEntry) -> URL? {
        guard let checksum = entry.checksum,
              let path = copies.withLock({ $0[copyKey(share: entry.share, proxy: entry.proxy, size: entry.size, checksum: checksum)] }),
              RemotePullManager.size(of: URL(fileURLWithPath: path)) == entry.size else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Bytes of a pinned copy (the drive's read).
    nonisolated static func read(_ file: URL, offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    /// What the drive lists for a share with no office to ask: the pinned proxies kept here.
    func offlineManifest(_ share: String) -> RemoteManifest? {
        let entries = pins.filter { $0.share == share && !$0.originals }.flatMap(\.here).filter { Self.localCopy($0) != nil }
        guard !entries.isEmpty, let office = client.office else { return nil }
        let name = pins.first { $0.share == share }?.shareName ?? share
        var seen = Set<String>()
        return RemoteManifest(host: office.device.uuidString, hostName: office.name, share: share, shareName: name,
                              entries: entries.filter { seen.insert($0.proxy).inserted })
    }

    func hasPins(_ share: String) -> Bool { pins.contains { $0.share == share && !$0.originals } }
}

/// Edit Anywhere › Kept on This Mac: each pinned folder with its size, how full, when it was last checked, and Unpin.
struct RemotePinsPane: View {
    @State private var pins = RemotePins.shared
    @State private var unpinning: RemotePins.Pin?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kept on This Mac").font(Design.Studio.sectionTitle)
            if pins.pins.isEmpty {
                Text("Right-click a folder in Browse and choose Keep on This Mac to edit it offline.")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            ForEach(pins.pins) { pin in row(pin) }
            if !pins.pins.isEmpty {
                let total = pins.pins.reduce(Int64(0)) { $0 + $1.bytes }
                Text("All pinned folders: \(bytes(total)) of \(bytes(pins.totalLimit))")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .onAppear { pins.start() }
        .alert(Text("Unpin “\(unpinning?.title ?? "")”?"), isPresented: Binding(get: { unpinning != nil }, set: { if !$0 { unpinning = nil } })) {
            Button("Cancel", role: .cancel) { unpinning = nil }
            Button("Unpin", role: .destructive) {
                if let unpinning { pins.unpin(unpinning) }
                unpinning = nil
            }
        } message: {
            Text("Its files on this Mac go to the Trash. Nothing changes at the office.")
        }
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func row(_ pin: RemotePins.Pin) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: pin.originals ? "film" : "pin", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pin.title).font(Design.Studio.body).lineLimit(1)
                Group {
                    Text(verbatim: [pin.originals ? String(localized: "Originals") : String(localized: "Proxies"),
                                    String(localized: "\(bytes(pin.bytes)) of \(bytes(pin.limit))"),
                                    pin.checked.map { String(localized: "checked \($0.formatted(.relative(presentation: .named)))") }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Design.Studio.textQuiet)
                    if pin.full {
                        Text("Pinned folder full: \(bytes(pin.bytes)) of \(bytes(pin.limit)). Raise the limit or unpin a folder. \(pin.waiting.count) files still to come.")
                            .foregroundStyle(Design.Studio.warn)
                    }
                    if !pin.gone.isEmpty {
                        Text("\(pin.gone.count) no longer on the office Mac").foregroundStyle(Design.Studio.textQuiet)
                    }
                    if let problem = pin.problem { Text(verbatim: problem).foregroundStyle(Design.Studio.warn) }
                    if pin.originals {
                        Text("Changes are found by size and date: the office keeps no checksums of originals.").foregroundStyle(Design.Studio.textQuiet)
                    }
                }
                .font(Design.Studio.hint).lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach([50, 100, 250, 500, 1000], id: \.self) { gb in
                    Button(String(localized: "\(gb) GB")) { pins.setLimit(Int64(gb) * 1_000_000_000, for: pin) }
                }
            } label: { Text("Limit") }
            .menuStyle(.button).buttonStyle(StudioFlatButtonStyle()).fixedSize()
            Button("Unpin") { unpinning = pin }.buttonStyle(StudioFlatButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }
}
