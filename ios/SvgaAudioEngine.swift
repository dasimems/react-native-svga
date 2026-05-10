import AVFoundation
import Foundation

/// Plays the audio tracks bundled inside an `.svga` file, frame-synced to the
/// frame loop in `SvgaPlayerView`.
///
/// Threading: every public method is expected to be called from the main
/// thread. The interruption observer is also delivered to main. The only
/// exception is `AVAudioPlayer.isPlaying`/`stop`, which Apple documents as
/// thread-safe read accesses.
internal final class SvgaAudioEngine {

    typealias AudioErrorHandler = (String) -> Void

    private final class Track {
        let player: AVAudioPlayer
        let startFrame: Int
        let endFrame: Int
        /// True iff this track was playing when the system audio session was
        /// interrupted (e.g. phone call). Cleared when the track is told to
        /// stop (either by `endFrame` or `stopAll`) so the post-interruption
        /// resume doesn't restart audio whose playback range has already
        /// passed.
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
        removeInterruptionObserver()
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
            if frame == track.endFrame {
                track.player.stop()
                // Track is past its end; if an interruption is active and
                // ends later, we should NOT auto-resume this track.
                track.wasPlayingBeforeInterrupt = false
            }
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
            track.wasPlayingBeforeInterrupt = false
        }
    }

    func release() {
        stopAll()
        unload()
        // Remove the NotificationCenter observer eagerly; otherwise it
        // accumulates across rapid mount/unmount cycles when HybridSvga
        // disposes its engine before ARC actually deallocates it.
        removeInterruptionObserver()
    }

    private func removeInterruptionObserver() {
        guard let observer = interruptionObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        interruptionObserver = nil
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
            // Always clear the flags, even if we don't resume (so a future
            // interruption snapshot is fresh).
            defer {
                for track in tracks { track.wasPlayingBeforeInterrupt = false }
            }
            if !options.contains(.shouldResume) { return }
            if muted { return }
            for track in tracks {
                // Only resume if (a) the track was playing pre-interruption
                // and (b) it still has unplayed audio (so the frame-loop's
                // endFrame stop didn't already retire it).
                if track.wasPlayingBeforeInterrupt && track.player.currentTime > 0 {
                    track.player.play()
                }
            }
        @unknown default:
            return
        }
    }
}
