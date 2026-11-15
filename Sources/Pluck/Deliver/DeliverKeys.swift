import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A share link's key and what comes from it (§3): the room id, the signaling server's register key,
/// the proofs both ends make over the DTLS fingerprints, and the optional password's hash.
enum DeliverKeys {
    static let salt = Data("pluck-review/1".utf8)

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        plain += String(repeating: "=", count: (4 - plain.count % 4) % 4)
        return Data(base64Encoded: plain)
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { fatalError("no random bytes") }
        return Data(bytes)
    }


    static func derive(_ key: Data, _ info: String, _ count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    static func roomID(_ key: Data) -> String { base64url(derive(key, "room", 16)) }
    static func authKey(_ key: Data) -> Data { derive(key, "auth", 32) }
    /// Level 2: what a browser shows the signaling server to join (link holders only, not roomId knowers), and its hash.
    static func join(_ key: Data) -> String { base64url(derive(key, "join", 32)) }
    static func joinHash(_ key: Data) -> String { sha256(derive(key, "join", 32)) }

    // MARK: - Level 2: the owner-only root R (never in the link): the Worker registration secret and the room signing key

    static let salt2 = Data("pluck-review/2".utf8)

    static func derive2(_ root: Data, _ info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt2, info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    static func registerKey(root: Data) -> String { base64url(derive2(root, "register")) }
    static func signSeed(root: Data) -> Data { derive2(root, "sign") }
    static func signingKey(root: Data) -> Curve25519.Signing.PrivateKey? { try? .init(rawRepresentation: signSeed(root: root)) }
    /// The room's Ed25519 public key, b64url: the part after the `.` in the link.
    static func publicKey(root: Data) -> String { signingKey(root: root).map { base64url($0.publicKey.rawRepresentation) } ?? "" }

    static func helloMessage(macNonce: Data, fpMac: String, fpBrowser: String) -> Data {
        Data("pluck-review/2 server\n".utf8) + macNonce + Data(fpMac.utf8) + Data("\n".utf8) + Data(fpBrowser.utf8)
    }

    /// hello's `sig`: the server's proof that a link holder can't make.
    static func helloSignature(root: Data, macNonce: Data, fpMac: String, fpBrowser: String) -> String? {
        (try? signingKey(root: root)?.signature(for: helloMessage(macNonce: macNonce, fpMac: fpMac, fpBrowser: fpBrowser))).map(base64url)
    }

    /// What a browser checks before it sends anything (tests use it as the browser).
    static func checkHello(pub: String, sig: String, macNonce: Data, fpMac: String, fpBrowser: String) -> Bool {
        guard let raw = data(base64url: pub), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = data(base64url: sig) else { return false }
        return key.isValidSignature(signature, for: helloMessage(macNonce: macNonce, fpMac: fpMac, fpBrowser: fpBrowser))
    }

    static func sha256(_ data: Data) -> String { base64url(Data(SHA256.hash(data: data))) }

    static func proof(authKey: Data, role: String, macNonce: Data, browserNonce: Data, fpMac: String, fpBrowser: String) -> String {
        var message = Data("pluck-review/1 \(role)\n".utf8)
        message += macNonce + browserNonce + Data(fpMac.utf8) + Data("\n".utf8) + Data(fpBrowser.utf8)
        return base64url(Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: authKey))))
    }

    /// Same bytes, in time that doesn't depend on where they differ.
    static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Password (PBKDF2-SHA256, 210,000 rounds, 16-byte salt, 32-byte hash)

    static let rounds = 210_000

    static func pbkdf2(_ password: String, salt: Data, rounds: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let bytes = Array(password.utf8)
        salt.withUnsafeBytes { saltBytes in
            _ = bytes.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                                     bytes.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
            }
        }
        return Data(out)
    }

    static func hashPassword(_ password: String, salt: Data = random(16), rounds: Int = rounds) -> String {
        "pbkdf2-sha256$\(rounds)$\(base64url(salt))$\(base64url(pbkdf2(password, salt: salt, rounds: rounds)))"
    }

    static func checkPassword(_ password: String, _ stored: String) -> Bool {
        let parts = stored.split(separator: "$").map(String.init)
        guard parts.count == 4, parts[0] == "pbkdf2-sha256", let rounds = Int(parts[1]), (1...10_000_000).contains(rounds),
              let salt = data(base64url: parts[2]), let hash = data(base64url: parts[3]) else { return false }
        return same(pbkdf2(password, salt: salt, rounds: rounds), hash)
    }
}
