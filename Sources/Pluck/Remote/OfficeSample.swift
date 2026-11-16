import Foundation

/// Sample data for the Share this Mac snapshot scenes (officemacs, officefolders, officeproxies, officerenders):
/// held in memory only, nothing stored, nothing started. Neutral names.
@MainActor
enum OfficeSample {
    static func load() {
        guard ScreenshotMode.scene != nil else { return }
        let laptop = UUID(), desktop = UUID()
        let devices = [
            OfficeRenderServer.Device(id: laptop, name: "Home MacBook Pro", secret: Data(count: 32), added: .now.addingTimeInterval(-30 * 86_400)),
            OfficeRenderServer.Device(id: desktop, name: "Studio iMac", secret: Data(count: 32), added: .now.addingTimeInterval(-60 * 86_400)),
        ]
        let ssd = URL(fileURLWithPath: "/Volumes/Work SSD/AI Video", isDirectory: true)
        let nas = URL(fileURLWithPath: "/Volumes/Footage NAS/Footage 2026", isDirectory: true)
        let ssdID = OfficeProxies.pathID(ssd.path), nasID = OfficeProxies.pathID(nas.path)
        OfficeArchive.shared.showSample([ssd, nas])
        RemoteShares.shared.showSample([
            .init(path: ssd.path, id: ssdID, volume: "Work SSD"),
            .init(path: nas.path, id: nasID, volume: "Footage NAS", watch: [.init(path: "Day 2/Drone", format: .light)]),
        ], states: [
            ssd.path: .init(online: true, free: 1_240_000_000_000, total: 2_000_000_000_000, kind: String(localized: "Local SSD")),
            nas.path: .init(online: true, free: 18_400_000_000_000, total: 40_000_000_000_000, kind: String(localized: "NAS (SMB)"), network: true),
        ])
        let render = UUID()
        OfficeRenderServer.shared.showSample(
            devices: devices,
            lastSeen: [laptop: .now, desktop: .now.addingTimeInterval(-86_400)],
            links: [laptop: Tunnel.Link(direct: true, rtt: 18)],
            jobs: [
                .init(id: UUID(), resolveJob: "1", folder: ["Clients"], project: "Spring Campaign", timeline: "Teaser v3", preset: "H.264 Master",
                      device: "Home MacBook Pro", deviceID: laptop, started: .now.addingTimeInterval(-7200), state: .done, progress: 1,
                      file: "/Volumes/Work SSD/Renders/Teaser v3.mp4"),
                .init(id: render, resolveJob: "2", folder: ["Clients"], project: "Spring Campaign", timeline: "Main Film v5", preset: "ProRes 422 HQ",
                      device: "Home MacBook Pro", deviceID: laptop, started: .now.addingTimeInterval(-600), progress: 0.42),
            ])
        let making = RemoteProxyJobs.Request(share: nasID, paths: ["Day 1/Camera A"], format: .light, device: laptop, state: .making, total: 40, done: 24)
        RemoteProxyJobs.shared.showSample([
            making,
            .init(share: nasID, paths: ["Day 1/Camera B"], format: .light, device: laptop),
            .init(share: ssdID, paths: ["Interviews"], format: .prores, device: desktop),
        ], current: making.id, working: "A001_C014.mov", progress: 0.8)
        OfficeProxies.shared.sampleMade = [
            .init(url: OfficeProxies.root.appendingPathComponent("\(nasID)-light"), name: "Footage 2026", format: .light, share: nasID,
                  clips: 148, bytes: 96_000_000_000, lastUsed: .now.addingTimeInterval(-3 * 86_400)),
            .init(url: OfficeProxies.root.appendingPathComponent("\(ssdID)-light"), name: "AI Video", format: .light, share: ssdID,
                  clips: 36, bytes: 21_500_000_000, lastUsed: .now.addingTimeInterval(-3600)),
            .init(url: OfficeProxies.root.appendingPathComponent("\(ssdID)-prores"), name: "AI Video", format: .prores, share: ssdID,
                  clips: 12, bytes: 58_200_000_000, lastUsed: .now.addingTimeInterval(-10 * 86_400)),
        ]
        OfficeInbox.shared.showSample([("Logo animation.mov", "Home MacBook Pro", .now.addingTimeInterval(-1800),
                                        OfficeInbox.shared.folder.appendingPathComponent("Home MacBook Pro/Logo animation.mov"))])
    }
}
