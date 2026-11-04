import Foundation
import Network

/// The network-facing checks, as pure functions: the shared Library's local-only addresses, Host
/// header, code lockout and login; paths and names other Macs send; links; site pictures; chapter
/// files; and the update's signing certificate.
extension EditSelfTest {
    static func network() {
        func host(_ text: String) -> NWEndpoint.Host { NWEndpoint.Host(text) }
        check("network local addresses",
              ["10.0.0.1", "192.168.1.1", "172.16.0.1", "127.0.0.1", "169.254.1.1", "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.2"]
                .allSatisfy { LibraryServer.isLocal(host($0)) }
              && !["8.8.8.8", "172.32.0.1", "11.0.0.1", "2001:4860::8888", "::ffff:8.8.8.8"].contains { LibraryServer.isLocal(host($0)) })

        check("network host header",
              ["192.168.1.5:47800", "[fe80::1]:47800", "macbook.local:47800", "macbook.local.", "localhost:47800", "127.0.0.1"]
                .allSatisfy { LibraryServer.isAllowedHost($0) }
              && ![nil, "", "evil.example.com", "192.168.1.5.evil.com:47800", "local", ".local", "[nonsense]"].contains { LibraryServer.isAllowedHost($0) })

        var lockout = LibraryServer.Lockout()
        let now = Date()
        for _ in 0..<9 { lockout.fail("a", now: now) }
        let nineOK = !lockout.isLocked("a", now: now)
        lockout.fail("a", now: now)
        check("network lockout per address",
              nineOK && lockout.isLocked("a", now: now) && !lockout.isLocked("b", now: now)
              && !lockout.isLocked("a", now: now.addingTimeInterval(LibraryServer.Lockout.window + 1)))
        var spread = LibraryServer.Lockout()
        for n in 0..<30 { spread.fail("10.0.0.\(n)", now: now) }
        check("network lockout everyone",
              spread.isLocked("10.0.0.200", now: now) && !spread.isLocked("10.0.0.200", now: now.addingTimeInterval(LibraryServer.Lockout.window + 1)))

        check("network code compare",
              LibraryServer.sameCode("012345", "012345") && !LibraryServer.sameCode("012346", "012345")
              && !LibraryServer.sameCode("01234", "012345") && !LibraryServer.sameCode("", "012345"))

        let withCode = LibraryServer.Request(head: "GET /api/library HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pluck-Code: 123456", body: Data())
        let withCookie = LibraryServer.Request(head: "GET /api/library HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: pluck_session=abc", body: Data())
        check("network only sessions get in",
              !LibraryServer.isAuthorised(withCode, sessions: ["abc"]) && LibraryServer.isAuthorised(withCookie, sessions: ["abc"])
              && !LibraryServer.isAuthorised(withCookie, sessions: ["other"]))

        let inbox = OfficeInbox.shared
        let bad = ["..", ".", "a/../b", "a/./b", "../x", "/abs", "", "a//b", ".hidden"]
        let refused = bad.filter { (try? inbox.target($0, from: "Mac")) == nil }
        check("network inbox paths", refused.count == bad.count && (try? inbox.target("Clips/A001.mov", from: "../Mac")) != nil,
              "accepted \(Set(bad).subtracting(refused))")

        check("network proxy paths",
              ProxySync.isSafe("Day 1/A001.mov") && !ProxySync.isSafe("..") && !ProxySync.isSafe("a/../b")
              && !ProxySync.isSafe("/etc/x") && !ProxySync.isSafe(""))

        check("network links",
              Links.validated("https://example.com/watch?v=1") != nil
              && ["javascript:alert(1)", "file:///etc/passwd", "http://", "ftp://example.com/x", "example"].allSatisfy { Links.validated($0) == nil })

        check("network site pictures",
              ["https://i.ytimg.com/vi/x/hq.jpg", "http://example.com/a.png"].allSatisfy { LibraryServer.isPublicWeb(URL(string: $0)!) }
              && !["http://127.0.0.1/a", "http://2130706433/a", "http://0x7f.1/a", "http://[::1]/a", "http://192.168.0.1/a",
                   "http://169.254.169.254/latest", "http://nas.local/a", "http://localhost:8080/a", "http://0.0.0.0/a",
                   "file:///etc/passwd", "ftp://example.com/a"].contains { LibraryServer.isPublicWeb(URL(string: $0)!) })

        check("network remote extension",
              NetworkLibraries.safeExtension("mp4") == "mp4" && NetworkLibraries.safeExtension("../../x") == "x"
              && NetworkLibraries.safeExtension("a/b:c") == "abc" && NetworkLibraries.safeExtension(nil) == "mp4"
              && NetworkLibraries.safeExtension("..") == "mp4")
        check("network saved code per address",
              NetworkLibraries.keychainAccount("Mac", URL(string: "http://10.0.0.5:47800")!)
                != NetworkLibraries.keychainAccount("Mac", URL(string: "http://10.0.0.6:47800")!))

        chapterPieces()
        updateSignature()
    }

    /// After a chapter split, only its own "NN - Title" files written since the download began.
    private static func chapterPieces() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-chapters-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let began = Date().addingTimeInterval(-60)
        func file(_ name: String, written: Date? = nil) -> URL {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            if let written { try? FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path) }
            return url
        }
        check("network chapter files",
              DownloadManager.isChapterPiece(file("01 - Intro.m4a"), since: began)
              && DownloadManager.isChapterPiece(file("102 - Late.m4a"), since: began)
              && !DownloadManager.isChapterPiece(file("notes.txt"), since: began)
              && !DownloadManager.isChapterPiece(file("02 - Old.m4a", written: began.addingTimeInterval(-3600)), since: began))
    }

    /// The update's certificate check: a signed tool has one, a changed copy of it has none.
    private static func updateSignature() {
        let signed = URL(fileURLWithPath: "/bin/ls")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-signed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        var data = (try? Data(contentsOf: signed)) ?? Data()
        if data.count > 0x6000 { data[data.count / 2] ^= 0xFF }
        try? data.write(to: copy)
        let original = CodeSignature.leafCertificate(signed, validate: true)
        check("network update certificate",
              original != nil && original == CodeSignature.leafCertificate(URL(fileURLWithPath: "/bin/cat"), validate: true)
              && CodeSignature.leafCertificate(copy, validate: true) == nil,
              "ls \(original ?? "nil"), changed copy \(CodeSignature.leafCertificate(copy, validate: true) ?? "nil")")
    }
}
