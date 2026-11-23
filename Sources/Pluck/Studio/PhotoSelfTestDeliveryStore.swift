import AppKit

extension PhotoSelfTest {
    /// Delivery Check's queue and specs (-PluckScreenshotOnly deliverystore): a brand's spec text finds its spec, Social
    /// takes 9:16, 1:1, 4:5 and 16:9, the queue and its reports come back after a relaunch (files that are gone stay out),
    /// and each queued file is checked against its own spec (a square clip passes Social, not Online).
    static func deliveryStoreTest() async {
        let social = DeliveryCheck.Destination.social.rawValue, online = DeliveryCheck.Destination.online.rawValue
        check("spec text: id", DeliveryCheck.specID(matching: "social") == social)
        check("spec text: name, any case", DeliveryCheck.specID(matching: " Broadcast EU ") == DeliveryCheck.Destination.broadcastEU.rawValue)
        check("spec text: full label", DeliveryCheck.specID(matching: DeliveryCheck.Destination.online.label) == online)
        check("spec text: unknown or empty is none", DeliveryCheck.specID(matching: "Cinema DCP") == nil && DeliveryCheck.specID(matching: "") == nil && DeliveryCheck.specID(matching: nil) == nil)
        let own = DeliveryCheck.save(DeliveryCheck.Spec(id: "x", name: "Client Web", aspect: 1))
        check("spec text: a saved spec by name", DeliveryCheck.specID(matching: "client web") == own.id)
        DeliveryCheck.delete(own)

        let shapes = DeliveryCheck.Destination.social.spec.allowedAspects
        check("social shapes", shapes.count == 4 && [9.0 / 16, 1, 4.0 / 5, 16.0 / 9].allSatisfy { w in shapes.contains { abs($0 - w) < 0.001 } })
        check("online: one shape", DeliveryCheck.Destination.online.spec.allowedAspects == [16.0 / 9])
        check("elsewhere: any shape", DeliveryCheck.Destination.other.spec.allowedAspects.isEmpty)

        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("DeliveryStoreTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("queue.json")
        let a = folder.appendingPathComponent("a.mov"), gone = folder.appendingPathComponent("gone.mov")
        try? Data("x".utf8).write(to: a)

        let issue = DeliveryCheck.Issue(severity: .warning, time: 1.5, title: "Black frame", detail: "d", box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), kind: .picture)
        let report = DeliveryCheck.Report(file: a, spec: DeliveryCheck.Destination.social.spec, duration: 4, fps: 25, size: CGSize(width: 1080, height: 1080),
                                          facts: [("Codec", "h264")], issues: [issue], loudness: -14, fileKey: "k")
        let first = DeliveryCheckStore(url: kept)
        first.items = [.init(file: a, specID: social, report: report), .init(file: gone, failed: "no")]
        first.current = first.items[0].id
        first.save()
        let second = DeliveryCheckStore(url: kept)
        let back = second.items.first
        check("queue: back after a relaunch, missing file dropped", second.items.count == 1 && back?.file == a)
        check("queue: its own spec", back?.specID == social)
        check("queue: report", back?.report?.issues.first?.title == "Black frame" && back?.report?.issues.first?.box == issue.box
              && back?.report?.facts.first?.1 == "h264" && back?.report?.size.width == 1080 && back?.report?.fileKey == "k")
        check("queue: the one shown", second.current == back?.id)

        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg") else { return check("delivery store: ffmpeg", false, "no ffmpeg") }
        let square = folder.appendingPathComponent("square.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x640:r=25:d=2", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=2",
                                                "-c:v", "mpeg4", "-q:v", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", square.path])
        UserDefaults.standard.set(online, forKey: "deliveryCheckDestination")
        let store = DeliveryCheckStore(url: nil)
        store.items = [.init(file: square, specID: social), .init(file: square)]
        store.check(all: false, manager: manager)
        await store.running?.value
        func wrongShape(_ item: DeliveryCheckStore.Item?) -> Bool? { item?.report.map { $0.issues.contains { $0.title == "Wrong picture shape" } } }
        check("per file: a square passes its own Social", wrongShape(store.items.first) == false, store.items.first?.failed ?? "")
        check("per file: and is wrong for the queue's Online", wrongShape(store.items.last) == true, store.items.last?.failed ?? "")
        store.setSpec(social, for: store.items[1].id, manager: manager)
        await store.running?.value
        check("per file: changing a spec checks it again", wrongShape(store.items.last) == false)
        // The spec changes while the file is being checked: the finished result is not kept, it's checked again for the new one.
        let busy = DeliveryCheckStore(url: nil)
        busy.items = [.init(file: square)]
        busy.check(all: false, manager: manager)
        busy.setSpec(social, for: busy.items[0].id, manager: manager)
        while let task = busy.running { await task.value }
        check("spec changed during a check: result is for the new spec", wrongShape(busy.items.first) == false && busy.items.first?.report?.spec.id == social,
              busy.items.first?.failed ?? "")
    }
}
