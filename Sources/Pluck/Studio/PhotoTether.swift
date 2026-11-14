import ImageCaptureCore
import SwiftUI

/// Tethered shooting: a camera on a cable (ImageCaptureCore, PTP: most Canon and Nikon bodies, others that allow it) fires from
/// Pluck and each photo comes straight to this Mac, into a dated folder in Pictures › Pluck Tethered and its album, and shows
/// at once. Cameras macOS can't fire (Sony's, mostly) shoot through their maker's own remote app: Pluck then watches the
/// folder that app saves to and brings each new photo in the same way.
@MainActor
@Observable
final class PhotoTether: NSObject {
    static let shared = PhotoTether()

    enum Mode: String { case camera, folder }
    private(set) var cameras: [ICCameraDevice] = []
    private(set) var camera: ICCameraDevice?
    private(set) var ready = false
    private(set) var canFire = false
    private(set) var note: String?
    private(set) var shot = 0
    /// The last photo brought in (its path), to show.
    private(set) var latest: String?
    /// Where photos go, and their album.
    private(set) var folder: URL?
    private(set) var album: UUID?
    /// Folder mode: the folder watched.
    private(set) var watched: URL?

    @ObservationIgnored private var browser: ICDeviceBrowser?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var seen: Set<String> = []
    /// Files being waited on until they're written (each once, however many changes the folder reports).
    @ObservationIgnored private var pending: Set<String> = []

    // MARK: - Starting

    /// Looks for cameras (asking macOS for leave to control them, the first time).
    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        self.browser = browser
        // (On the Mac, macOS asks for camera access itself the first time a camera is opened.)
        browser.start()
    }

    func stop() {
        camera?.requestDisableTethering()
        camera?.requestCloseSession()
        browser?.stop()
        browser = nil
        watcher?.cancel(); watcher = nil
        camera = nil; cameras = []; ready = false; canFire = false; watched = nil
        // A new session gets its own folder and album (a watched folder is never where a camera's photos go).
        folder = nil; album = nil
    }

    /// The session's folder and album (made the first time a photo comes in).
    private func destination() -> URL? {
        if let folder { return folder }
        let day = Date.now.formatted(.iso8601.year().month().day())
        let made = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck Tethered", isDirectory: true).appendingPathComponent(day, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)) != nil else { return nil }
        folder = made
        return made
    }

    /// A new photo on this Mac: into the album, and shown.
    private func arrived(_ url: URL) {
        let path = url.path
        guard seen.insert(path).inserted, PhotoCatalog.isPhoto(url) else { return }
        let catalog = PhotoCatalog.shared
        if let album, catalog.albums.contains(where: { $0.id == album }) {
            catalog.add([path], to: album)
        } else {
            album = catalog.newAlbum(named: String(localized: "Tethered \(Date.now.formatted(date: .abbreviated, time: .shortened))"), with: [path]).id
        }
        shot += 1
        latest = path
    }

    // MARK: - A camera

    func use(_ device: ICCameraDevice) {
        camera?.requestCloseSession()
        camera = device
        ready = false
        canFire = false
        note = nil
        device.delegate = self
        device.requestOpenSession()
    }

    /// Fires the camera (its photo then arrives by itself).
    func fire() {
        guard let camera, canFire else { return }
        camera.requestTakePicture()
    }

    // MARK: - A folder (the maker's remote app)

    func watch(_ url: URL) {
        stop()
        watched = url
        folder = url
        seen = Set(((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { url.appendingPathComponent($0).path })
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { note = String(localized: "That folder can’t be watched."); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        ready = true
    }

    /// New files in the watched folder, once they've finished being written (their size steady for a moment).
    private func scan() {
        guard let watched else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: watched, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { !seen.contains($0.path) && PhotoCatalog.isPhoto($0) }
        for file in files where pending.insert(file.path).inserted {
            Task {
                defer { pending.remove(file.path) }
                var size = -1
                while true {
                    // (Fresh each time: URL caches what it was asked.)
                    let now = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
                    guard let now, watched != nil else { return }
                    if now == size, now > 0 { break }
                    size = now
                    try? await Task.sleep(for: .milliseconds(600))
                }
                arrived(file)
            }
        }
    }
}

// MARK: - Image Capture's callbacks

extension PhotoTether: ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in
            cameras.append(camera)
            if self.camera == nil { use(camera) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            cameras.removeAll { $0 === device }
            if camera === device { camera = nil; ready = false; canFire = false; note = String(localized: "The camera was disconnected.") }
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error { note = error.localizedDescription; return }
            ready = true
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            // Shooting from the Mac, when the camera allows it.
            canFire = device.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue)
            if canFire { device.requestEnableTethering() } else {
                note = String(localized: "This camera can’t be fired from a Mac. Use its maker’s remote app and watch the folder it saves to.")
            }
            // What's already on the card isn't brought in: only what's shot from now on.
            for item in device.mediaFiles ?? [] { seen.insert(item.name ?? "") }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            guard ready, let folder = destination() else { return }
            for case let file as ICCameraFile in items where !seen.contains(file.name ?? "") {
                seen.insert(file.name ?? "")
                camera.requestDownloadFile(file, options: [.downloadsDirectoryURL: folder], downloadDelegate: self,
                                           didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
            }
        }
    }

    @objc nonisolated func didDownloadFile(_ file: ICCameraFile, error: (any Error)?, options: [String: Any] = [:], contextInfo: UnsafeMutableRawPointer?) {
        let folder = options[ICDownloadOption.downloadsDirectoryURL.rawValue] as? URL
        let name = options[ICDownloadOption.savedFilename.rawValue] as? String ?? file.name
        Task { @MainActor in
            if let error { note = error.localizedDescription; return }
            if let folder, let name { arrived(folder.appendingPathComponent(name)) }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in canFire = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        Task { @MainActor in note = error?.localizedDescription }
    }
}

// MARK: - The sheet

/// Tethered shooting: the camera (or the watched folder), Shoot (Space), how many came in; the newest shows behind it.
struct PhotoTetherSheet: View {
    let show: (String) -> Void
    let close: () -> Void
    @State private var tether = PhotoTether.shared
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tethered Shooting").font(Design.Studio.sectionTitle)
            if let watched = tether.watched {
                Label("Watching \(watched.lastPathComponent)", systemImage: "folder").font(Design.Studio.body)
                Text("Shoot with the camera maker’s remote app: each photo it saves here comes into Pluck.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            } else if let camera = tether.camera {
                Label(camera.name ?? String(localized: "Camera"), systemImage: "camera").font(Design.Studio.body)
                Button { tether.fire() } label: { Label("Shoot", systemImage: "camera.shutter.button") }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!tether.canFire)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connect a camera with its cable and switch it on.").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            if tether.shot > 0 {
                Text("^[\(tether.shot) photo](inflect: true) this session").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            if let note = tether.note { Text(note).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Watch a Folder…") { choosingFolder = true }.buttonStyle(StudioFlatButtonStyle())
                    .help("For cameras macOS can't fire: the folder their maker's remote app saves to")
                Spacer()
                Button("Done") { tether.stop(); close() }.buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Design.Studio.panel)
        .onAppear { tether.start() }
        .onChange(of: tether.latest) { _, path in if let path { show(path) } }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { tether.watch(url) }
        }
    }
}
