import AVFoundation
import Foundation

internal final class SvgaAudioEngine {

    private final class Track {
        let player: AVAudioPlayer
        let startFrame: Int
        let endFrame: Int
        init(player: AVAudioPlayer, startFrame: Int, endFrame: Int) {
            self.player = player
            self.startFrame = startFrame
            self.endFrame = endFrame
        }
    }

    private var tracks: [Track] = []
    private var muted = false
    private var volume: Float = 1
    private var rate: Float = 1

    func setMuted(_ value: Bool) {
        muted = value
        if !value { return }
        for track in tracks { track.player.stop() }
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        for track in tracks { track.player.volume = volume }
    }

    func setRate(_ value: Float) {
        rate = max(0.5, min(2, value))
        for track in tracks {
            track.player.enableRate = true
            track.player.rate = rate
        }
    }

    func load(_ entity: SvgaEntity) {
        unload()
        if entity.movie.audios.isEmpty { return }
        for audio in entity.movie.audios {
            guard let bytes = entity.audioData[audio.audioKey] else { continue }
            do {
                let player = try AVAudioPlayer(data: bytes)
                player.prepareToPlay()
                player.volume = volume
                player.enableRate = true
                player.rate = rate
                tracks.append(Track(
                    player: player,
                    startFrame: audio.startFrame,
                    endFrame: audio.endFrame
                ))
            } catch {
                continue
            }
        }
    }

    func onFrame(_ frame: Int) {
        if muted { return }
        for track in tracks {
            if frame == track.startFrame { track.player.play() }
            if frame == track.endFrame { track.player.stop() }
        }
    }

    func pauseAll() {
        for track in tracks { track.player.pause() }
    }

    func resumeAll() {
        if muted { return }
        for track in tracks {
            if track.player.currentTime > 0 && !track.player.isPlaying { track.player.play() }
        }
    }

    func stopAll() {
        for track in tracks {
            track.player.stop()
            track.player.currentTime = 0
        }
    }

    func release() {
        stopAll()
        unload()
    }

    private func unload() {
        for track in tracks {
            track.player.stop()
        }
        tracks.removeAll()
    }
}
