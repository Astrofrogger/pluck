import SwiftUI

/// Seams between the remote-edit areas built side by side, so none has to edit another's files.
/// Each is set once at launch by the area that provides it (nil until then: callers hide the feature).
@MainActor
enum RemoteHooks {
    /// B4 → B2: a player for a file on the host, streamed by ranges (share id, share-relative path of the original).
    static var player: ((_ share: String, _ path: String) -> AnyView)?
    /// B5 → B3: the mounted network folder holding a share's proxies (network-only mode), mounting it if needed.
    static var networkProxyRoot: ((_ share: String) async throws -> URL)?
    /// B2 → B3: the local folder holding a share's pulled proxies (with its RemoteManifest), if pulled.
    static var pulledProxyRoot: ((_ share: String) -> URL?)?
    /// B3 → B2/B5: link the proxies in this folder (with its RemoteManifest) into DaVinci Resolve.
    static var linkInResolve: ((_ root: URL) async throws -> Void)?
}

/// How this (remote) Mac works from one share's proxies: downloaded here, or streamed from the host.
/// Its own choice, per share; Resolve links from the folder of the chosen mode only.
enum RemoteProxyMode: String {
    case download, stream
    /// The streamed shares' ids, one per line (a string, so views can follow it with @AppStorage).
    static let key = "editAnywhereStreamShares"

    static func of(_ share: String, in streamed: String) -> RemoteProxyMode {
        streamed.split(separator: "\n").contains { $0 == share } ? .stream : .download
    }

    @MainActor static func of(_ share: String) -> RemoteProxyMode { of(share, in: UserDefaults.standard.string(forKey: key) ?? "") }

    /// Choices saved under the earlier key (a dictionary share id → mode) carried over once, at launch.
    @MainActor static func migrate() {
        let defaults = UserDefaults.standard, old = "editAnywhereShareModes"
        guard let modes = defaults.dictionary(forKey: old) else { return }
        if defaults.string(forKey: key) == nil {
            defaults.set(modes.filter { $0.value as? String == stream.rawValue }.keys.sorted().joined(separator: "\n"), forKey: key)
        }
        defaults.removeObject(forKey: old)
    }

    @MainActor static func set(_ mode: RemoteProxyMode, for share: String) {
        var ids = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init).filter { $0 != share }
        if mode == .stream { ids.append(share) }
        UserDefaults.standard.set(ids.joined(separator: "\n"), forKey: key)
    }
}

extension RemoteHooks {
    /// The folder a share's proxies are linked from, by the share's mode (nil: none yet).
    static func proxyRoot(_ share: String) async -> URL? {
        switch RemoteProxyMode.of(share) {
        case .download: pulledProxyRoot?(share)
        case .stream: try? await networkProxyRoot?(share)
        }
    }
}
