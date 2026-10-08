import Foundation
import Security

/// Checks that a downloaded binary is signed with an Apple-issued Developer ID from the expected team.
/// A matching checksum only proves the file wasn't corrupted in transit; this proves who built it.
enum CodeSignature {
    static func isSigned(_ url: URL, byTeam team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
}

/// Download links must point where we expect, over HTTPS.
enum TrustedHosts {
    static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
        url.scheme?.lowercased() == "https" && hosts.contains(url.host?.lowercased() ?? "")
    }
}
