import Foundation

extension PhotoSelfTest {
    /// The Going Home check (part of remotepull): all proxies kept → ready; a missing, partial or unpinned proxy listed;
    /// the office away said; a proxy with no matching original, and an original with no proxy, listed.
    static func remoteGoingHomeTest() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("GoingHomeTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func entry(_ name: String, size: Int64 = 100) -> RemoteManifestEntry {
            RemoteManifestEntry(share: "s", path: "Day 1/" + name + ".mxf", proxy: "Day 1/" + name + ".mov", reel: name, timecode: "01:00:00:00", size: size, checksum: "ab")
        }
        func keep(_ e: RemoteManifestEntry, bytes: Int? = nil) { fm.createFile(atPath: root.appendingPathComponent(e.proxy).path, contents: Data(count: bytes ?? Int(e.size))) }
        let a = entry("A001"), b = entry("A002"), c = entry("A003")
        [a, b, c].forEach { keep($0) }
        let pin = RemotePins.Pin(share: "s", shareName: "Share", path: "Day 1", originals: false, limit: 1_000_000, destination: root.path, here: [a, b, c])
        let originals: Set<String> = Set([a, b, c].map(\.path))
        func run(_ wanted: [RemoteManifestEntry]?, _ originals: Set<String>?, pins: [RemotePins.Pin]) -> RemoteGoingHome.Result {
            RemoteGoingHome.evaluate(share: "s", path: "Day 1", wanted: wanted, originals: originals, pins: pins)
        }

        let ready = run([a, b, c], originals, pins: [pin])
        check("going home: everything kept here is ready", ready.ready && ready.here == 3 && ready.missing.isEmpty && ready.line == String(localized: "Ready to edit at home"), ready.line)

        let d = entry("A004"), e = entry("A005", size: 200)
        keep(e, bytes: 50)
        let gaps = run([a, b, c, d, e], originals.union([d.path, e.path]), pins: [pin])
        check("going home: a missing proxy is listed", gaps.missing.contains(Item(proxy: d.proxy, why: .missing)) && !gaps.ready, "\(gaps.missing)")
        check("going home: a proxy of the wrong size is listed as partial", gaps.missing.contains(Item(proxy: e.proxy, why: .partial)), "\(gaps.missing)")
        check("going home: only the gaps are listed, and counted", gaps.missing.count == 2 && gaps.here == 3 && gaps.canPin)

        let loose = run([a], [a.path], pins: [])
        check("going home: a folder with no pin lists its proxies as not pinned", loose.missing == [Item(proxy: a.proxy, why: .notPinned)], "\(loose.missing)")

        let away = run(nil, nil, pins: [pin])
        check("going home: an unreachable office is said, not ready, not pinnable", !away.reachable && !away.ready && !away.canPin && away.line == String(localized: "Can’t reach the office now. Connect before you leave."), away.line)
        check("going home: with the office away it still counts what's kept", away.here == 3 && away.missing.isEmpty, "\(away.here)")

        let lonely = run([a, b, c], [a.path, b.path], pins: [pin])
        check("going home: a proxy with no matching original is listed", lonely.orphans.map(\.proxy) == [c.proxy] && lonely.orphans.first?.timecode == "01:00:00:00", "\(lonely.orphans)")
        let bare = run([a, b, c], originals.union(["Day 1/A009.mxf"]), pins: [pin])
        check("going home: an original with no proxy is listed and keeps it from ready", bare.noProxy == ["Day 1/A009.mxf"] && !bare.ready && bare.orphans.isEmpty, "\(bare.noProxy)")
    }
    private typealias Item = RemoteGoingHome.Item
}
