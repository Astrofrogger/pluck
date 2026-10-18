import Foundation

/// RED clip folders (.RDC) as one item in Finder, when asked for in Settings: one thumbnail,
/// the space bar plays the whole take with its sound, a double-click opens it in the Player.
/// The type lives in a small app inside Pluck that's registered with macOS only while it's on, so
/// turning it off gives ordinary folders again.
enum RedClipFolders {
    static let key = "redClipsAsItems"

    private static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RedClipTypes.app") }
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Registers or unregisters the type (also at launch, so a moved or updated Pluck keeps it).
    static func apply(_ on: Bool = isOn) {
        guard FileManager.default.fileExists(atPath: helper.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = [on ? "-f" : "-u", helper.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
