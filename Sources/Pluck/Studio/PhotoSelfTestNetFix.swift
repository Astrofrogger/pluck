import Foundation

extension PhotoSelfTest {
    /// Edit Anywhere's link mending itself (part of remoteiroh): the connection log's rotation and redaction, the
    /// messages, a home helper that listens at once with the office unreachable (then says why after a minute), a
    /// helper that quits while starting or while running started again (not a timeout), and wakes / network
    /// changes passed on. Offline: local pluck-iroh helpers only.
    static func irohRecoveryTest() async {
        // The log: the last 500 lines, ids cut.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("NetFix-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let savedLog = ConnectionLog.file
        ConnectionLog.file = base.appendingPathComponent("connection.log")
        let id = String(repeating: "ab", count: 32)
        for i in 0..<700 { ConnectionLog.add("test", "line \(i) \(id)") }
        let lines = ConnectionLog.text().split(separator: "\n")
        check("netfix: the log keeps about the last 500 lines", (ConnectionLog.keep...ConnectionLog.keep * 6 / 5).contains(lines.count)
              && lines.last?.hasSuffix("line 699 abababab…") == true, "\(lines.count) \(lines.last ?? "")")
        check("netfix: the log has no node id in full", !ConnectionLog.text().contains(id)
              && ConnectionLog.redact(String(repeating: "x", count: 900)).count == 400)
        ConnectionLog.file = savedLog

        // Messages.
        check("netfix: clear messages", PrivateNetwork.Failure.officeOffline.localizedDescription.contains("asleep")
              && PrivateNetwork.Failure.noRelay.localizedDescription.contains("relay")
              && PrivateNetwork.Failure.stopped("exit 1").localizedDescription.contains("exit 1")
              && PrivateNetwork.Failure.reconnecting.isBlip && !PrivateNetwork.Failure.timeout.isBlip)

        guard let real = PrivateNetwork.helper(.iroh) else {
            return note("SKIP netfix: helpers (no pluck-iroh in this build's Contents/Helpers)")
        }
        func local(_ name: String, _ more: [String: Any] = [:]) -> [String: Any] {
            ["local": true, "keyFile": base.appendingPathComponent("\(name).key").path, "officeAddrs": ["127.0.0.1:9"]].merging(more) { $1 }
        }
        let office = String(repeating: "cd", count: 32)

        // The office unreachable: listening at once, "Reconnecting…", after a minute why.
        let lonely = Tunnel(.home, .iroh)
        lonely.testSettings = local("lonely")
        defer { lonely.stop() }
        let started = Date.now
        do {
            try await lonely.start(office: office)
            check("netfix: home starts at once with the office unreachable", Date.now.timeIntervalSince(started) < 5 && lonely.listen != nil,
                  "\(Date.now.timeIntervalSince(started)) s")
        } catch {
            check("netfix: home starts at once with the office unreachable", false, error.localizedDescription)
        }
        for _ in 0..<70 where lonely.officeDown == nil { try? await Task.sleep(for: .milliseconds(500)) }
        check("netfix: office unreachable is a quiet blip first, then said", lonely.failure() == .reconnecting
              && lonely.failure(at: .now.addingTimeInterval(Tunnel.patience + 1)) == .officeOffline && !lonely.noRelay,
              "\(String(describing: lonely.officeDown)) \(String(describing: lonely.failure()))")

        // A helper that quits while starting: tried again, then said how, never a timeout.
        let flaky = base.appendingPathComponent("flaky.sh")
        try? "#!/bin/sh\nif [ ! -e \"$0.ran\" ]; then touch \"$0.ran\"; exit 3; fi\nexec '\(real.path)'\n".write(to: flaky, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flaky.path)
        let shaky = Tunnel(.home, .iroh, keyFile: base.appendingPathComponent("shaky.key"))
        shaky.testSettings = local("shaky", ["helper": flaky.path])
        defer { shaky.stop() }
        do {
            try await shaky.start(office: office)
            check("netfix: a helper that quits while starting is started again", shaky.listen != nil
                  && ConnectionLog.text().contains("stopped while starting (exit 3)"))
        } catch {
            check("netfix: a helper that quits while starting is started again", false, error.localizedDescription)
        }
        let dead = Tunnel(.home, .iroh)
        dead.testSettings = local("dead", ["helper": "/usr/bin/false"])
        let tried = Date.now
        do {
            try await dead.start(office: office)
            check("netfix: a helper that keeps quitting says how", false)
        } catch {
            let said = (error as? PrivateNetwork.Failure).map { if case .stopped(let how) = $0 { how == "exit 1" } else { false } } == true
            check("netfix: a helper that keeps quitting says how, not a timeout", said && Date.now.timeIntervalSince(tried) < 15, error.localizedDescription)
        }
        dead.stop()

        // A running helper that dies: "Reconnecting…", then a new one (the old one gone).
        guard let first = lonely.helperID else { return check("netfix: a helper that dies is started again", false, "not running") }
        kill(first, SIGKILL)
        for _ in 0..<40 where !lonely.restarting { try? await Task.sleep(for: .milliseconds(50)) }
        let quiet = lonely.failure() == .reconnecting
        for _ in 0..<100 where lonely.helperID == nil || lonely.helperID == first || lonely.listen == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check("netfix: a helper that dies is started again, quietly", quiet && lonely.helperID != nil && lonely.helperID != first
              && lonely.listen != nil && !lonely.restarting && kill(first, 0) != 0, "\(String(describing: lonely.helperID)) \(lonely.state)")

        // Wake / network change: passed on to running helpers; one Pluck wants but that's gone comes back.
        let marks = ConnectionLog.text().components(separatedBy: "networkChecked").count
        Tunnel.networkChanged("test: network changed")
        for _ in 0..<50 where ConnectionLog.text().components(separatedBy: "networkChecked").count < marks + 2 { try? await Task.sleep(for: .milliseconds(100)) }
        check("netfix: a network change reaches the running helpers", ConnectionLog.text().components(separatedBy: "networkChecked").count >= marks + 2)
        check("netfix: a stopped tunnel doesn't follow network changes", dead.helperID == nil && dead.wanted == nil)
    }
}
