import AVFoundation
import Foundation

internal final class SvgaSoundLibrary {

    private var players: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "svga.sound.library")

    func load(key: String, url: URL) throws {
        try queue.sync {
            if players[key] != nil { return }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[key] = player
        }
    }

    func play(key: String, volume: Float) {
        queue.async { [weak self] in
            guard let player = self?.players[key] else { return }
            player.volume = max(0, min(1, volume))
            player.currentTime = 0
            player.play()
        }
    }

    func stop(key: String) {
        queue.async { [weak self] in
            self?.players[key]?.stop()
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            self?.players.values.forEach { $0.stop() }
        }
    }

    func unload(key: String) {
        queue.async { [weak self] in
            self?.players.removeValue(forKey: key)?.stop()
        }
    }

    func release() {
        queue.sync {
            players.values.forEach { $0.stop() }
            players.removeAll()
        }
    }
}
