import Foundation

/// A screenful of edited RAW photos whose previews all have to be made again (3.9.6 changed every preview's key) all
/// come: developed all at once they blocked every thread and Core Image's RAW decoding never finished (no pictures).
extension PhotoSelfTest {
    static func thumbnailsAtOnce() async {
        let name = "a screenful of RAW thumbnails all come"
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("shootout/raws")
        let raws = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { ["arw", "cr3"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted().map { folder.appendingPathComponent($0).path }
        guard raws.count >= 4 else { return skip(name, "no shootout/raws") }
        // A 3.9.5 photo as it was in the catalogue that showed nothing (process 4, Classic, film on with Halation changed).
        let json = #"{"adjust":{"colorNoise":25,"sharpen":0,"straighten":0,"lookAmount":100,"blacks":0,"noise":0,"vignetteFeather":50,"texture":0,"process":4,"clarity":0,"moire":0,"vignetteStyle":1,"vignetteHighlights":0,"grainRoughness":50,"highlights":0,"whites":0,"wheels":{"offset":{"y":0,"master":0,"x":0},"balance":0,"gain":{"y":0,"master":0,"x":0},"blending":50,"lift":{"x":0,"y":0,"master":0},"gamma":{"x":0,"y":0,"master":0}},"shadows":0,"vibrance":0,"mixer":{"hue":[0,0,0,0,0,0,0,0],"saturation":[0,0,0,0,0,0,0,0],"luminance":[0,0,0,0,0,0,0,0]},"crop":"original","temperature":-10.55098684210526,"vignetteRoundness":100,"vignetteMidpoint":50,"masks":[],"dehaze":0,"contrast":0,"curves":{"red":[{"x":0,"y":0},{"x":1,"y":1}],"blue":[{"x":0,"y":0},{"x":1,"y":1}],"master":[{"x":0,"y":0},{"x":1,"y":1}],"green":[{"x":0,"y":0},{"x":1,"y":1}]},"grainSize":25,"vignette":0,"rawDecoder":"8","exposure":0,"grain":0,"calibration":{"blueSaturation":0,"greenHue":0,"redSaturation":0,"blueHue":0,"shadowTint":0,"greenSaturation":0,"redHue":0},"saturation":0,"tint":0},"denoise":0,"edited":815750928.442406,"flag":"none","rating":0,"denoiseAI":false,"snapshots":[],"film":{"changed":{"scan_film":{"number":{"_0":0}},"halation_on":{"number":{"_0":1}}},"film":"fujifilm_pro_400h","paper":"fujifilm_crystal_archive_typeii"},"filmOn":true}"#
        guard let record = try? JSONDecoder().decode(PhotoRecord.self, from: Data(json.utf8)) else { return check(name, false, "the record decodes") }
        await FilmEngine.shared.loadProfiles()
        BaseCache.shared.removeAll()
        // Two cells per photo (more than the Mac has threads), each as a grid cell asks; the wait is timed on the main
        // queue (when they're stuck, Dispatch's other threads are too).
        let cells = raws.count * 2, start = Date.now
        let made = FilmLocked(0), counted = FilmLocked(0), answered = FilmLocked(false)
        let all: Bool = await withCheckedContinuation { done in
            let finish = { (ok: Bool) in if answered.withLock({ was in defer { was = true }; return !was }) { done.resume(returning: ok) } }
            for i in 0..<cells {
                Task.detached(priority: .userInitiated) {
                    let picture = await PhotoRender.thumbnail(raws[i % raws.count], record: record)
                    if picture != nil { made.withLock { $0 += 1 } }
                    if counted.withLock({ $0 += 1; return $0 }) == cells { finish(true) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 150) { finish(false) }
        }
        let got = made.withLock { $0 }
        check(name, all && got == cells,
              "\(cells) pictures within 150 s; \(all ? "all finished" : "stuck after \(counted.withLock { $0 }) finished"), \(got) made, \(Int(Date.now.timeIntervalSince(start))) s")
        BaseCache.shared.removeAll()
    }
}
