import Foundation

/// Archive's fifth review (part of shrinksafety): the two-Mac flow (a run left on the always-on Mac
/// carries on, a hold expires, only a Mac that may shrink can stop or hold), Put Back never drops a master
/// for a part that isn't there, proxies come back into a folder made again, and the dashboard's
/// counts (.DS_Store, freed, not touched, you can free, relinked, per project finished).
extension PhotoSelfTest {
    static func shrinkSafety5Test() async {
        typealias S = ShrinkFolders
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("pluck-shrinksafe5-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let base = S.real(made)
        let share = base.appendingPathComponent("Safe5")
        let testVolumes = OfficeGroup.testVolumes
        OfficeGroup.testVolumes = [(share.path, "smb://test/safe5"), (share.path.replacingOccurrences(of: "/private/var/", with: "/var/"), "smb://test/safe5")]
        defer { OfficeGroup.testVolumes = testVolumes; try? fm.removeItem(at: base) }
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("shrink safety 5: ffmpeg", false, "no ffmpeg")
        }
        let old = Date.now.addingTimeInterval(-2 * 365 * 86400)
        let prores = ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le"]
        func make(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1,noise=alls=3:allf=t",
                                        "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:duration=1,aformat=channel_layouts=stereo:sample_rates=48000",
                                        "-map", "0:v", "-map", "1:a", "-shortest"] + prores + ["-timecode", "10:00:00:00", "-f", "mov", url.path])
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        func write(_ url: URL, _ count: Int, date: Date? = nil) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 5, count: count).write(to: url)
            try? fm.setAttributes([.modificationDate: date ?? old], ofItemAtPath: url.path)
        }
        func size(_ url: URL) -> Int64? { (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 }
        func scan(_ folder: URL) -> [S.File] { S.scan([folder], ffprobe: ffprobe, minimum: 200_000, quiet: 0).sorted { $0.path < $1.path } }
        func center(_ name: String) -> ShrinkCenter {
            let made = ShrinkCenter(store: base.appendingPathComponent("\(name).json"), mac: "Mac A")
            made.quiet = 0
            made.editing = { _ in false }
            made.trash = { try FileManager.default.moveItem(at: $0, to: base.appendingPathComponent("Trash-" + UUID().uuidString)) }
            return made
        }
        func states(_ files: [S.File]?) -> String { (files ?? []).map { "\(($0.path as NSString).lastPathComponent) \($0.state) \($0.note ?? "") \($0.problem ?? "")" }.joined(separator: " | ") }
        let hd = S.Settings.compact.with(size: .hd, quality: .high)
        let projects = share.appendingPathComponent("Projects")
        let holding = share.appendingPathComponent(S.holdingName)
        var viewer = OfficeRenderServer.Device(id: UUID(), name: "Viewer", secret: Data(), added: .now)
        viewer.role = "viewer"
        var admin = viewer
        admin.role = "admin"

        // 1 A file left to the always-on Mac that never got to it: Resume here takes it back (its claim stops double work) and makes it.
        let awayFolder = projects.appendingPathComponent("Away/Rushes"), awayClip = awayFolder.appendingPathComponent("A200C001.mov")
        make(awayClip)
        let awayCenter = center("away")
        let awayID = awayCenter.add(scan(awayFolder), settings: hd, roots: [awayFolder.deletingLastPathComponent().path])
        if var file = awayCenter.run(awayID)?.files.first { file.state = .elsewhere; awayCenter.set(file, in: awayID) }
        awayCenter.reclaim(awayID)
        await awayCenter.resume(awayID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety 5: a file left to the always-on Mac that never made it: Resume here takes it back and makes it",
              awayCenter.run(awayID)?.files.first?.state == .done, states(awayCenter.run(awayID)?.files))
        // … and the always-on Mac, idle with a run still to do (restarted, or busy before), carries on when asked how it goes; not once stopped.
        let officeCenter = center("office")
        let officeID = officeCenter.add([S.File(path: "/v/O/x.mov", folder: "/v/O", size: 10, modified: old)], settings: hd, roots: ["/v/O"])
        let asked = ShrinkRemote.state(["id": officeID.uuidString], admin, center: officeCenter, run: false)
        _ = try? ShrinkRemote.stop(["id": officeID.uuidString], admin, center: officeCenter)
        let askedAfterStop = ShrinkRemote.state(["id": officeID.uuidString], admin, center: officeCenter, run: false)
        check("shrink safety 5: the always-on Mac carries on with a run still to do when asked, but not one stopped from the other Mac",
              asked["resumed"] as? Bool == true && askedAfterStop["resumed"] as? Bool != true, "\(asked["resumed"] ?? "nil") \(askedAfterStop["resumed"] ?? "nil")")

        // 2 A hold from the other Mac runs out unless it's renewed (that Mac asleep or quit); a Viewer can't hold or stop.
        let holdCenter = center("hold")
        holdCenter.hold(true, for: 0.3)
        let heldNow = holdCenter.held
        try? await Task.sleep(for: .seconds(0.6))
        check("shrink safety 5: a hold from the other Mac runs out unless renewed", heldNow && !holdCenter.held)
        let viewerHold = (try? ShrinkRemote.hold(["hold": true], viewer, center: holdCenter)) != nil
        let viewerStop = (try? ShrinkRemote.stop(["id": UUID().uuidString], viewer, center: holdCenter)) != nil
        let adminHold = (try? ShrinkRemote.hold(["hold": true], admin, center: holdCenter)) != nil && holdCenter.held
        check("shrink safety 5: only a Mac that may shrink there can hold or stop the always-on Mac's shrinks",
              !viewerHold && !viewerStop && adminHold, "viewer hold \(viewerHold) stop \(viewerStop) admin \(adminHold)")
        holdCenter.hold(false)

        // 3 Put Back with a part of the original missing from the folder to delete: the master stays at its name; with all parts, it goes back.
        let partsFolder = projects.appendingPathComponent("Parts/Rushes"), partsClip = partsFolder.appendingPathComponent("A201C001.mov")
        let partsPart = partsFolder.appendingPathComponent("A201C001.p2")
        let partsMoved = S.movedPath(partsClip.path, holding: holding)
        write(URL(fileURLWithPath: partsMoved), 1000)
        write(partsClip, 300)
        var parted = S.File(path: partsClip.path, folder: partsFolder.path, size: 1500, modified: old)
        parted.parts = [partsPart.path]
        parted.state = .done
        parted.master = partsClip.path
        parted.masterSize = 300
        parted.moved = partsMoved
        let trashBin = base.appendingPathComponent("PutBackTrash")
        try? fm.createDirectory(at: trashBin, withIntermediateDirectories: true)
        let toBin: (URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: trashBin.appendingPathComponent(UUID().uuidString)) }
        let missingPart = S.putBack(parted, settings: hd, trash: toBin)
        check("shrink safety 5: Put Back with a part missing from the folder to delete: nothing moves, the master stays at its name",
              missingPart.state == .done && missingPart.problem != nil && size(partsClip) == 300 && fm.fileExists(atPath: partsMoved),
              "\(missingPart.state) \(missingPart.problem ?? "") master \(size(partsClip) ?? -1)")
        write(URL(fileURLWithPath: (partsMoved as NSString).deletingLastPathComponent).appendingPathComponent(partsPart.lastPathComponent), 400)
        let wrongSize = S.putBack(parted, settings: hd, trash: toBin)
        check("shrink safety 5: Put Back with a part of another size: the master stays", wrongSize.state == .done && size(partsClip) == 300,
              "\(wrongSize.state) \(wrongSize.problem ?? "")")
        write(URL(fileURLWithPath: (partsMoved as NSString).deletingLastPathComponent).appendingPathComponent(partsPart.lastPathComponent), 500)
        let whole = S.putBack(parted, settings: hd, trash: toBin)
        check("shrink safety 5: Put Back with all of the original there: the original and its part back, the master to the Trash",
              whole.state == .restored && size(partsClip) == 1000 && size(partsPart) == 500, "\(whole.state) \(whole.problem ?? "")")

        // 4 The project travels to the always-on Mac as a place too (its age is looked at there), and this Mac keeps its own.
        var placed = S.File(path: "/a/P/Rushes/x.mov", folder: "/a/P/Rushes", size: 1, modified: old)
        placed.project = "/a/P"
        let mapped = ShrinkRemote.translated(placed) { "/mnt" + $0 }
        let projectCenter = center("project")
        let projectID = projectCenter.add([placed], settings: hd, roots: ["/a/P"])
        var back = placed
        back.state = .done
        back.project = ""
        ShrinkRemote.merge([back], into: projectID, center: projectCenter)
        check("shrink safety 5: a file's project is mapped for the always-on Mac; its results keep this Mac's project",
              mapped?.project == "/mnt/a/P" && projectCenter.run(projectID)?.files.first?.project == "/a/P" && projectCenter.run(projectID)?.files.first?.state == .done,
              "\(mapped?.project ?? "nil") \(projectCenter.run(projectID)?.files.first?.project ?? "nil")")

        // 5 Put Back of a proxy folder Resolve made again meanwhile: its proxies go back into it, never over one there; that one says why.
        let px = projects.appendingPathComponent("ProxyBack"), pxClip = px.appendingPathComponent("Rushes/A202C001.mov")
        make(pxClip)
        let pxProxy = px.appendingPathComponent("Proxy")
        write(pxProxy.appendingPathComponent("A202C001.mov"), 100)
        write(pxProxy.appendingPathComponent("A202C001_1.mov"), 110)
        let pxFiles = scan(pxClip.deletingLastPathComponent())
        let pxCenter = center("proxyback")
        let pxID = pxCenter.add(pxFiles, settings: hd, roots: [px.path], proxies: [pxFiles.first?.project ?? px.path: [pxProxy.path]])
        await pxCenter.resume(pxID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        let pxMoved = pxCenter.run(pxID)?.movedFolders[pxProxy.path]
        write(pxProxy.appendingPathComponent("A202C001.mov"), 50)
        await pxCenter.putBack(pxID)
        let pxRun = pxCenter.run(pxID)
        check("shrink safety 5: Put Back into a proxy folder made again: the proxies go back in, the new one is never replaced, the one left says why",
              pxMoved != nil && size(pxProxy.appendingPathComponent("A202C001_1.mov")) == 110 && size(pxProxy.appendingPathComponent("A202C001.mov")) == 50
              && pxMoved.map { size(URL(fileURLWithPath: $0).appendingPathComponent("A202C001.mov")) == 100 } == true && pxRun?.proxyNotes?[pxProxy.path] != nil,
              "moved \(pxMoved ?? "nil") notes \(pxRun?.proxyNotes ?? [:]) \(states(pxRun?.files))")

        // 6 + 9b + 10 The folder to delete: .DS_Store and ._ files are no reason not to delete; freed counts only what's gone from a share
        // that's there; the history row's drive facts come from the dashboard's look.
        let masterFile = base.appendingPathComponent("m.mov")
        write(masterFile, 100)
        let dsHolding = base.appendingPathComponent("DSShare").appendingPathComponent(S.holdingName)
        var fine = S.File(path: "/v/P/fine.mov", folder: "/v/P", size: 10, modified: old)
        fine.state = .done
        fine.checked = .now
        fine.checkProblems = []
        fine.master = masterFile.path
        fine.masterStamp = S.stamp(masterFile.path)
        fine.masterSize = 100
        fine.client = "Client"
        fine.projectName = "P"
        fine.moved = dsHolding.appendingPathComponent("v/P/fine.mov").path
        write(URL(fileURLWithPath: fine.moved ?? ""), 10)
        write(dsHolding.appendingPathComponent("v/P/.DS_Store"), 6)
        write(dsHolding.appendingPathComponent("v/P/._fine.mov"), 4)
        var deleted = fine
        deleted.path = "/v/P/deleted.mov"
        deleted.size = 1000
        deleted.moved = dsHolding.appendingPathComponent("v/P/deleted.mov").path
        var unmounted = deleted
        unmounted.path = "/v/P/unmounted.mov"
        unmounted.moved = "/Volumes/PluckNotMounted-\(UUID().uuidString.prefix(6))/\(S.holdingName)/P/unmounted.mov"
        let dsCenter = center("ds")
        let dsID = dsCenter.add([fine, deleted, unmounted], settings: hd, roots: ["/v/P"])
        for file in [fine, deleted, unmounted] { dsCenter.set(file, in: dsID) }
        let dsModel = ArchiveModel(center: dsCenter)
        await dsModel.refreshSpace()
        let dsPlace = dsModel.waiting.first { S.real($0.folder).path == S.real(dsHolding).path }
        check("shrink safety 5: .DS_Store and ._ files in the folder to delete are counted but never a reason not to delete",
              dsPlace?.unsafe == 0 && dsPlace?.unsafeFiles.isEmpty == true && dsPlace?.safe == 10 && (dsPlace?.bytes ?? 0) >= 16, // (a local disk may not list ._ files at all)
              "\(dsPlace.map { "safe \($0.safe) unsafe \($0.unsafe) \($0.unsafeFiles) bytes \($0.bytes)" } ?? "no place")")
        check("shrink safety 5: freed so far counts an original deleted from a share that's there, not one on a share not mounted",
              dsModel.freedSoFar == 900, "\(dsModel.freedSoFar)")
        check("shrink safety 5: the history row's Put Back is known from the dashboard's look (off the main thread)",
              dsModel.history[dsID]?.canPutBack == true, "\(String(describing: dsModel.history[dsID]))")

        // 7 Relinked A and B, A pointed back: B's warning stays; once B too, it goes.
        let relinkCenter = center("relink")
        let relinkID = relinkCenter.add([fine], settings: hd, roots: ["/v/P"])
        relinkCenter.markRelinked(relinkID, projects: ["A", "B"], back: false)
        relinkCenter.markRelinked(relinkID, projects: ["A"], back: true)
        let stillB = relinkCenter.run(relinkID)?.relinked != nil
        relinkCenter.markRelinked(relinkID, projects: ["B"], back: true)
        check("shrink safety 5: relinked two projects, one pointed back: the warning stays until both are",
              stillB && relinkCenter.run(relinkID)?.relinked == nil, "after A \(stillB) after B \(String(describing: relinkCenter.run(relinkID)?.relinked))")

        // 8 Two writers on one inventory: no line lost, one header.
        let inventoryFolder = base.appendingPathComponent("Inventory")
        let one = fine
        await Task.detached { DispatchQueue.concurrentPerform(iterations: 64) { _ in S.record(one, settings: hd, check: "x", in: inventoryFolder) } }.value
        let inventoryText = ((try? fm.contentsOfDirectory(atPath: inventoryFolder.path)) ?? []).compactMap {
            try? String(contentsOf: inventoryFolder.appendingPathComponent($0), encoding: .utf8)
        }.joined()
        let inventoryLines = inventoryText.split(separator: "\n")
        check("shrink safety 5: an inventory written by two at once keeps every line and one header",
              inventoryLines.count == 65 && inventoryLines.filter { $0.hasPrefix("date,") }.count == 1, "\(inventoryLines.count) lines")

        // 9a "Not touched" goes by each file's newest run: skipped once and archived later, it's not listed.
        let utCenter = center("untouched")
        var later = S.File(path: "/v/U/later.mov", folder: "/v/U", size: 200_000_000, modified: old)
        let olderID = utCenter.add([later], settings: hd, roots: ["/v/U"])
        later.state = .skipped
        later.note = "Recent project"
        utCenter.set(later, in: olderID)
        let newerID = utCenter.add([later], settings: hd, roots: ["/v/U"])
        later.state = .done
        later.note = nil
        utCenter.set(later, in: newerID)
        let utModel = ArchiveModel(center: utCenter)
        check("shrink safety 5: a file skipped once and archived later isn't in Not touched", !utModel.untouched.contains { $0.path == later.path },
              "\(utModel.untouched.map(\.path))")

        // 9c "You can free" leaves out originals whose master a destination run already made.
        var big = S.File(path: base.appendingPathComponent("Dest/P/big.mov").path, folder: base.appendingPathComponent("Dest/P").path, size: 40_000_000_000, modified: old)
        big.seconds = 600; big.fps = 25; big.width = 3840; big.height = 2160; big.codec = "prores"; big.kind = .rushes; big.channels = 2
        big.project = base.appendingPathComponent("Dest/P").path
        var survey = S.Survey(folders: [base.appendingPathComponent("Dest").path])
        survey.files = [big]
        let plainModel = ArchiveModel(center: center("plain"))
        plainModel.survey = survey
        let destCenter = center("dest")
        let destID = destCenter.add([big], settings: hd, destination: base.appendingPathComponent("Masters"), roots: [base.appendingPathComponent("Dest").path])
        var bigDone = big
        bigDone.state = .done
        bigDone.master = masterFile.path
        bigDone.masterSize = 100
        destCenter.set(bigDone, in: destID)
        let destModel = ArchiveModel(center: destCenter)
        destModel.survey = survey
        check("shrink safety 5: You can free leaves out an original whose master is already made in another folder",
              plainModel.freeable.saving > 0 && destModel.freeable.saving == 0,
              "plain \(plainModel.freeable.saving) \(plainModel.files.first.flatMap(plainModel.reason) ?? "") dest \(destModel.freeable.saving)")

        // 12 Lists opened in a spreadsheet: a cell that starts like a formula is kept as text.
        var formula = fine
        formula.client = "=HYPERLINK(1)"
        formula.projectName = "=HYPERLINK(1)"
        var formulaRun = S.Run(settings: hd, files: [formula])
        formulaRun.destination = base.appendingPathComponent("CSV").path
        S.writeReport(formulaRun)
        S.reportsWritten()
        let reportText = ((try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("CSV").path)) ?? []).filter { $0.hasSuffix(".csv") }.compactMap {
            try? String(contentsOf: base.appendingPathComponent("CSV").appendingPathComponent($0), encoding: .utf8)
        }.joined()
        var failedFormula = fine
        failedFormula.state = .failed
        failedFormula.note = "=1+2"
        let csvCenter = center("csv")
        let csvID = csvCenter.add([failedFormula], settings: hd, roots: ["/v/P"])
        csvCenter.set(failedFormula, in: csvID)
        let untouchedText = ArchiveModel(center: csvCenter).untouchedCSV()
        check("shrink safety 5: a cell starting with = + - @ is written as text in the lists",
              reportText.contains("HYPERLINK") && !reportText.contains("\"=HYPERLINK") && untouchedText.contains("1+2") && !untouchedText.contains("\"=1+2"),
              String(reportText.suffix(200)) + " | " + untouchedText)

        // B Broad delivery words (client, social, final, upload, master) above a rushes folder don't make rushes deliveries; clear ones do.
        let k = { S.classify($0, root: "/V/Share", project: "/V/Share/Job", tags: [:]).0 }
        check("shrink safety 5: Client interviews/Rushes, Social/Raw, Final/Raw are rushes; Export/Clips, Deliveries/Media, Renders/Raw stay deliveries",
              k("/V/Share/Job/Client interviews/Rushes/C0001.MP4") == .rushes && k("/V/Share/Job/Social/Raw/A001C001.mov") == .rushes
              && k("/V/Share/Job/Final/Raw/A001C001.mov") == .rushes && k("/V/Share/Job/Uploads/Footage/C0002.MP4") == .rushes
              && k("/V/Share/Job/Export/Clips/x.mov") == .deliveries && k("/V/Share/Job/Deliveries/Media/x.mov") == .deliveries
              && k("/V/Share/Job/Renders/Raw/x.mov") == .deliveries && k("/V/Share/Job/Final/x.mov") == .deliveries,
              "\(k("/V/Share/Job/Client interviews/Rushes/C0001.MP4")) \(k("/V/Share/Job/Social/Raw/A001C001.mov")) \(k("/V/Share/Job/Final/Raw/A001C001.mov"))")
        check("shrink safety 5: a project placed higher (Clients/<client>) doesn't make a gala's rushes deliveries",
              S.deliveryFolder("/V/Share/Clients/Acme/2024 Final Gala/Rushes/C0001.MP4", inside: "/V/Share/Clients/Acme") == nil
              && S.deliveryFolder("/V/Share/Clients/Acme/Gala/Export/x.mov", inside: "/V/Share/Clients/Acme") == "Export")
        let r = { S.classify($0, root: "/V/Share", tags: [:]).0 }
        check("shrink safety 5: real share layouts stay rushes",
              r("/V/Share/Brand Co/Video/Factory Visit/002_Production/001_Video-Opnames/C0001.MP4") == .rushes
              && r("/V/Share/Example.com/Video/Gala Roadshow/CITY/C0001.MP4") == .rushes)

        // C A project's age leaves out what the survey leaves out: NAS thumbnails (@eaDir), its recycle bin, templates, a folder to delete.
        let nasAged = projects.appendingPathComponent("NASAged"), nasClip = nasAged.appendingPathComponent("Rushes/A203C001.mov")
        make(nasClip)
        write(nasAged.appendingPathComponent("Rushes/@eaDir/A203C001.mov/SYNOPHOTO_THUMB_M.jpg"), 10, date: .now)
        write(nasAged.appendingPathComponent("#recycle/old.drp"), 10, date: .now)
        write(nasAged.appendingPathComponent("_Template/x.drp"), 10, date: .now)
        write(nasAged.appendingPathComponent("Old to delete/x.drp"), 10, date: .now)
        check("shrink safety 5: NAS thumbnails, recycle bin, templates and to-delete folders aren't an edit",
              !S.editedSince(nasAged.path, months: 6))
        let nasFiles = scan(nasClip.deletingLastPathComponent())
        let nasCenter = center("nasaged")
        let nasID = nasCenter.add(nasFiles, settings: hd, roots: [nasAged.path], months: 6)
        await nasCenter.resume(nasID, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check("shrink safety 5: an old project only the NAS touched is shrunk when the run goes",
              nasFiles.count == 1 && nasCenter.run(nasID)?.files.first?.state == .done, states(nasCenter.run(nasID)?.files))

        // D Finished per project: a project still to do (or on an offline other Mac) doesn't hold back a checked one.
        var fineQ = fine
        fineQ.path = "/v/Q/fine.mov"
        fineQ.projectName = "Q"
        var awayQ = fineQ
        awayQ.path = "/v/Q/away.mov"
        awayQ.state = .elsewhere
        awayQ.checked = nil
        let perProject = ArchiveModel(center: center("perproject")).checks(S.Run(settings: hd, files: [fine, fineQ, awayQ]))
        let lineP = perProject.first { $0.title == "Client – P" }, lineQ = perProject.first { $0.title == "Client – Q" }
        check("shrink safety 5: a checked project is safe while another project of the run waits on the other Mac; that one isn't",
              lineP?.safe == true && lineQ?.safe == false && lineQ?.finished == false, "\(perProject.map { "\($0.title) \($0.safe) \($0.finished)" })")
    }
}
