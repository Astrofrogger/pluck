import Foundation

/// Lightroom presets and edits (Task 19), from files written here.
extension PhotoSelfTest {
    static func lightroom() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-lightroom-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A preset as Lightroom Classic writes it.
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="Normal" crs:Version="16.0" crs:ProcessVersion="11.0"
           crs:Exposure2012="+0.50" crs:Contrast2012="+12" crs:HueAdjustmentAqua="-20" crs:GrainAmount="25"
           crs:ColorGradeShadowHue="120" crs:ColorGradeShadowSat="50" crs:HasSettings="True">
           <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Soft Teal</rdf:li></rdf:Alt></crs:Name>
           <crs:Look><rdf:Description crs:Name="Adobe Color" crs:Amount="1"/></crs:Look>
           <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 140</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let preset = folder.appendingPathComponent("Soft Teal.xmp")
        try? xmp.write(to: preset, atomically: true, encoding: .utf8)
        let crs = (try? LightroomPresets.read(preset)) ?? [:]
        let (adjust, unmapped) = LightroomPresets.adjustments(crs)
        check("xmp preset exposure", adjust.exposure == 0.5 && adjust.contrast == 12, "0.5 and 12; got \(adjust.exposure), \(adjust.contrast)")
        check("hsl maps to mixer", adjust.mixer.hue[4] == -20, "-20; got \(adjust.mixer.hue[4])")
        let curve = adjust.curves.master
        check("tone curve points", curve.count == 3 && abs(curve[1].x - 0.502) < 0.001 && abs(curve[1].y - 0.549) < 0.001,
              "3 points, middle 0.502, 0.549; got \(curve)")
        check("colour grading to wheels", abs(adjust.wheels.lift.x + 0.1) < 0.001 && abs(adjust.wheels.lift.y - 0.1732) < 0.001,
              "lift at 120° half way (-0.1, 0.173); got \(adjust.wheels.lift.x), \(adjust.wheels.lift.y)")
        check("unmapped listed", unmapped == ["GrainAmount"], "only GrainAmount; got \(unmapped)")
        check("preset name is its own", crs["Name"] == "Soft Teal", "Soft Teal, not the profile's; got \(String(describing: crs["Name"]))")
        // White balance: As Shot leaves it; Custom on a photo is measured from its own light.
        let asShot = LightroomPresets.adjustments(["WhiteBalance": "As Shot", "Temperature": "3200", "Tint": "+10"], asShotKelvin: 3200).0
        let custom = LightroomPresets.adjustments(["WhiteBalance": "Custom", "Temperature": "6400", "Tint": "0"], asShotKelvin: 3200).0
        check("lightroom white balance", asShot.temperature == 0 && asShot.tint == 0 && abs(custom.temperature - 100 / 1.3) < 0.5,
              "as shot 0; custom one stop warmer (76.9); got \(asShot.temperature), \(custom.temperature)")

        // The older Lua template.
        let template = """
        s = {
            id = "8D4E1F2A",
            internalName = "Punchy",
            title = "Punchy",
            type = "Develop",
            value = {
                settings = {
                    Contrast2012 = 25,
                    ConvertToGrayscale = true,
                    ToneCurvePV2012 = { 0, 0, 64, 50, 255, 255, },
                    -- a comment
                    Vibrance = -10,
                },
                uuid = "8D4E1F2A",
            },
            version = 0,
        }
        """
        let lua = folder.appendingPathComponent("Punchy.lrtemplate")
        try? template.write(to: lua, atomically: true, encoding: .utf8)
        let old = LightroomPresets.adjustments((try? LightroomPresets.read(lua)) ?? [:]).0
        check("lrtemplate parses", old.contrast == 25 && old.vibrance == -10 && old.profile == .monochrome && old.curves.master.count == 3,
              "25, -10, monochrome, 3 points; got \(old.contrast), \(old.vibrance), \(String(describing: old.profile)), \(old.curves.master.count)")

        // Importing: a look per file, again replaces.
        let catalog = PhotoCatalog.shared
        let before = catalog.presets.count
        var result = LightroomPresets.importPresets(from: [folder], into: catalog)
        result = LightroomPresets.importPresets(from: [folder], into: catalog)
        let teal = catalog.presets.first { $0.name == "Soft Teal" }
        check("presets import once", result.imported == 2 && catalog.presets.count == before + 2 && teal?.adjust.exposure == 0.5,
              "2 looks, imported again in place; got \(result.imported), \(catalog.presets.count - before)")
        for preset in catalog.presets where preset.source?.hasPrefix(folder.path) == true { catalog.deletePreset(preset.id) }

        // A photo's sidecar with Lightroom's edit: used only when the setting is on.
        let photo = folder.appendingPathComponent("IMG_0001.jpg")
        try? Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photo)
        try? xmp.write(to: folder.appendingPathComponent("IMG_0001.xmp"), atomically: true, encoding: .utf8)
        let found = PhotoXMP.read(photo.path)
        check("sidecar edits read", found?.lightroom?["Exposure2012"] == "+0.50", "Exposure2012 +0.50; got \(String(describing: found?.lightroom?["Exposure2012"]))")
        let defaults = UserDefaults.standard
        let was = defaults.bool(forKey: LightroomPresets.useEditsKey)
        defer { defaults.set(was, forKey: LightroomPresets.useEditsKey) }
        func readBack(_ name: String, on: Bool) async -> Double? {
            let copy = folder.appendingPathComponent(name + ".jpg")
            try? Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: copy)
            try? xmp.write(to: folder.appendingPathComponent(name + ".xmp"), atomically: true, encoding: .utf8)
            defaults.set(on, forKey: LightroomPresets.useEditsKey)
            PhotoCatalog.shared.readSidecars([copy.path])
            for _ in 0..<40 where PhotoCatalog.shared.records[copy.path] == nil { try? await Task.sleep(for: .milliseconds(50)) }
            return PhotoCatalog.shared.records[copy.path] != nil ? PhotoCatalog.shared.record(copy.path).adjust.exposure : nil
        }
        let on = await readBack("IMG_0002", on: true), off = await readBack("IMG_0003", on: false)
        // Off: nothing kept for the photo, so turning it on later still brings the edit in.
        check("sidecar edits used when on", on == 0.5 && off == nil, "0.5 on, nothing off; got \(String(describing: on)), \(String(describing: off))")
    }
}
