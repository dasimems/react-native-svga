import AVFoundation
import Foundation

internal final class SvgaAudioEngine {

    typealias AudioErrorHandler = (String) -> Void

    private final class Track {
        let player: AVAudioPlayer
        let startFrame: Int
        let endFrame: Int
        var wasPlayingBeforeInterrupt: Bool = false
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
    private var interruptionObserver: NSObjectProtocol?
    var onAudioError: AudioErrorHandler?

    init() {
        registerInterruptionObserver()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        if !value { return }
        for track in tracks {
            if track.player.isPlaying { track.player.pause() }
        }
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
                onAudioError?("audio load failed for \(audio.audioKey): \(error.localizedDescription)")
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
        for track in tracks {
            if track.player.isPlaying { track.player.pause() }
        }
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

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            for track in tracks {
                track.wasPlayingBeforeInterrupt = track.player.isPlaying
                if track.player.isPlaying { track.player.pause() }
            }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if !options.contains(.shouldResume) { return }
            if muted { return }
            for track in tracks {
                if track.wasPlayingBeforeInterrupt {
                    track.player.play()
                }
                track.wasPlayingBeforeInterrupt = false
            }
        @unknown default:
            return
        }
    }
}
