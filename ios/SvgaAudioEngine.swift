import AVFoundation
import Foundation

/// Plays the audio tracks bundled inside an `.svga` file, frame-synced to the
/// frame loop in `SvgaPlayerView`.
///
/// Threading: every public method is expected to be called from the main
/// thread. The interruption observer is also delivered to main. The only
/// exception is `AVAudioPlayer.isPlaying`/`stop`, which Apple documents as
/// thread-safe read accesses. Decoding (`AVAudioPlayer(data:)`) is offloaded
/// to a global utility queue because constructor initialisation and
/// `prepareToPlay` can stall main for tens of ms per track.
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
    /// Generation counter incremented on every `load` and `release`. Async
    /// decode tasks compare against this before installing decoded tracks
    /// to drop results that belong to a stale entity.
    private var generation: UInt64 = 0
    private static let decodeQueue = DispatchQueue(label: "svga.audio.decode", qos: .userInitiated, attributes: .concurrent)
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
        generation += 1
        let myGen = generation
        // Snapshot (key, audio) pairs the parser produced. Heavy work
        // (`AVAudioPlayer(data:)` + `prepareToPlay`) is per-track, so spread
        // it across a concurrent decode queue and hop back to main to install.
        let pending: [(AudioEntity, Data)] = entity.movie.audios.compactMap { audio in
            guard let bytes = entity.audioData[audio.audioKey] else { return nil }
            return (audio, bytes)
        }
        let snapshotVolume = volume
        let snapshotRate = rate
        for (audio, bytes) in pending {
            Self.decodeQueue.async { [weak self] in
                let player: AVAudioPlayer
                do {
                    player = try AVAudioPlayer(data: bytes)
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.onAudioError?("audio load failed for \(audio.audioKey): \(error.localizedDescription)")
                    }
                    return
                }
                player.prepareToPlay()
                player.volume = snapshotVolume
                player.enableRate = true
                player.rate = snapshotRate
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if myGen != self.generation { return }  // entity replaced; drop
                    self.tracks.append(Track(
                        player: player,
                        startFrame: audio.startFrame,
                        endFrame: audio.endFrame
                    ))
                }
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
        // Bumping the generation invalidates any in-flight decode tasks
        // that haven't installed yet, so they don't push tracks into a
        // released engine.
        generation += 1
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
            // The session is deactivated for the duration of the interruption
            // (phone call, Siri, etc.) and AVAudioPlayer.play() silently
            // returns false on a deactivated session. Re-activate before we
            // try to resume — surface the activation failure if the host app
            // has not configured an audio category that supports resumption.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                onAudioError?("audio session reactivation failed: \(error.localizedDescription)")
                return
            }
            for track in tracks {
                // Only resume if (a) the track was playing pre-interruption
                // and (b) it still has unplayed audio (so the frame-loop's
                // endFrame stop didn't already retire it).
                guard track.wasPlayingBeforeInterrupt && track.player.currentTime > 0 else { continue }
                if !track.player.play() {
                    onAudioError?("audio resume failed after interruption")
                }
            }
        @unknown default:
            return
        }
    }
}
