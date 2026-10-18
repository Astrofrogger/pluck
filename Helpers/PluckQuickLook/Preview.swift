import AppKit
import QuickLookUI
import os

private let trace = Logger(subsystem: "be.wideopen.pluck.quicklook", category: "preview")

/// Finder's preview of a RED or Blackmagic RAW clip: a sharp picture a second in, with a line on
/// what it is. In the Quick Look window (the space bar) it then plays, looping; in Finder's own
/// preview pane (columns, gallery) it stays a still, like a thumbnail. Click to pause.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let screen = NSView()
    private let caption = NSTextField(labelWithString: "")
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
        root.addSubview(screen)
        root.addSubview(caption)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor), screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.topAnchor.constraint(equalTo: root.topAnchor), screen.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        root.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePause)))
        view = root
    }

    @objc private func togglePause() { state.paused.toggle() }

    func preparePreviewOfFile(at url: URL) async throws {
        let file = RawClip.clipFile(url)
        let clip = try await Task.detached { try RawClip(url: file) }.value
        self.clip = clip
        preferredContentSize = CGSize(width: 960, height: 960 * Double(clip.height) / Double(max(clip.width, 1)))
        // The picture straight away: a frame a second in, at about the window's size.
        poster = min(Int(clip.fps), max(clip.frames - 1, 0))
        let frame = poster
        let still = try await Task.detached { try clip.frame(frame, scale: clip.scale(forWidth: 1400)) }.value
        show(still, frame: poster)
        updatePlaying()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePlaying()
    }

    /// Plays in the Quick Look window, stays still in Finder's preview pane.
    private func updatePlaying() {
        guard let clip, clip.frames > 1 else { return }
        let large = view.bounds.width >= Self.playingWidth
        if large, playing == nil {
            play(clip, from: poster)
        } else if !large, let task = playing {
            task.cancel()
            playing = nil
        }
    }

    private func play(_ clip: RawClip, from start: Int) {
        // As sharp as the window, as long as the decoder keeps up: on the graphics chip up to
        // full HD, on the processor about 700 wide.
        let pixels = view.bounds.width * (view.window?.backingScaleFactor ?? 2)
        let scale = clip.gpu ? clip.scale(forWidth: min(pixels, 1920)) : clip.scale(forWidth: 700)
        let state = state
        trace.log("playing \(clip.width / scale)×\(clip.height / scale) at \(clip.fps) fps, gpu \(clip.gpu)")
        // Decoding runs on its own while the picture before it is on screen.
        playing = Task.detached(priority: .userInitiated) { [weak self] in
            var clock = Date.now, base = start, shown = start
            var count = 0, since = Date.now
            while !Task.isCancelled {
                if state.paused {
                    try? await Task.sleep(for: .milliseconds(100))
                    clock = .now; base = shown
                    continue
                }
                // The frame due now (frames the decoder fell behind on are skipped).
                var due = base + Int(Date.now.timeIntervalSince(clock) * clip.fps)
                if due <= shown && shown != start { due = shown + 1 }
                if due >= clip.frames { clock = .now; base = 0; due = 0 }
                guard let image = try? clip.frame(due, scale: scale, eightBit: true), !Task.isCancelled else { continue }
                // Not before its time.
                let wait = clock.addingTimeInterval(Double(due - base) / clip.fps).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
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

    private func show(_ image: CGImage, frame: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.layer?.contents = image
        CATransaction.commit()
        if let clip { update(frame, of: clip) }
    }

    private func update(_ frame: Int, of clip: RawClip) {
        let rate = Int(clip.fps.rounded()), seconds = frame / max(rate, 1)
        let time = String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % max(rate, 1))
        let name = clip.format == "r3d" ? "REDCODE RAW" : clip.format == "braw" ? "Blackmagic RAW" : clip.format.uppercased()
        caption.stringValue = " \(time)  ·  \(clip.camera.map { "\($0)  ·  " } ?? "")\(name)  ·  \(clip.width)×\(clip.height)  ·  \(rate) fps "
    }

    deinit {
        playing?.cancel()
        clip?.close()
    }
}

/// Paused or not, read by the playing loop off the main thread.
private final class PlayState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var paused: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
