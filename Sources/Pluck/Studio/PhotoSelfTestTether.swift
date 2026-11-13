import Foundation

/// Tethered shooting (-PluckScreenshotOnly tether): with no camera, looking for one starts and stops cleanly; a watched folder
/// brings in a photo saved to it (into a Tethered album, as the one to show) and ignores what was already there.
extension PhotoSelfTest {
    static func tetherTest() async {
        let tether = PhotoTether.shared
        tether.start()
        try? await Task.sleep(for: .seconds(1))
        check("tether: looking for cameras starts", tether.note == nil || tether.cameras.isEmpty, tether.note ?? "")
        tether.stop()
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("tether-test", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = URL(fileURLWithPath: photos).appendingPathComponent("one.jpg")
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("before.jpg"))
        tether.watch(folder)
        check("tether: the folder is watched", tether.ready && tether.watched == folder)
        let shot = folder.appendingPathComponent("shot-1.jpg")
        try? FileManager.default.copyItem(at: source, to: shot)
        for _ in 0..<20 where tether.latest == nil { try? await Task.sleep(for: .milliseconds(250)) }
        check("tether: a new photo comes in", tether.latest == shot.path && tether.shot == 1, "latest \(tether.latest ?? "none"), \(tether.shot) in")
        let album = PhotoCatalog.shared.albums.first { $0.id == tether.album }
        check("tether: into its album", album?.paths.contains(shot.path) == true && album?.paths.contains(folder.appendingPathComponent("before.jpg").path) == false,
              album?.name ?? "no album")
        tether.stop()
    }
}
