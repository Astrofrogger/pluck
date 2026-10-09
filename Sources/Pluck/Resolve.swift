import AppKit
import Foundation

/// Send to DaVinci Resolve: imports files into a "Pluck" bin of the project open in Resolve,
/// through Resolve's own scripting (its bundled Python, so nothing else needs installing).
enum Resolve {
    private static let app = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
    private static let python = app.appendingPathComponent("Contents/Applications/ResolvePython")
    private static let library = app.appendingPathComponent("Contents/Libraries/Fusion/fusionscript.so")
    private static let scripting = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: library.path)
    }

    enum Failure: LocalizedError {
        case notReachable, noProject, importFailed, other(String)

        var errorDescription: String? {
            switch self {
            case .notReachable:
                String(localized: "Pluck couldn’t reach DaVinci Resolve. Open DaVinci Resolve Studio and set Preferences › System › General › External scripting using to Local. (The free version of Resolve doesn’t allow this.)")
            case .noProject: String(localized: "Open a project in DaVinci Resolve first.")
            case .importFailed: String(localized: "DaVinci Resolve couldn’t import the file.")
            case .other(let message): message
            }
        }
    }

    /// The script Resolve's Python runs: file paths come in as arguments.
    private static let script = """
    import sys
    sys.path.append(sys.argv[1])
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        print("PLUCK:notReachable"); sys.exit(0)
    project = resolve.GetProjectManager().GetCurrentProject()
    if project is None:
        print("PLUCK:noProject"); sys.exit(0)
    pool = project.GetMediaPool()
    root = pool.GetRootFolder()
    bin = next((f for f in root.GetSubFolderList() if f.GetName() == "Pluck"), None) or pool.AddSubFolder(root, "Pluck")
    if bin:
        pool.SetCurrentFolder(bin)
    items = pool.ImportMedia(sys.argv[2:]) or []
    print("PLUCK:imported:%d:%s" % (len(items), project.GetName()))
    """

    /// Imports the files; returns the project name.
    static func send(_ files: [URL]) async throws -> String {
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", script, scripting + "/Modules"] + files.map(\.path)
            var environment = ProcessInfo.processInfo.environment
            environment["RESOLVE_SCRIPT_API"] = scripting
            environment["RESOLVE_SCRIPT_LIB"] = library.path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PLUCK:") }) else {
            throw Failure.other(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Failure.notReachable.localizedDescription : String(output.suffix(300)))
        }
        let parts = line.split(separator: ":", maxSplits: 3).map(String.init)
        switch parts.count > 1 ? parts[1] : "" {
        case "notReachable": throw Failure.notReachable
        case "noProject": throw Failure.noProject
        case "imported" where parts.count == 4 && (Int(parts[2]) ?? 0) > 0: return parts[3]
        default: throw Failure.importFailed
        }
    }

    /// Sends the files and brings Resolve forward; explains what went wrong if it didn't work.
    @MainActor
    static func sendAndShow(_ files: [URL]) {
        Task {
            do {
                _ = try await send(files)
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t send to DaVinci Resolve")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
