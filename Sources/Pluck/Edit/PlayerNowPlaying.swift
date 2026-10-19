import AppKit
import MediaPlayer

/// The Player in macOS's Now Playing (Control Center, the menu bar's widget) and on the
/// keyboard's play, next and previous keys, while its page is open.
@MainActor
final class PlayerNowPlaying {
    private let player: RawPlayer
    private var targets: [(MPRemoteCommand, Any)] = []
    /// The clip before and after in the folder being browsed.
    var neighbour: ((Int) -> Void)?

    init(player: RawPlayer) {
        self.player = player
    }

    func start() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Bool) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) ? .success : .commandFailed }
            }
            targets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in self?.player.play(); return self?.player.info != nil }
        on(center.pauseCommand) { [weak self] _ in self?.player.stop(); return true }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.player.togglePlay(); return self?.player.info != nil }
        on(center.nextTrackCommand) { [weak self] _ in
            guard let neighbour = self?.neighbour else { return false }
            neighbour(1); return true
        }
        on(center.previousTrackCommand) { [weak self] _ in
            guard let neighbour = self?.neighbour else { return false }
            neighbour(-1); return true
        }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
            player.show(Int(event.positionTime * player.fps))
            update()
            return true
        }
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// The clip and where it is (macOS moves the time on by itself while it plays).
    func update() {
        guard !targets.isEmpty else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let url = player.url, let info = player.info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: url.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyArtist: [info.camera, info.formatName].compactMap { $0 }.joined(separator: " · "),
            MPMediaItemPropertyPlaybackDuration: Double(info.frames) / player.fps,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(player.index) / player.fps,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        center.playbackState = player.isPlaying ? .playing : .paused
    }
}
