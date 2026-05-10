import AVFoundation
import Foundation

internal final class SvgaSoundLibrary {

    private final class Track {
        let player: AVAudioPlayer
        let sourcePath: String
        init(player: AVAudioPlayer, sourcePath: String) {
            self.player = player
            self.sourcePath = sourcePath
        }
    }

    private var tracks: [String: Track] = [:]
    private let queue = DispatchQueue(label: "svga.sound.library")

    func load(key: String, url: URL) throws {
        let newPath = url.path
        try queue.sync {
            if let existing = tracks[key], existing.sourcePath == newPath { return }
            if let existing = tracks[key] {
                existing.player.stop()
                tracks.removeValue(forKey: key)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            tracks[key] = Track(player: player, sourcePath: newPath)
        }
    }

    func play(key: String, volume: Float) {
        queue.async { [weak self] in
            guard let player = self?.tracks[key]?.player else { return }
            player.volume = max(0, min(1, volume))
            player.currentTime = 0
            player.play()
        }
    }

    func stop(key: String) {
        queue.async { [weak self] in
            self?.tracks[key]?.player.stop()
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            self?.tracks.values.forEach { $0.player.stop() }
        }
    }

    func unload(key: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let track = self.tracks.removeValue(forKey: key) else { return }
            track.player.stop()
        }
    }

    func release() {
        // Async so we can't block the calling thread (typically main during
        // unmount, where a `.sync` here would block on any in-flight
        // `play`/`stop` already serialised on `queue`). Order is preserved
        // because `queue` is serial — release fires after every previously
        // enqueued operation.
        queue.async { [weak self] in
            guard let self = self else { return }
            self.tracks.values.forEach { $0.player.stop() }
            self.tracks.removeAll()
        }
    }
}
