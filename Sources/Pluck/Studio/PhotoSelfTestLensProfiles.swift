import Foundation

/// Lens profiles (-PluckScreenshotOnly lensprofiles; needs the database in Pluck's folder): a barrel profile fits as positive
/// Distortion (it takes barrel out) and the fitted warp follows the profile's closely; corner fall-off as positive Vignetting;
/// real lens names find their profiles; the test photos' lenses are named.
extension PhotoSelfTest {
    static func lensProfiles() async {
        // A made-up full-frame lens: poly3 barrel (k1 −0.02), corners 30% darker, red a little large.
        var lens = PhotoLensProfiles.Lens(maker: "Test", models: ["Test 24mm f/2.8"], crop: 1)
        lens.distortion = [(24, "poly3", -0.02, 0, 0)]
        lens.vignetting = [(24, 2.8, 1000, -0.3, 0, 0)]
        lens.tca = [(24, "poly3", 1.0004, 0.9997, 0, 0, 0, 0)]
        let shot = PhotoLensProfiles.Shot(lens: "Test 24mm f/2.8", focal: 24, aperture: 2.8, crop: 1)
        let fit = PhotoLensProfiles.fitted(lens, shot: shot, width: 6000, height: 4000)
        check("lens profiles: barrel fits as positive Distortion", fit.distortion > 0, "\(fit.distortion)")
        // The fitted warp against the profile's, across the frame (shares of the half diagonal), its size matched (Pluck scales
        // to fill the frame).
        let toProfile = hypot(6000.0, 4000) / 2 / 2000
        let rs = (1...20).map { Double($0) / 20 }
        let ours = rs.map { $0 * (1 + fit.k1 * $0 * $0 + fit.k2 * $0 * $0 * $0 * $0) }
        let theirs = rs.map { r -> Double in let ru = r * toProfile; return ru * (1 + 0.02 - 0.02 * ru * ru) / toProfile }
        let scale = zip(ours, theirs).reduce(0) { $0 + $1.0 * $1.1 } / ours.reduce(0) { $0 + $1 * $1 }
        let worst = zip(ours, theirs).map { abs($0 * scale - $1) / scale }.max() ?? 1
        check("lens profiles: the fitted warp follows the profile", worst < 0.004, "worst \(worst) of the half diagonal")
        check("lens profiles: corner fall-off fits as positive Vignetting", fit.vignetting > 15 && fit.vignetting < 40, "\(fit.vignetting), midpoint \(fit.midpoint)")
        check("lens profiles: red read larger fits as Red/Cyan", fit.redCyan < 0 && fit.blueYellow > 0, "red \(fit.redCyan), blue \(fit.blueYellow)")
        guard PhotoLensProfiles.isReady else { skip("lens profiles: database", "not downloaded"); return }
        let lenses = PhotoLensProfiles.lenses()
        check("lens profiles: the database reads", lenses.count > 500, "\(lenses.count) lenses")
        for name in ["FE 24-70mm F2.8 GM", "EF24-70mm f/2.8L II USM", "XF35mmF1.4 R"] {
            let found = PhotoLensProfiles.find(name)
            check("lens profiles: \(name) is found", found != nil, found?.models.first ?? "none")
        }
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("raws")
        var names: [String] = []
        for file in ["DSC02845.ARW", "R6LO7634.CR3"] {
            let path = folder.appendingPathComponent(file).path
            if let s = PhotoLensProfiles.shot(path) {
                names.append("\(file): \(s.lens) at \(s.focal) mm → \(PhotoLensProfiles.find(s.lens)?.models.first ?? "no profile"), Apple corrects: \(PhotoLensProfiles.appleCorrects(path))")
            }
        }
        note("lens profiles: " + names.joined(separator: "; "))
    }
}
