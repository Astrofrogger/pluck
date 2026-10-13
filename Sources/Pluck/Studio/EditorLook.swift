import AVFoundation
import CryptoKit
import SwiftUI

/// A look read while the picture plays (so a change shows at once).
final class LookBox: @unchecked Sendable {
    private var look: ClipLook?
    private let lock = NSLock()
    func set(_ new: ClipLook?) { lock.lock(); look = new; lock.unlock() }
    func get() -> ClipLook? { lock.lock(); defer { lock.unlock() }; return look }
}

/// The Editor's picture settings for a file on its own: the same as a clip's in a project.
extension EditorModel {
    private var lookFile: URL {
        let name = SHA256.hash(data: Data(file.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Editor Looks/\(name).json")
    }

    func loadLook() {
        guard let data = try? Data(contentsOf: lookFile), let saved = try? JSONDecoder().decode(ClipLook.self, from: data) else { return }
        look = saved
    }

    /// Changes the look: shown straight away; saved when `record` (a slider let go).
    func changeLook(record: Bool, _ body: (inout ClipLook) -> Void) {
        var new = look ?? ClipLook()
        body(&new)
        let wasSteadied = look?.stabilize == true
        look = new.isDefault ? nil : new
        lookBox.set(look)
        if record {
            if let look, let data = try? JSONEncoder().encode(look) {
                try? FileManager.default.createDirectory(at: lookFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: lookFile, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: lookFile)
            }
        }
        if (look?.stabilize == true) != wasSteadied || player.currentItem?.videoComposition == nil {
            Task { await applyLook() }
        } else {
            redrawLook()
        }
    }

    /// The player item with the look (and the steadied copy's picture when stabilized).
    func applyLook() async {
        guard hasVideo, let base = playedAsset else { return }
        lookBox.set(look)
        let keep = player.currentTime()
        var asset: AVAsset = base
        if look?.stabilize == true, let copy = Stabilizer.copy(for: file.path) {
            let composition = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: (try? await base.load(.duration)) ?? .zero)
            if let track = try? await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first,
               let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? video.insertTimeRange(range, of: track, at: .zero)
                video.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
            }
            if let track = try? await base.loadTracks(withMediaType: .audio).first,
               let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? audio.insertTimeRange(range, of: track, at: .zero)
            }
            asset = composition
        }
        let item = AVPlayerItem(asset: asset)
        if look != nil {
            let box = lookBox, size = pixelSize, length = max(duration, 0.001)
            if let composition = try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                request.finish(with: ClipLook.place(request.sourceImage, look: box.get(), progress: request.compositionTime.seconds / length, in: size),
                               context: nil)
            }) {
                composition.renderSize = size
                item.videoComposition = composition
            }
        }
        player.replaceCurrentItem(with: item)
        await player.seek(to: keep, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Draws the frame again with the new look (when paused, the player keeps the old one).
    func redrawLook() {
        guard let item = player.currentItem, let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = composition
    }
}
