import AppKit
import Foundation
import SwiftUI

/// "Going home" check for a folder of a share: are its proxies all kept on this Mac (pinned, complete, sizes match), do
/// all its originals have a proxy, and is the office reachable now. One result line, what's missing, and Pin Missing.
/// Plus the relink check: proxies whose original (by the office's pairing, `OfficeProxies`: share + path, with its reel
/// name and timecode) is no longer in the folder, so Resolve could not relink them.
enum RemoteGoingHome {
    struct Item: Hashable, Identifiable {
        enum Why: Hashable { case notPinned, missing, partial }
        var proxy: String
        var why: Why
        var id: String { proxy }
    }

    struct Orphan: Hashable, Identifiable {
        var proxy: String
        var reel: String
        var timecode: String?
        var id: String { proxy }
    }

    struct Result: Equatable {
        /// The office answered just now (false: judged from what's kept here, as of the last look).
        var reachable: Bool
        var total = 0
        var here = 0
        var missing: [Item] = []
        /// Originals in the folder with no proxy made yet (paths).
        var noProxy: [String] = []
        /// Proxies without a matching original.
        var orphans: [Orphan] = []

        var ready: Bool { reachable && missing.isEmpty && noProxy.isEmpty }
        /// Pin Missing helps when there are proxies to fetch.
        var canPin: Bool { reachable && !missing.isEmpty }
        var line: String {
            if !reachable { return String(localized: "Can’t reach the office now. Connect before you leave.") }
            if ready { return String(localized: "Ready to edit at home") }
            if !missing.isEmpty { return String(localized: "Not ready: \(missing.count) of \(total) proxies aren’t on this Mac") }
            return String(localized: "Not ready: \(noProxy.count) originals have no proxy yet")
        }
    }

    /// `wanted`: the folder's proxies at the office (nil: the office couldn't be asked); `originals`: its original clips
    /// (paths in the share, nil with the office away); `pins`: this Mac's pins.
    nonisolated static func evaluate(share: String, path: String, wanted: [RemoteManifestEntry]?, originals: Set<String>?,
                                     pins: [RemotePins.Pin]) -> Result {
        let covering = pins.filter { $0.share == share && !$0.originals && ($0.path.isEmpty || path == $0.path || path.hasPrefix($0.path + "/")) }
        let reachable = wanted != nil
        // Office away: the last known list is what the pins kept.
        let entries = wanted ?? covering.flatMap(\.here).filter { path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/") }
        var result = Result(reachable: reachable, total: entries.count)
        for entry in entries {
            switch state(of: entry, pins: covering) {
            case nil: result.here += 1
            case let why?: result.missing.append(Item(proxy: entry.proxy, why: why))
            }
        }
        result.missing.sort { $0.proxy.localizedStandardCompare($1.proxy) == .orderedAscending }
        guard let originals else { return result }
        let paired = Set(entries.map(\.path))
        result.noProxy = originals.subtracting(paired).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        result.orphans = entries.filter { !originals.contains($0.path) }.map { Orphan(proxy: $0.proxy, reel: $0.reel, timecode: $0.timecode) }
            .sorted { $0.proxy.localizedStandardCompare($1.proxy) == .orderedAscending }
        return result
    }

    /// nil: kept here and complete.
    private nonisolated static func state(of entry: RemoteManifestEntry, pins: [RemotePins.Pin]) -> Item.Why? {
        if pins.isEmpty { return .notPinned }
        var partial = false
        for pin in pins {
            let root = URL(fileURLWithPath: pin.destination, isDirectory: true)
            let known = pin.here.first { $0.proxy == entry.proxy }
            if RemotePullManager.isHere(entry, in: root), RemotePins.unchanged(known, entry) { return nil }
            if RemotePullManager.size(of: root.appendingPathComponent(entry.proxy)) != nil { partial = true }
            else if (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(entry.proxy).deletingLastPathComponent().path))?
                .contains(where: { $0.hasPrefix((entry.proxy as NSString).lastPathComponent + ".") && $0.hasSuffix(".part") }) == true { partial = true }
        }
        return partial ? .partial : .missing
    }

    // MARK: - Asking the office

    /// The check for a folder now: its proxies, and its original clips (folders walked, a clip folder counts once).
    @MainActor static func check(share: OfficeRenderClient.RemoteShare, path: String) async -> Result {
        let pins = RemotePins.shared.pins
        do {
            let wanted = try await RemotePullClient.manifest(share: share.id, path: path, format: .light).entries
                .filter { ProxySync.isSafe($0.proxy) && ProxySync.isSafe($0.path) && (path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/")) }
            return evaluate(share: share.id, path: path, wanted: wanted, originals: try await clips(share: share.id, in: path), pins: pins)
        } catch {
            return evaluate(share: share.id, path: path, wanted: nil, originals: nil, pins: pins)
        }
    }

    /// shortcut: at most 300 folders walked, a bigger project is checked by its first ones; raise it if that bites.
    @MainActor static func clips(share: String, in path: String) async throws -> Set<String> {
        var found = Set<String>(), queue = [path], seen = 0
        while !queue.isEmpty, seen < 300 {
            let folder = queue.removeFirst()
            seen += 1
            for entry in try await OfficeRenderClient.shared.browse(share: share, path: folder) where !entry.name.hasPrefix(".") {
                let full = folder.isEmpty ? entry.name : folder + "/" + entry.name
                if entry.clip ?? entry.isVideo { found.insert(full) } else if entry.folder { queue.append(full) }
            }
        }
        return found
    }

    /// Pin Missing: the pin that covers the folder fetches what's missing at once; no pin yet: the folder is pinned (proxies).
    @MainActor static func pinMissing(share: OfficeRenderClient.RemoteShare, path: String) async throws {
        let pins = RemotePins.shared
        if let pin = pins.pins.first(where: { $0.share == share.id && !$0.originals && ($0.path.isEmpty || path == $0.path || path.hasPrefix($0.path + "/")) }) {
            await pins.pass(pin.id)
        } else {
            try await pins.pin(share: share, path: path, originals: false)
        }
    }
}

/// The sheet: one line, what's missing, Pin Missing.
struct RemoteGoingHomeSheet: View {
    let share: OfficeRenderClient.RemoteShare
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var result: RemoteGoingHome.Result?
    @State private var working = false
    @State private var problem: String?
    /// Tests and snapshots: a result to show without asking.
    var preset: RemoteGoingHome.Result?

    private var name: String { path.isEmpty ? share.name : (path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Going Home").font(Design.Typography.sheetTitle)
            if let result {
                HStack(spacing: 8) {
                    StudioChip(text: Text(verbatim: result.line), symbol: result.ready ? "checkmark.circle" : "exclamationmark.triangle",
                               colour: result.ready ? Design.Studio.good : Design.Studio.warn, tinted: true)
                    if working { PlumSpinner() }
                }
                Text("“\(name)”: \(result.here) of \(result.total) proxies kept on this Mac")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                if !result.missing.isEmpty {
                    list(String(localized: "Not on this Mac"), result.missing.map { ($0.proxy, label($0.why)) })
                }
                if !result.noProxy.isEmpty {
                    list(String(localized: "No proxy yet (Make Proxies first)"), result.noProxy.map { ($0, "") })
                }
                if !result.orphans.isEmpty {
                    list(String(localized: "Proxies with no matching original"), result.orphans.map { ($0.proxy, $0.timecode ?? $0.reel) })
                }
            } else {
                HStack(spacing: 8) { PlumSpinner(); Text("Checking…").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
            }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn) }
            HStack {
                Spacer()
                Button("Check Again") { Task { await run() } }.buttonStyle(StudioFlatButtonStyle()).disabled(working)
                if result?.canPin == true {
                    Button("Pin Missing") { Task { await pin() } }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(working)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(StudioFlatButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Design.Studio.panel)
        .task { if let preset { result = preset } else { await run() } }
    }

    private func label(_ why: RemoteGoingHome.Item.Why) -> String {
        switch why {
        case .notPinned: String(localized: "not pinned")
        case .missing: String(localized: "missing")
        case .partial: String(localized: "partly here")
        }
    }

    private func list(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(Design.Studio.sectionTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.0) { row in
                        HStack {
                            Text(verbatim: row.0).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(verbatim: row.1).foregroundStyle(Design.Studio.textQuiet)
                        }
                        .font(Design.Studio.hint)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
    }

    private func run() async {
        working = true
        result = await RemoteGoingHome.check(share: share, path: path)
        working = false
    }

    private func pin() async {
        working = true
        problem = nil
        do { try await RemoteGoingHome.pinMissing(share: share, path: path) } catch { problem = error.localizedDescription }
        result = await RemoteGoingHome.check(share: share, path: path)
        working = false
    }
}
