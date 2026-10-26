import Foundation

/// Offload projects (Task 1): cards recognised, folders named, what's already in the project
/// skipped, and nothing written over; on made-up cards in a temporary folder.
extension EditSelfTest {
    static func offloadProjects() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-offload-projects-\(UUID().uuidString)", isDirectory: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        cardRecognition(base)
        offloadTemplates()
        await planSkips(base)
        await oneFolderPerPerson(base)
        await twoCardsAtOnce(base)
        await alreadyThereOnEveryDrive(base)
        await cardBeforeBackup(base)
        await cameraRemembered(base)
        await offloadWithoutProject(base)
        // The throwaway projects, jobs and cards aren't kept.
        for project in OffloadProjects.shared.projects where project.name.hasPrefix("Self Test") { OffloadProjects.shared.remove(project.id) }
        for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Made-up cards

    private static func put(_ data: Data, _ path: String, in folder: URL) {
        let url = folder.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func put(_ text: String, _ path: String, in folder: URL) { put(Data(text.utf8), path, in: folder) }

    /// An MP4 box: its size, its type, what's in it.
    private static func box(_ type: String, _ content: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(content.count + 8).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        return data + content
    }

    /// A GoPro metadata text (key, "c", 1 byte each, how many, the text padded to 4).
    private static func gpmf(_ key: String, _ text: String) -> Data {
        var data = Data(key.utf8)
        data.append(contentsOf: [UInt8(ascii: "c"), 1, UInt8(text.utf8.count >> 8), UInt8(text.utf8.count & 0xFF)])
        data.append(contentsOf: Array(text.utf8))
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private static func sonyXML(_ serial: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
          <Duration value="250"/>
          <Device manufacturer="Sony" modelName="ILCE-7SM3" serialNo="\(serial)"/>
        </NonRealTimeMeta>
        """
    }

    /// A card of clips C0001… (each its own bytes, `seed` changing them), in DCIM/100MEDIA.
    private static func clipCard(_ folder: URL, _ numbers: ClosedRange<Int>, seed: String = "") {
        for n in numbers {
            put("clip \(n) \(seed) " + String(repeating: "\(n % 10)", count: 2000 + n), String(format: "DCIM/100MEDIA/C%04d.MP4", n), in: folder)
        }
    }

    private static func offloadProject(_ name: String, drive: URL, operators: [String]) -> OffloadProject {
        var project = OffloadProject(name: name)
        project.drives = [drive.path]
        let letters = ["A", "B", "C"]
        project.operators = operators.enumerated().map { OffloadProject.Operator(name: $1, letter: letters[$0]) }
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        OffloadProjects.shared.save(project)
        return project
    }

    /// The newest job, once it's done (or nil after 30 s).
    private static func finished() async -> OffloadJob? {
        guard let id = OffloadCenter.shared.jobs.first?.id else { return nil }
        for _ in 0..<300 {
            if let job = OffloadCenter.shared.jobs.first(where: { $0.id == id }), OffloadCenter.shared.state(job) == .done { return job }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: - Checks

    private static func cardRecognition(_ base: URL) {
        let red = base.appendingPathComponent("RED")
        put(Data(count: 64), "A001_C001_0921K7.RDC/A001_C001_0921K7_001.R3D", in: red)
        let sony = base.appendingPathComponent("SONY")
        put(Data(count: 64), "PRIVATE/M4ROOT/CLIP/C0001.MP4", in: sony)
        put(sonyXML("1234567"), "PRIVATE/M4ROOT/CLIP/C0001M01.XML", in: sony)
        let gopro = base.appendingPathComponent("GOPRO")
        let movie = box("ftyp", Data("isom\0\0\0\0".utf8)) + box("mdat", Data(count: 32))
            + box("moov", box("udta", box("GPMF", gpmf("MINF", "HERO11 Black") + gpmf("CASN", "C3471325000000"))))
        put(movie, "DCIM/100GOPRO/GX010001.MP4", in: gopro)
        let plain = base.appendingPathComponent("PLAIN")
        put(Data(count: 64), "DCIM/100MEDIA/IMG_0001.JPG", in: plain)

        let cards = [CameraCard.read(red), CameraCard.read(sony), CameraCard.read(gopro), CameraCard.read(plain)]
        let ok = cards[0].brand == "RED" && cards[0].key == "RED A" && cards[0].letter == "A"
            && cards[1].brand == "Sony" && cards[1].key == "Sony 1234567" && cards[1].model == "ILCE-7SM3"
            && cards[2].brand == "GoPro" && cards[2].key == "GoPro C3471325000000" && cards[2].model == "HERO11 Black"
            && cards[3].brand == "Camera" && cards[3].key == nil
        check("card recognises cameras", ok, "RED A, Sony 1234567, GoPro C3471325000000, Camera nil; got "
              + cards.map { "\($0.brand) \($0.key ?? "nil") \($0.model ?? "")" }.joined(separator: ", "))
    }

    private static func offloadTemplates() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 7; parts.day = 12; parts.hour = 12
        let date = Calendar.current.date(from: parts) ?? .now
        let project = OffloadProject(name: "Festival")
        // Day 1 is the day the first card was offloaded, or today while there isn't one.
        var earlier = OffloadJob(name: "A001", source: "/Volumes/A001", sourceVolume: "A001", roots: ["/Volumes/RAID"], rootVolumes: ["RAID"], files: [])
        earlier.project = project.id
        earlier.started = date.addingTimeInterval(-86_400)
        var later = earlier
        later.started = date
        var other = earlier
        other.project = UUID()
        other.started = date.addingTimeInterval(-5 * 86_400)
        let first = project.firstOffload(in: [later, other, earlier])
        let day = project.day(of: date, firstOffload: first)
        check("day number counts from the first card", first == earlier.started && project.firstOffload(in: [other]) == nil
              && project.day(of: date) == 1 && day == 2,
              "first card yesterday, day 2; none yet, day 1; got \(String(describing: first)), \(project.day(of: date)), \(day)")
        func render(_ template: String) -> String {
            FolderTemplate.render(template, date: date, day: day, letter: "A", operator: "Operator A", camera: "", card: 4)
        }
        let got = [render(project.dayFolder.template), render(project.operatorFolder), render(project.cardFolder.template), render("Day {day}")]
        check("templates render", got == ["2026-07-12", "A_Operator A", "A004", "Day 2"],
              "2026-07-12, A_Operator A, A004, Day 2; got \(got.joined(separator: ", "))")
        check("templates make safe names", FolderTemplate.render("a/b:{letter}", date: date, day: 1, letter: "A", operator: "", camera: "", card: 1) == "a-b-A",
              "slashes and colons replaced")
    }

    /// Card 2 repeats 40 of card 1's files and adds 12: only the 12 are copied.
    private static func planSkips(_ base: URL) async {
        let drive = base.appendingPathComponent("Drive Skip", isDirectory: true)
        let made = offloadProject("Self Test Skip", drive: drive, operators: ["Operator A"])
        let first = base.appendingPathComponent("Card Skip 1"), second = base.appendingPathComponent("Card Skip 2")
        clipCard(first, 1...40)
        clipCard(second, 1...52)
        let person = made.operators[0].id
        let problem = await OffloadCenter.shared.add(card: first, project: made.id, operator: person, camera: CameraCard(brand: "Camera"))
        guard problem == nil, let one = await finished() else { return check("plan skips what's there", false, "card 1: \(problem ?? "didn't finish")") }
        guard let now = OffloadProjects.shared.project(made.id), let who = now.person(person) else { return check("plan skips what's there", false, "no project") }
        let files = OffloadCenter.files(in: second).map { OffloadFile(path: $0.path, size: $0.size, modified: $0.modified, done: [false]) }
        let plan = await Task.detached { OffloadProjectPlanner.plan(card: second, files: files, project: now, operator: who, date: .now) }.value
        check("plan skips what's there", plan.files.count == 12 && plan.alreadyThere == 40 && plan.label == "A002" && one.card == "A001",
              "12 to copy, 40 there, A001 then A002; got \(plan.files.count), \(plan.alreadyThere), \(one.card ?? "nil") then \(plan.label)")
        let problem2 = await OffloadCenter.shared.add(card: second, project: made.id, operator: person, camera: CameraCard(brand: "Camera"))
        let two = problem2 == nil ? await finished() : nil
        check("job says what's already there", two?.alreadyThere == 40 && two?.files.count == 12 && two?.problems.isEmpty == true
              && two?.targets.first?.hasSuffix("/A002") == true,
              "40 there, 12 copied into A002; got \(problem2 ?? ""), \(two?.alreadyThere ?? -1), \(two?.files.count ?? -1), \(two?.targets.first ?? "")")
    }

    /// Day and card folders off: two cards each with a different C0001.MP4, and one the same.
    private static func oneFolderPerPerson(_ base: URL) async {
        let drive = base.appendingPathComponent("Drive Person", isDirectory: true)
        var made = offloadProject("Self Test Person", drive: drive, operators: ["Operator A"])
        made.dayFolder.on = false
        made.cardFolder.on = false
        OffloadProjects.shared.save(made)
        let first = base.appendingPathComponent("Card Person 1"), second = base.appendingPathComponent("Card Person 2")
        put("first card clip", "DCIM/100MEDIA/C0001.MP4", in: first)
        put("other card clip", "DCIM/100MEDIA/C0001.MP4", in: second)
        put("the same clip", "DCIM/100MEDIA/C0002.MP4", in: first)
        put("the same clip", "DCIM/100MEDIA/C0002.MP4", in: second)
        let person = made.operators[0].id
        var problems: [String] = []
        if let problem = await OffloadCenter.shared.add(card: first, project: made.id, operator: person, camera: CameraCard(brand: "Camera")) { problems.append(problem) }
        _ = await finished()
        if let problem = await OffloadCenter.shared.add(card: second, project: made.id, operator: person, camera: CameraCard(brand: "Camera")) { problems.append(problem) }
        let two = await finished()
        let folder = drive.appendingPathComponent("Self Test Person/A_Operator A/DCIM/100MEDIA")
        func text(_ name: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        let ok = problems.isEmpty && text("C0001.MP4") == "first card clip" && text("C0001_A002.MP4") == "other card clip"
            && text("C0002.MP4") == "the same clip" && text("C0002_A002.MP4") == nil && two?.alreadyThere == 1 && two?.problems.isEmpty == true
        check("one folder per person", ok, "C0001 kept, C0001_A002 added, C0002 once; got \(problems), "
              + "\(text("C0001.MP4") ?? "nil") / \(text("C0001_A002.MP4") ?? "nil") / there \(two?.alreadyThere ?? -1)")
        // The MHL lists the copy by its new name, so a check of the folder finds it.
        let listed = MHL.items(in: drive.appendingPathComponent("Self Test Person/A_Operator A"))?.map(\.path) ?? []
        check("renamed file in the MHL", listed.contains("DCIM/100MEDIA/C0001_A002.MP4") && listed.contains("DCIM/100MEDIA/C0001.MP4"),
              "both C0001s listed; got \(listed)")
    }

    /// These jobs, once they're all done or stopped (nil after 60 s).
    private static func settled(_ ids: [UUID]) async -> [OffloadJob]? {
        let center = OffloadCenter.shared
        for _ in 0..<600 {
            let jobs = ids.compactMap { id in center.jobs.first { $0.id == id } }
            if jobs.count == ids.count, jobs.allSatisfy({ job in
                switch center.state(job) { case .done, .stopped: true; default: false }
            }) { return jobs }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Two cards in at once into one person's folder, each with a different C0001.MP4: planned one
    /// after the other, so the second is renamed rather than failing (or writing over the first).
    private static func twoCardsAtOnce(_ base: URL) async {
        let drive = base.appendingPathComponent("Drive Together", isDirectory: true)
        var made = offloadProject("Self Test Together", drive: drive, operators: ["Operator A"])
        made.dayFolder.on = false
        made.cardFolder.on = false
        OffloadProjects.shared.save(made)
        let first = base.appendingPathComponent("Card Together 1"), second = base.appendingPathComponent("Card Together 2")
        put("card one clip", "DCIM/100MEDIA/C0001.MP4", in: first)
        put("card two clip", "DCIM/100MEDIA/C0001.MP4", in: second)
        let person = made.operators[0].id, center = OffloadCenter.shared, project = made.id
        let before = Set(center.jobs.map(\.id))
        async let one = center.add(card: first, project: project, operator: person, camera: CameraCard(brand: "Camera"))
        async let two = center.add(card: second, project: project, operator: person, camera: CameraCard(brand: "Camera"))
        let problems = await [one, two].compactMap { $0 }
        let ids = center.jobs.filter { !before.contains($0.id) && $0.project == project }.map(\.id)
        let jobs = await settled(ids) ?? []
        let folder = drive.appendingPathComponent("Self Test Together/A_Operator A/DCIM/100MEDIA")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let texts = Set(names.compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) })
        check("two cards at once never collide", problems.isEmpty && jobs.count == 2 && jobs.allSatisfy { $0.problems.isEmpty }
              && names.count == 2 && texts == ["card one clip", "card two clip"],
              "both C0001s kept, one renamed, no problems; got \(problems), \(jobs.map(\.problems.count)), \(names)")
    }

    /// A clip only counts as already there when every drive of the project has it: one missing
    /// from the second drive is copied again.
    private static func alreadyThereOnEveryDrive(_ base: URL) async {
        let main = base.appendingPathComponent("Drive Every 1", isDirectory: true), second = base.appendingPathComponent("Drive Every 2", isDirectory: true)
        var made = offloadProject("Self Test Every", drive: main, operators: ["Operator A"])
        try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        made.drives.append(second.path)
        OffloadProjects.shared.save(made)
        let card = base.appendingPathComponent("Card Every")
        clipCard(card, 1...5)
        let person = made.operators[0].id
        let problem = await OffloadCenter.shared.add(card: card, project: made.id, operator: person, camera: CameraCard(brand: "Camera"))
        guard problem == nil, let one = await finished(), let folder = one.targets.last else {
            return check("already there means on every drive", false, "card 1: \(problem ?? "didn't finish")")
        }
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent("DCIM/100MEDIA/C0003.MP4"))
        guard let now = OffloadProjects.shared.project(made.id), let who = now.person(person) else { return check("already there means on every drive", false, "no project") }
        let files = OffloadCenter.files(in: card).map { OffloadFile(path: $0.path, size: $0.size, modified: $0.modified, done: [false, false]) }
        let plan = await Task.detached { OffloadProjectPlanner.plan(card: card, files: files, project: now, operator: who, date: .now) }.value
        check("already there means on every drive", plan.alreadyThere == 4 && plan.files.map(\.path) == ["DCIM/100MEDIA/C0003.MP4"],
              "C0003 copied again, 4 there; got \(plan.alreadyThere), \(plan.files.map(\.path))")
    }

    /// A card put in while a backup copies goes first: the backup stops where it is and carries on after.
    private static func cardBeforeBackup(_ base: URL) async {
        let center = OffloadCenter.shared
        let main = base.appendingPathComponent("Backup Source", isDirectory: true)
        let backupDrive = base.appendingPathComponent("Backup Drive", isDirectory: true)
        let card = base.appendingPathComponent("Card Before Backup", isDirectory: true)
        let drive = base.appendingPathComponent("Drive Before Backup", isDirectory: true)
        for folder in [backupDrive, drive] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for n in 1...6 { put(Data(repeating: UInt8(n), count: 4 << 20), "B\(n).MOV", in: main) }
        clipCard(card, 1...2)
        func job(_ source: URL, to root: URL, name: String) -> OffloadJob {
            let files = OffloadCenter.files(in: source).map { OffloadFile(path: $0.path, size: $0.size, modified: $0.modified, done: [false]) }
            return OffloadJob(name: name, source: source.path, sourceVolume: source.lastPathComponent, roots: [root.path],
                              rootVolumes: [root.lastPathComponent], files: files)
        }
        var backup = job(main, to: backupDrive, name: "Self Test Backup")
        backup.backup = UUID()
        let offload = job(card, to: drive, name: "Self Test Card")
        center.enqueue(backup)
        center.enqueue(offload)
        let jobs = await settled([backup.id, offload.id]) ?? []
        let done = jobs.first { $0.id == backup.id }, cardJob = jobs.first { $0.id == offload.id }
        let copied = (1...6).allSatisfy { n in
            (try? Data(contentsOf: backupDrive.appendingPathComponent("Self Test Backup/B\(n).MOV"))) == Data(repeating: UInt8(n), count: 4 << 20)
        }
        check("a card goes before a backup", done?.finished != nil && cardJob?.finished != nil && copied && done?.problems.isEmpty == true
              && (cardJob?.finished ?? .distantFuture) < (done?.finished ?? .distantPast),
              "card done first, the backup after with every file; got card \(String(describing: cardJob?.finished)), backup \(String(describing: done?.finished)), copied \(copied)")
    }

    /// A camera's operator is asked once, then known; a card that doesn't say is asked every time.
    private static func cameraRemembered(_ base: URL) async {
        let drive = base.appendingPathComponent("Drive Cameras", isDirectory: true)
        let made = offloadProject("Self Test Cameras", drive: drive, operators: ["Operator A", "Operator B"])
        let b = made.operators[1].id
        let sony1 = base.appendingPathComponent("Card Sony 1"), sony2 = base.appendingPathComponent("Card Sony 2")
        for (card, clip) in [(sony1, "one"), (sony2, "two")] {
            put("sony clip \(clip)", "PRIVATE/M4ROOT/CLIP/C0001.MP4", in: card)
            put(sonyXML("7654321"), "PRIVATE/M4ROOT/CLIP/C0001M01.XML", in: card)
        }
        let plain = base.appendingPathComponent("Card Plain")
        put("plain clip", "DCIM/100MEDIA/IMG_0001.MP4", in: plain)
        let center = OffloadCenter.shared

        _ = await center.offload(card: sony1, project: made.id)
        let asked = center.questions.first { $0.volume == sony1 }
        var answered: String?
        if let asked { answered = await center.answer(asked.id, operator: b) }
        _ = await finished()
        let jobs = center.jobs.count
        let problem = await center.offload(card: sony2, project: made.id)
        let started = center.jobs.count == jobs + 1 ? center.jobs.first : nil
        _ = await finished()
        check("camera remembered", asked != nil && answered == nil && problem == nil && !center.questions.contains { $0.volume == sony2 }
              && started?.operatorID == b && OffloadProjects.shared.project(made.id)?.cameras["Sony 7654321"] == b,
              "asked once, then B's without asking; got asked \(asked != nil), \(answered ?? ""), \(problem ?? ""), started \(started != nil)")

        _ = await center.offload(card: plain, project: made.id)
        let again = center.questions.first { $0.volume == plain }
        check("a card without a serial is asked", again != nil && again?.preselected == b,
              "asked, B suggested; got \(again != nil), \(again?.preselected == b)")
        if let again { center.dismiss(again.id) }
    }

    /// Without a project, an offload goes where it always did.
    private static func offloadWithoutProject(_ base: URL) async {
        let drive = base.appendingPathComponent("Drive Plain", isDirectory: true)
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let card = base.appendingPathComponent("Card No Project")
        clipCard(card, 1...3)
        let problem = await OffloadCenter.shared.add(source: card, roots: [drive], name: "2026-10-26 Card")
        let job = problem == nil ? await finished() : nil
        let there = FileManager.default.fileExists(atPath: drive.appendingPathComponent("2026-10-26 Card/DCIM/100MEDIA/C0002.MP4").path)
        check("offload without project unchanged", job?.targets == [drive.appendingPathComponent("2026-10-26 Card").path] && there
              && job?.project == nil && job?.renames == nil && job?.problems.isEmpty == true,
              "into Drive Plain/2026-10-26 Card; got \(problem ?? ""), \(job?.targets ?? []), \(there)")
        // A job saved before projects still opens.
        let old = #"{"id":"6F1C2C4A-1D2B-4C3E-9A8B-0123456789AB","name":"2026-10-17 A001","source":"/Volumes/A001","sourceVolume":"A001","roots":["/Volumes/RAID"],"rootVolumes":["RAID"],"files":[{"path":"C0001.MP4","size":10,"modified":0,"done":[true]}],"started":0,"finished":10}"#
        let decoded = try? JSONDecoder().decode(OffloadJob.self, from: Data(old.utf8))
        check("old offload jobs decode", decoded?.targets == ["/Volumes/RAID/2026-10-17 A001"] && decoded?.project == nil && decoded?.destination(of: "C0001.MP4") == "C0001.MP4",
              "decodes without the project fields")
    }
}
