import AVFoundation
import AppKit
import QuickLookUI
import os

private let trace = Logger(subsystem: "be.wideopen.pluck.quicklook", category: "preview")

/// Finder's preview of a RED or Blackmagic RAW clip: a sharp picture a second in, with a line on
/// what it is and a bar to scrub through it. In the Quick Look window (the space bar) it then
/// plays, looping; in Finder's own preview pane (columns, gallery) it stays a still, like a
/// thumbnail, until it's scrubbed. Click the picture to pause.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let screen = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var clip: RawClip?
    private var poster = 0
    private var playing: Task<Void, Never>?
    private let state = PlayState()

    /// Narrower than this, it's Finder's preview pane rather than the Quick Look window.
    private static let playingWidth: CGFloat = 520

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        screen.wantsLayer = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        caption.drawsBackground = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        scrubber.isContinuous = true
        scrubber.controlSize = .small
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.toolTip = String(localized: "Drag to go through the clip")
        root.addSubview(screen)
        root.addSubview(caption)
        root.addSubview(scrubber)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor), screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.topAnchor.constraint(equalTo: root.topAnchor), screen.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrubber.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrubber.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrubber.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            caption.bottomAnchor.constraint(equalTo: scrubber.topAnchor, constant: -6),
        ])
        // On the picture only (a click on the bar is scrubbing).
        screen.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePause)))
        view = root
    }

    @objc private func togglePause() { state.paused.toggle() }

    /// The bar dragged: that frame, shown as soon as it's decoded (the latest asked for first);
    /// playing carries on from there when it's let go.
    @objc private func scrubbed() {
        guard let clip, clip.frames > 1 else { return }
        let frame = Int((scrubber.doubleValue * Double(clip.frames - 1)).rounded())
        let event = NSApp.currentEvent?.type
        state.scrubbing = event == .leftMouseDown || event == .leftMouseDragged
        state.request(frame)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let file = RawClip.clipFile(url)
        let clip = try await Task.detached { try RawClip(url: file) }.value
        self.clip = clip
        preferredContentSize = CGSize(width: 960, height: 960 * Double(clip.height) / Double(max(clip.width, 1)))
        // The picture straight away: a frame a second in (or where the file chosen starts, for a
        // take in several files), at about the window's size.
        poster = min(Int(clip.fps), max(clip.frames - 1, 0))
        if let start = RawClip.spanned(url)?.start { poster = min(Int(start * Double(clip.frames)), max(clip.frames - 1, 0)) }
        let frame = poster
        let still = try await Task.detached { try clip.frame(frame, scale: clip.scale(forWidth: 1400)) }.value
        show(still, frame: poster)
        guard clip.frames > 1 else { return }
        start(clip, from: poster)
        updatePlaying()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePlaying()
    }

    /// Plays in the Quick Look window, stays still in Finder's preview pane.
    private func updatePlaying() {
        state.autoplay = view.bounds.width >= Self.playingWidth
        let pixels = view.bounds.width * (view.window?.backingScaleFactor ?? 2)
        if pixels > 0 { state.width = pixels }
    }

    /// Shows frames: in turn while playing, and whichever is asked for while scrubbing.
    private func start(_ clip: RawClip, from start: Int) {
        let state = state
        trace.log("ready \(clip.width)×\(clip.height) at \(clip.fps) fps, gpu \(clip.gpu)")
        // As sharp as the window, as long as the decoder keeps up: on the graphics chip up to
        // full HD, on the processor about 700 wide (the window can change size).
        func scale() -> Int { clip.gpu ? clip.scale(forWidth: min(state.width, 1920)) : clip.scale(forWidth: min(state.width, 700)) }
        // The sound, found once the picture's there (it sets the pace while it plays).
        Task.detached(priority: .utility) {
            if let file = clip.audio() {
                state.sound = Sound(file)
                trace.log("sound \(file.lastPathComponent, privacy: .public), \(state.sound?.duration ?? 0) s")
            } else {
                trace.log("no sound")
            }
        }
        // Decoding runs on its own while the picture before it is on screen.
        playing = Task.detached(priority: .userInitiated) { [weak self] in
            var clock = Date.now, base = start, shown = start
            var count = 0, since = Date.now
            while !Task.isCancelled {
                // Scrubbed to a frame: that one now, and on from there.
                if let target = state.takeRequest() {
                    state.sound?.pause()
                    if let image = try? clip.frame(target, scale: scale(), eightBit: true), !Task.isCancelled {
                        await MainActor.run { self?.show(image, frame: target, scrubbing: true) }
                    }
                    shown = target; base = target; clock = .now
                    continue
                }
                if state.paused || state.scrubbing || !state.autoplay {
                    state.sound?.pause()
                    try? await Task.sleep(for: .milliseconds(15))
                    clock = .now; base = shown
                    continue
                }
                // (Past the end of the sound, the picture keeps its own time.)
                let sound = state.sound.flatMap { Double(shown + 1) / clip.fps < $0.duration - 0.02 ? $0 : nil }
                if sound == nil { state.sound?.pause() }
                // The frame due now (frames the decoder fell behind on are skipped): by the
                // sound's clock while it plays, so picture and sound stay together.
                var due: Int
                if let sound {
                    if !sound.playing { sound.play(from: Double(shown + 1) / clip.fps) }
                    due = Int(sound.time * clip.fps)
                    // Not there yet: the next frame's time.
                    if due <= shown {
                        try? await Task.sleep(for: .seconds(max(Double(shown + 1) / clip.fps - sound.time, 0.002)))
                        continue
                    }
                } else {
                    due = base + Int(Date.now.timeIntervalSince(clock) * clip.fps)
                    if due <= shown { due = shown + 1 }
                }
                if due >= clip.frames { clock = .now; base = 0; due = 0; sound?.play(from: 0) }
                guard let image = try? clip.frame(due, scale: scale(), eightBit: true), !Task.isCancelled else { continue }
                // Not before its time.
                if sound == nil {
                    let wait = clock.addingTimeInterval(Double(due - base) / clip.fps).timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                }
                shown = due
                await MainActor.run { self?.show(image, frame: due) }
                count += 1
                if count == 100 {
                    trace.log("shown \(Double(count) / Date.now.timeIntervalSince(since), format: .fixed(precision: 1)) fps")
                    count = 0; since = .now
                }
            }
        }
    }

    private func show(_ image: CGImage, frame: Int, scrubbing: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.layer?.contents = image
        CATransaction.commit()
        guard let clip else { return }
        update(frame, of: clip)
        // The bar follows the picture, unless it's the one being dragged.
        if !scrubbing, !state.scrubbing { scrubber.doubleValue = Double(frame) / Double(max(clip.frames - 1, 1)) }
    }

    private func update(_ frame: Int, of clip: RawClip) {
        let rate = Int(clip.fps.rounded()), seconds = frame / max(rate, 1)
        let time = String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % max(rate, 1))
        let name = clip.format == "r3d" ? "REDCODE RAW" : clip.format == "braw" ? "Blackmagic RAW" : clip.format.uppercased()
        caption.stringValue = " \(time)  ·  \(clip.camera.map { "\($0)  ·  " } ?? "")\(name)  ·  \(clip.width)×\(clip.height)  ·  \(rate) fps "
    }

    deinit {
        playing?.cancel()
        state.sound?.stop()
        clip?.close()
    }
}

/// The clip's sound, played in step with the picture (the loop reads its clock).
private final class Sound: @unchecked Sendable {
    private let player: AVAudioPlayer
    private let file: URL
    private let lock = NSLock()

    init?(_ file: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return nil }
        player.prepareToPlay()
        self.player = player
        self.file = file
        duration = player.duration
    }

    var playing: Bool { lock.withLock { player.isPlaying } }
    let duration: Double
    var time: Double { lock.withLock { player.currentTime } }

    func play(from seconds: Double) {
        lock.withLock {
            player.currentTime = max(min(seconds, player.duration), 0)
            player.play()
        }
    }

    func pause() { lock.withLock { if player.isPlaying { player.pause() } } }

    func stop() {
        lock.withLock { player.stop() }
        // A copy made from the clip goes (not the camera's own .wav).
        if file.lastPathComponent.hasPrefix("pluck-ql-") { try? FileManager.default.removeItem(at: file) }
    }
}

/// What the frame loop is told from the window: paused, playing at all, a frame scrubbed to.
private final class PlayState: @unchecked Sendable {
    private let lock = NSLock()
    private var _sound: Sound?
    /// The clip's sound, once it's ready.
    var sound: Sound? {
        get { lock.withLock { _sound } }
        set { lock.withLock { _sound = newValue } }
    }
    private var _paused = false, _autoplay = false, _scrubbing = false, _width: CGFloat = 1400
    private var requested: Int?

    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    /// In the Quick Look window (not Finder's small preview pane).
    var autoplay: Bool {
        get { lock.withLock { _autoplay } }
        set { lock.withLock { _autoplay = newValue } }
    }
    /// The window's width in pixels (what the frames are decoded for).
    var width: CGFloat {
        get { lock.withLock { _width } }
        set { lock.withLock { _width = newValue } }
    }
    /// The bar held down.
    var scrubbing: Bool {
        get { lock.withLock { _scrubbing } }
        set { lock.withLock { _scrubbing = newValue } }
    }

    /// A frame to show (a newer one replaces one not shown yet).
    func request(_ frame: Int) { lock.withLock { requested = frame } }
    func takeRequest() -> Int? { lock.withLock { defer { requested = nil }; return requested } }
}
