import CoreImage
import simd

/// Lightroom's profiles (Lightroom presets task 3): the Adobe-like start for Adobe's own profiles, and
/// creative profiles' colour tables (crs:Look). The tables here were written by a small encoder made
/// from the DNG SDK's source (dng_rgb_table::PutStream, dng_big_table::EncodeAsString), with real zlib.
extension PhotoSelfTest {
    /// 2 per side, ProPhoto, sRGB gamma: every colour as it was.
    static let identityTable = #"b1000OcImwBRLy1{X$/w9'=(b{NaYEO7|`l]b9%w(@0"#
    /// 2 per side, sRGB primaries and gamma: every channel halved (in sRGB steps).
    static let halfTable = #"b1000OcImwBRLy1{X$/w0]1rA$`R2.?Z`D5lXpDG!gFl:d}9v1Fbs?9N0"#
    /// 3 per side, sRGB primaries, linear: red, green, blue become green, blue, red.
    static let swapTable = #"E2000xBW^J}e!UfTR(dYd=Q=z42+kP=/uY:2RTe^Ze.Qw3DIXuyBfLVTU$-`@A.dx`mWTKZEpTN}H=^q=ZPZ2h{r`+d0hr{2B4QeT0"#

    private static let profileSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func patch(_ c: SIMD3<Float>) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), colorSpace: profileSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    /// The middle pixel (linear light).
    private static func middle(_ image: CIImage) -> SIMD3<Float> {
        var px = [Float](repeating: 0, count: 4)
        let at = CGRect(x: image.extent.midX.rounded(.down), y: image.extent.midY.rounded(.down), width: 1, height: 1)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: at, format: .RGBAf, colorSpace: profileSpace)
        }
        return SIMD3(px[0], px[1], px[2])
    }

    static func lightroomProfiles() {
        // Decoding: a known table.
        let swap = LookTable(text: swapTable)
        let swapped = swap?.lookup(SIMD3(0.5, 1, 0)) ?? .zero
        check("look table decodes", swap?.divisions == 3 && swap?.primaries == 0 && swap?.gamma == 0 && swap?.extend == false
              && simd_distance(swapped, SIMD3(1, 0, 0.5)) < 0.001,
              "3 per side, sRGB, linear, (0.5, 1, 0) to (1, 0, 0.5); got \(String(describing: swap?.divisions)), \(swapped)")
        let identity = LookTable(text: identityTable)
        check("look table header", identity?.divisions == 2 && identity?.primaries == 2 && identity?.gamma == 1
              && LookTable(text: "not a table") == nil && LookTable(text: String(swapTable.prefix(40))) == nil,
              "2 per side, ProPhoto, sRGB gamma; junk and a cut table refused")

        // On the picture: an identity table changes nothing, Amount 0 is skipped, a real table at its amount.
        LookTable.keep("A0000000000000000000000000000001", text: identityTable)
        LookTable.keep("A0000000000000000000000000000002", text: halfTable)
        let grey = SIMD3<Float>(0.2, 0.45, 0.7)
        func through(_ digest: String?, _ amount: Double) -> SIMD3<Float> {
            var a = PhotoAdjustments()
            a.lookTable = digest; a.lookName = digest.map { _ in "Test" }; a.lookAmount = amount
            return middle(PhotoRender.adjusted(patch(grey), a, isRaw: false, kelvin: 5500))
        }
        let plain = through(nil, 100)
        let same = through("A0000000000000000000000000000001", 100)
        check("identity look changes nothing", simd_distance(plain, same) < 0.003, "the same; got \(plain), \(same)")
        let none = through("A0000000000000000000000000000002", 0)
        check("look at amount 0 changes nothing", none == plain, "the same; got \(plain), \(none)")
        let full = through("A0000000000000000000000000000002", 100), half = through("A0000000000000000000000000000002", 50)
        let step = { (x: Float) in Float(LookTable.toSRGB(Double(x))) }
        check("look at its amount", abs(step(full.y) - step(plain.y) * 0.5) < 0.01 && abs(step(half.y) - step(plain.y) * 0.75) < 0.01,
              "green's sRGB step halved at 100, three quarters at 50; got \(step(plain.y)), \(step(full.y)), \(step(half.y))")

        // From a preset: the look, its amount and its own settings; a table that can't be read is listed.
        func preset(_ table: String, digest: String = "B0000000000000000000000000000003", amount: String = "0.5", extra: String = "") -> (PhotoAdjustments, unmapped: [String]) {
            let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
             <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.30" crs:Contrast2012="+5">
              <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Faded</rdf:li></rdf:Alt></crs:Name>
              <crs:Look><rdf:Description crs:Name="Vintage Test" crs:Amount="\(amount)" crs:UUID="1234" crs:SupportsAmount="true">
               <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Vintage</rdf:li></rdf:Alt></crs:Group>
               <crs:Parameters><rdf:Description crs:Version="14.0" crs:ProcessVersion="11.0" crs:CameraProfile="Adobe Standard"
                 crs:Contrast2012="+10" crs:RGBTable="\(digest)" crs:Table_\(digest)="\(table)"\(extra)>
                <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 30</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
               </rdf:Description></crs:Parameters>
              </rdf:Description></crs:Look>
             </rdf:Description></rdf:RDF></x:xmpmeta>
            """
            return LightroomPresets.adjustments(LightroomPresets.settings(fromXMP: Data(xmp.utf8)))
        }
        let (look, left) = preset(halfTable)
        check("creative profile from a preset", look.lookTable == "B0000000000000000000000000000003" && look.lookName == "Vintage Test"
              && look.lookAmount == 50 && look.contrast == 15 && look.exposure == 0.3 && look.profile == .adobe
              && abs(Curve(look.curves.master).value(0) - 30.0 / 255) < 0.01 && left.isEmpty,
              "its table at 50, contrast 5 + 10, its curve, Adobe base, nothing listed; got \(String(describing: look.lookTable)), \(look.lookAmount), \(look.contrast), \(left)")
        let (broken, listed) = preset("this isn't a table", digest: "B0000000000000000000000000000005")
        check("unreadable look listed", broken.lookTable == nil && broken.exposure == 0.3 && broken.contrast == 15 && listed == ["Vintage Test"],
              "the preset kept, the profile listed; got \(broken.exposure), \(listed)")
        check("look's hue table listed", preset(halfTable, extra: #" crs:LookTable="C0000000000000000000000000000004""#).unmapped == ["Vintage Test"],
              "the older kind of table can't be read")
        check("look amount as Lightroom's", preset(halfTable, amount: "1.5").0.lookAmount == 150, "1.5 is 150")

        // The Adobe-like start: only when an Adobe profile is named, only on RAW.
        let named = LightroomPresets.adjustments(["CameraProfile": "Adobe Color"]).0.profile
        let camera = LightroomPresets.adjustments(["CameraProfile": "Camera Standard", "Exposure2012": "+0.5"]).0.profile
        let byLook = LightroomPresets.adjustments(["Look.Name": "Adobe Portrait"]).0.profile
        check("adobe base only when named", named == .adobe && camera == nil && byLook == .portrait && LightroomPresets.adjustments([:]).0.profile == nil,
              "Adobe Color the Adobe-like profile, Adobe Portrait Portrait, others untouched; got \(String(describing: named)), \(String(describing: camera))")
        // (Version 2's Classic: version 3's has Adobe's own mid grey, see PhotoSelfTestProPhoto.)
        var adobe = PhotoAdjustments(), neutral = PhotoAdjustments(), oldPlain = PhotoAdjustments()
        adobe.profile = .adobe; neutral.profile = .neutral
        adobe.process = 2; neutral.process = 2; oldPlain.process = 2
        let scene = patch(SIMD3(repeating: 0.18))
        let rawAdobe = middle(PhotoEngine.develop(scene, adobe, isRaw: true)), rawNeutral = middle(PhotoEngine.develop(scene, neutral, isRaw: true))
        let rawDefault = middle(PhotoEngine.develop(scene, oldPlain, isRaw: true))
        // Classic keeps Neutral's mid grey (Adobe's curve alone is 0.7 stop brighter) and has its own contrast.
        let darkAdobe = middle(PhotoEngine.develop(patch(SIMD3(repeating: 0.03)), adobe, isRaw: true))
        let darkNeutral = middle(PhotoEngine.develop(patch(SIMD3(repeating: 0.03)), neutral, isRaw: true))
        check("adobe base is adobe's curve", abs(log2(rawAdobe.y / rawNeutral.y)) < 0.15 && abs(log2(darkAdobe.y / darkNeutral.y)) > 0.05
              && rawDefault == rawNeutral,
              "mid grey within 0.15 stop of Neutral's, the shadows its own, a RAW without it as before; got \(rawAdobe.y), \(rawNeutral.y), \(darkAdobe.y), \(darkNeutral.y)")
        // Above the decode's white the light rolls off into white rather than clipping.
        let bright = [1.0, 2.0, 4.0, 8.0].map { middle(PhotoEngine.develop(patch(SIMD3(repeating: Float($0))), adobe, isRaw: true)).y }
        let table = PhotoEngine.adobeBase
        check("classic rolls off its highlights", zip(bright, bright.dropFirst()).allSatisfy { $1 > $0 + 0.003 } && bright[3] <= 1.001
              && zip(table.dropFirst(), table.dropFirst(2)).allSatisfy { $1 > $0 } && abs(table[127] - 1) < 0.001,
              "1, 2, 4 and 8 brighter each, at most white; the table rising to white; got \(bright), \(table.suffix(3))")
        var asShot = PhotoAdjustments()
        asShot.profile = .asShot; asShot.process = 2
        let jpeg = patch(SIMD3(0.3, 0.2, 0.1))
        check("adobe base not on jpeg", middle(PhotoEngine.develop(jpeg, adobe, isRaw: false)) == middle(PhotoEngine.develop(jpeg, asShot, isRaw: false)),
              "As Shot on a photo that isn't RAW")

        // Older settings: no look, the profile as it was.
        let old = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.5,"profile":"vivid","process":2}"#.utf8))
        check("old settings without a look decode", old?.lookTable == nil && old?.lookName == nil && old?.lookAmount == 100 && old?.profile == .vivid,
              "no look, amount 100, vivid; got \(String(describing: old))")
    }
}
