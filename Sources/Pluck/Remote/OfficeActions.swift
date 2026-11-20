import CryptoKit
import Foundation

/// Actions a paired Mac can ask the host, added from their own files: OfficeRenderServer.perform
/// handles its built-in ones and hands every other name here. An area registers its actions in
/// one `register()` of its own, listed once in `registerAll()`.
///
/// A handler gets the request's `args` and the paired Mac, and answers a dictionary (JSON). To send
/// raw bytes (a file piece), put them as Data under `bytesKey`: they travel after the JSON in a
/// binary frame, never base64; the client's `ask` gives them back under the same key.
@MainActor
enum OfficeActions {
    typealias Handler = @MainActor (_ arguments: [String: Any], _ device: OfficeRenderServer.Device) async throws -> [String: Any]

    nonisolated static let bytesKey = "bytes"
    private static var handlers: [String: Handler] = [:]

    static func register(_ name: String, _ handler: @escaping Handler) {
        assert(handlers[name] == nil, "action \(name) registered twice")
        handlers[name] = handler
    }

    static func handler(_ name: String) -> Handler? { handlers[name] }

    /// Every area's actions (each line one area's own file). Called when the server starts.
    static func registerAll() {
        guard handlers.isEmpty else { return }
        RemoteEditHost.register()
        RemoteProxyJobs.register()
        RemoteReview.register()
        RemoteNetworkHost.register()
        RemoteResolveProject.register()
        ReviewHosting.register()
        OfficeGroup.register()
        RemoteSendInto.register()
        RemoteAskFiles.register()
        OfficeAccess.register()
        RemoteDriveWriteHost.register()
        ShrinkRemote.register()
        RemoteMissing.register()
        // B1–B4 add one line each here, e.g. RemoteShares.register()
    }

    // MARK: - Checks for handlers

    static func require(_ right: KeyPath<OfficeRenderServer.Device.Rights, Bool>, _ device: OfficeRenderServer.Device,
                        refusal: String? = nil) throws {
        guard OfficeAccess.shared.rights(for: device)[keyPath: right] else {
            throw OfficeLink.Failure.office(refusal ?? String(localized: "The host Mac doesn’t allow this Mac to do that."))
        }
    }

    /// The check for every action that takes a path in a share: the path resolved inside the share (`..`, absolute
    /// paths and links out refused), then the right as the Mac has it in that folder (OfficeAccess: role, person,
    /// nearest folder role). Gives the resolved file.
    @discardableResult
    static func require(_ right: KeyPath<OfficeRenderServer.Device.Rights, Bool>, _ device: OfficeRenderServer.Device,
                        share: (root: URL, id: String), path: String, refusal: String? = nil) throws -> URL {
        let file = try RemoteEditHost.resolve(path, in: share.root)
        guard allowed(right, device, share: share, file: file) else {
            throw OfficeLink.Failure.office(refusal ?? String(localized: "The host Mac doesn’t allow this Mac to do that."))
        }
        return file
    }

    /// Whether a Mac has a right at an already resolved file of a share (listing and manifests hide what it hasn't).
    static func allowed(_ right: KeyPath<OfficeRenderServer.Device.Rights, Bool>, _ device: OfficeRenderServer.Device,
                        share: (root: URL, id: String), file: URL) -> Bool {
        allowed(right, device, share: share, relative: RemoteEditHost.relative(file, in: share.root))
    }

    /// The same for a checked path inside the share ("Day 1/A001.mov").
    static func allowed(_ right: KeyPath<OfficeRenderServer.Device.Rights, Bool>, _ device: OfficeRenderServer.Device,
                        share: (root: URL, id: String), relative: String) -> Bool {
        OfficeAccess.shared.rights(for: device, place: OfficeAccess.folderKey(root: share.root, share: share.id, relative: relative))[keyPath: right]
    }

    static func refused() -> OfficeLink.Failure {
        OfficeLink.Failure.office(String(localized: "The host Mac doesn’t allow this Mac to do that."))
    }

    /// Every action name the host answers to (the built-in ones of OfficeRenderServer.perform too), for the test that
    /// each one taking a path checks it.
    static var names: [String] { Array(handlers.keys) + OfficeRenderServer.builtInActions }
    /// Sending files into the office (inbox or a folder) is an Editor's right. Said in full, so an older home Mac that
    /// only shows the host's words still tells its user what to do.
    static var sendRefusal: String {
        String(localized: "Sending files to the office needs the Editor role. Ask the office to change this Mac’s role.")
    }

    static func incomplete() -> OfficeLink.Failure {
        OfficeLink.Failure.office(String(localized: "The request wasn’t complete."))
    }

    static func text(_ value: Any?, _ limit: Int = 1000, empty: Bool = false) throws -> String {
        guard let text = value as? String, empty || !text.isEmpty, text.count <= limit else { throw incomplete() }
        return text
    }

    static func number(_ value: Any?) throws -> Int64 {
        guard let number = (value as? NSNumber)?.int64Value, number >= 0 else { throw incomplete() }
        return number
    }

    // MARK: - Sealing an answer

    /// A sealed answer frame: JSON alone (`request`), or a 4-byte JSON length, the JSON and the raw
    /// bytes (`data`). Sealed with the answer key, bound to the question's nonce.
    nonisolated static func seal(_ json: Data, bytes: Data?, key: SymmetricKey, nonce: Data) -> Data? {
        guard let bytes else {
            return (try? ChaChaPoly.seal(json, using: key, authenticating: nonce)).map { OfficeLink.frame(.request, $0.combined) }
        }
        var length = UInt32(json.count).bigEndian
        var plain = Data(bytes: &length, count: 4)
        plain.reserveCapacity(4 + json.count + bytes.count)
        plain.append(json)
        plain.append(bytes)
        return (try? ChaChaPoly.seal(plain, using: key, authenticating: nonce)).map { OfficeLink.frame(.data, $0.combined) }
    }

    /// The JSON and bytes of an opened `data` answer.
    nonisolated static func split(_ plain: Data) -> (json: Data, bytes: Data)? {
        guard plain.count >= 4 else { return nil }
        let length = plain.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard plain.count >= 4 + length else { return nil }
        let start = plain.startIndex + 4
        return (Data(plain[start..<start + length]), Data(plain[(start + length)...]))
    }
}
