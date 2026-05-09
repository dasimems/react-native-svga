import AVFoundation
import Foundation

internal final class SvgaSoundLibrary {

    private final class Track {
        let player: AVAudioPlayer
        var refCount: Int
        init(_ player: AVAudioPlayer) {
            self.player = player
            self.refCount = 1
        }
    }

    private var tracks: [String: Track] = [:]
    private let queue = DispatchQueue(label: "svga.sound.library")

    func load(key: String, url: URL) throws {
        try queue.sync {
            if let existing = tracks[key] {
                existing.refCount += 1
                return
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            tracks[key] = Track(player)
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
            guard let track = self.tracks[key] else { return }
            track.refCount -= 1
            if track.refCount > 0 { return }
            track.player.stop()
            self.tracks.removeValue(forKey: key)
        }
    }

    func release() {
        queue.sync {
            tracks.values.forEach { $0.player.stop() }
            tracks.removeAll()
        }
    }
}
