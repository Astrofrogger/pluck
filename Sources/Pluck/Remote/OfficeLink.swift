import CryptoKit
import Foundation
import Network
import Security

/// The private line between a Mac at home and the office Mac for Edit Anywhere.
///
/// How it stays closed to the outside:
/// - The office Mac only answers private addresses (its own network, the private network Pluck
///   sets up for Edit Anywhere), never the internet, and only while "Edit Anywhere" is turned on.
/// - A Mac gets in once, by pairing: the office Mac shows a one-time code (ten minutes, five
///   wrong tries and it's gone). Pairing also does a fresh key exchange, so the
///   device's key never crosses the network in a form the code alone could open.
/// - Every message after that is encrypted and signed with that Mac's own 256-bit key
///   (ChaCha20-Poly1305), carries the time and a random nonce, and is refused if it's old,
///   from the future or seen before. Answers are bound to the question they answer.
/// - The office Mac can do six things for a paired Mac (list projects, timelines and presets,
///   start a render, report, cancel, send a small preview). No files, no shell, no settings.
/// - Paired Macs are listed on the office Mac and can be removed there at any time.
enum OfficeLink {
    static let port: UInt16 = 47_801
    /// How the office Mac shows up on its own network (Bonjour), for pairing without typing an
    /// address. It only tells that it's there; getting in still takes the pairing code.
    static let service = "_pluck-render._tcp"
    /// How far a message's clock may be off.
    static let clockWindow: TimeInterval = 120
    static let pairingLifetime: TimeInterval = 10 * 60
    static let pairingTries = 5
    static let maxRequest = 256 * 1024
    static let maxAnswer = 8 << 20
    /// A preview travels in pieces this big.
    static let previewChunk = 1_500_000

    enum Kind: UInt8 { case pair = 1, request = 2 }
    static let magic = Data("PLKR".utf8)

    enum Failure: LocalizedError {
        case unreachable, refused, badCode, expired, garbled, office(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: String(localized: "The host Mac didn’t answer. Check that it’s on, with Pluck open and sharing turned on in Edit Anywhere, and that the address is right.")
            case .refused: String(localized: "The host Mac refused this Mac. It may have been removed there (pair it again), or the two Macs’ clocks are more than two minutes apart.")
            case .badCode: String(localized: "That pairing code isn’t right, or it has expired. Make a new one on the host Mac.")
            case .expired: String(localized: "The pairing code has expired. Make a new one on the host Mac.")
            case .garbled: String(localized: "The answer from the host Mac couldn’t be verified, so it was ignored.")
            case .office(let message): message
            }
        }
    }

    // MARK: - Pairing codes

    /// Letters and digits that can't be mistaken for each other (no 0/O, 1/I/L, U).
    private static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 12 characters from 30 (about 59 bits). It works once, for ten minutes, with five tries:
    /// guessing online is hopeless, and cracking it from intercepted traffic would take days,
    /// long after it has expired (and the key exchange protects what pairing hands over anyway).
    static let codeLength = 12

    static func newPairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var code = ""
        for byte in bytes {
            // 256 isn't a multiple of 30: bytes from 240 up are redrawn so every character is as likely.
            var value = byte
            while value >= 240 {
                var extra: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &extra)
                value = extra
            }
            code.append(alphabet[Int(value) % alphabet.count])
        }
        return code
    }

    /// The code as shown: XXXX-XXXX-XXXX.
    static func formatted(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i -> String in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(4, code.count - i))])
        }.joined(separator: "-")
    }

    /// What was typed, without spaces or dashes, in capitals; nil if it can't be a code.
    static func normalised(_ typed: String) -> String? {
        let code = typed.uppercased().filter { alphabet.contains($0) }
        return code.count == codeLength ? code : nil
    }

    /// The key that seals the first pairing message, from the code and the asker's fresh public key.
    static func codeKey(_ code: String, clientKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("pluck-render-pair-v1".utf8),
                               info: clientKey, outputByteCount: 32)
    }

    /// The key that seals the office's answer: the key exchange and the code together.
    static func pairingAnswerKey(_ shared: SharedSecret, code: String, clientKey: Data, officeKey: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                       sharedInfo: Data("pluck-render-pair-answer-v1".utf8) + clientKey + officeKey, outputByteCount: 32)
    }

    // MARK: - Messages

    /// The keys a device secret gives: one for questions, one for answers (so neither can be
    /// bounced back as the other).
    static func keys(_ secret: Data) -> (request: SymmetricKey, answer: SymmetricKey) {
        let key = SymmetricKey(data: secret)
        let salt = Data("pluck-render-v1".utf8)
        return (HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("request".utf8), outputByteCount: 32),
                HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("answer".utf8), outputByteCount: 32))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// One frame on the wire: magic, kind, length, payload.
    static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var data = magic
        data.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(payload)
        return data
    }

    static func uuidData(_ id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }

    static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: - Which addresses may talk

    /// The office's own network, Tailscale (100.64.0.0/10 and fd7a:115c:a1e0::/48, inside the
    /// unique-local range) and VPNs on private ranges. Anything else (the internet) is refused.
    static func isPrivate(_ host: NWEndpoint.Host) -> Bool {
        if case .ipv4(let address) = host {
            let b = [UInt8](address.rawValue)
            if b.count == 4, b[0] == 100, (64...127).contains(b[1]) { return true }   // CGNAT: Tailscale
        }
        if case .ipv6(let address) = host {
            let b = [UInt8](address.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF,
               let v4 = IPv4Address(Data(b[12..<16])) {
                return isPrivate(.ipv4(v4))
            }
        }
        return LibraryServer.isLocal(host)
    }

    // MARK: - The keychain

    enum Keychain {
        private static let service = "Pluck Edit Anywhere"

        private static func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        static func save(_ data: Data, as account: String) {
            SecItemDelete(query(account) as CFDictionary)
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }

        static func load(_ account: String) -> Data? {
            var item = query(account)
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        static func delete(_ account: String) {
            SecItemDelete(query(account) as CFDictionary)
        }
    }
}

/// Reads one frame from a connection (or gives up), shared by both ends.
enum FrameReader {
    static func read(from connection: NWConnection, limit: Int, timeout: TimeInterval = 30,
                     done: @escaping @Sendable ((kind: OfficeLink.Kind, payload: Data)?) -> Void) {
        let once = OnceFlag()
        let finish: @Sendable ((kind: OfficeLink.Kind, payload: Data)?) -> Void = { result in
            if once.claim() { done(result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { head, _, _, error in
            guard error == nil, let head, head.count == 9, head.prefix(4) == OfficeLink.magic,
                  let kind = OfficeLink.Kind(rawValue: head[head.startIndex + 4]) else { return finish(nil) }
            let length = head.suffix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= limit else { return finish(nil) }
            collect(connection, remaining: length, into: Data()) { payload in
                finish(payload.map { (kind, $0) })
            }
        }
    }

    private static func collect(_ connection: NWConnection, remaining: Int, into buffer: Data, done: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { data, _, complete, error in
            guard error == nil, let data, !data.isEmpty else { return done(nil) }
            let buffer = buffer + data
            if data.count >= remaining { return done(buffer) }
            if complete { return done(nil) }
            collect(connection, remaining: remaining - data.count, into: buffer, done: done)
        }
    }
}

/// Lets exactly one of several callbacks through.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
