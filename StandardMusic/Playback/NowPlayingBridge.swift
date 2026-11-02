import AppKit
import MediaPlayer
import StandardKit

/// Publishes to Control Center / the Now Playing widget and handles media keys.
@MainActor
final class NowPlayingBridge {
    private var artworkCache: (URL, MPMediaItemArtwork)?

    func install(player: PlayerModel) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak player] _ in
            MainActor.assumeIsolated { player?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            MainActor.assumeIsolated { player?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            MainActor.assumeIsolated { player?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            MainActor.assumeIsolated { player?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            MainActor.assumeIsolated { player?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { player?.seek(to: event.positionTime) }
            return .success
        }
    }

    func update(info: TrackInfo?, state: PlayerModel.State, time: Double, duration: Double, artwork: URL?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.track.title,
            MPMediaItemPropertyArtist: info.artist.name,
            MPMediaItemPropertyAlbumTitle: info.album.title,
            MPMediaItemPropertyAlbumTrackNumber: info.track.trackNumber,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPMediaItemPropertyGenre: info.album.primaryGenre,
        ]
        if let artwork {
            if artworkCache?.0 != artwork, let image = NSImage(contentsOf: artwork) {
                artworkCache = (artwork, Self.artwork(image))
            }
            if let cached = artworkCache, cached.0 == artwork { dict[MPMediaItemPropertyArtwork] = cached.1 }
        }
        center.nowPlayingInfo = dict
        center.playbackState = state == .playing ? .playing : .paused
    }
}

extension NowPlayingBridge {
    /// MediaPlayer calls the request handler on its own queue, so it must not inherit main-actor isolation.
    nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
