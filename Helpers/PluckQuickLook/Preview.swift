import AppKit
import QuickLookUI

/// Finder's preview (the space bar) of a RED or Blackmagic RAW clip: a sharp first picture, then it
/// plays, looping, at a size that keeps up, with a line on what it is. Click to pause.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let picture = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var clips: [RawClip] = []
    private var playing: Task<Void, Never>?
    private var paused = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        // Fitted in the window, never sizing it to the picture's pixels.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            picture.setContentCompressionResistancePriority(.fittingSizeCompression, for: orientation)
            picture.setContentHuggingPriority(.defaultLow, for: orientation)
        }
        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        caption.drawsBackground = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(picture)
        root.addSubview(caption)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor), picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            picture.topAnchor.constraint(equalTo: root.topAnchor), picture.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        root.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePause)))
        view = root
    }

    @objc private func togglePause() { paused.toggle() }

    func preparePreviewOfFile(at url: URL) async throws {
        let file = RawClip.clipFile(url)
        let first = try await Task.detached { try RawClip(url: file) }.value
        clips = [first]
        preferredContentSize = CGSize(width: 960, height: 960 * Double(first.height) / Double(max(first.width, 1)))
        // The picture straight away: a frame a second in, at about the window's size.
        let poster = min(Int(first.fps), max(first.frames - 1, 0))
        let still = try await Task.detached { try first.frame(poster, scale: first.scale(forWidth: 1400)) }.value
        picture.image = NSImage(cgImage: still, size: .zero)
        update(poster, of: first)
        guard first.frames > 1 else { return }
        play(from: poster)
    }

    private func play(from start: Int) {
        let pool = clips
        guard let clip = pool.first else { return }
        // Small enough to keep up on one decoder (Pluck's Raw Player uses several).
        let scale = clip.scale(forWidth: 700)
        playing = Task { @MainActor [weak self] in
            var clock = Date.now, base = start
            var inFlight: [Int: Task<CGImage?, Never>] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                if self.paused {
                    try? await Task.sleep(for: .milliseconds(100))
                    clock = .now
                    continue
                }
                var due = base + Int(Date.now.timeIntervalSince(clock) * clip.fps)
                if due >= clip.frames { clock = .now; base = 0; due = 0; inFlight = [:] }
                for frame in due..<min(due + pool.count, clip.frames) where inFlight[frame] == nil {
                    let decoder = pool[frame % pool.count]
                    inFlight[frame] = Task.detached(priority: .userInitiated) { try? decoder.frame(frame, scale: scale) }
                }
                for late in inFlight.keys where late < due { inFlight[late] = nil }
                if let image = await inFlight[due]?.value {
                    self.picture.image = NSImage(cgImage: image, size: .zero)
                    self.update(due, of: clip)
                }
                inFlight[due] = nil
                let wait = clock.addingTimeInterval(Double(due - base + 1) / clip.fps).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
    }

    private func update(_ frame: Int, of clip: RawClip) {
        let rate = Int(clip.fps.rounded()), seconds = frame / max(rate, 1)
        let time = String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % max(rate, 1))
        let name = clip.format == "r3d" ? "REDCODE RAW" : clip.format == "braw" ? "Blackmagic RAW" : clip.format.uppercased()
        caption.stringValue = " \(time)  ·  \(clip.camera.map { "\($0)  ·  " } ?? "")\(name)  ·  \(clip.width)×\(clip.height)  ·  \(rate) fps "
    }

    deinit {
        playing?.cancel()
        for clip in clips { clip.close() }
    }
}
