import AVFoundation
import Foundation

/// Plays the audio tracks bundled inside an `.svga` file, frame-synced to the
/// frame loop in `SvgaPlayerView`.
///
/// Threading:
///  - `prepareTracks(_:)` is a static off-main pass: the host calls it on the
///    entity-load worker right after `loadEntity` returns, so by the time
///    `installTracks` runs on main the players are already prepared.
///  - Every other public method runs on main.
///  - The interruption observer is delivered to main.
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
        /// True iff this track was playing when `pauseAll()` ran (engine
        /// pause). `resumeAll()` restarts only tracks with this flag set,
        /// then clears it. Cleared in `onFrame`'s endFrame branch and in
        /// `stopAll()` so a track that has already played past its window
        /// doesn't restart on resume.
        var wasPlayingBeforePauseAll: Bool = false
        init(player: AVAudioPlayer, startFrame: Int, endFrame: Int) {
            self.player = player
            self.startFrame = startFrame
            self.endFrame = endFrame
        }
    }

    private var tracks: [Track] = []
    private var muted = false
    /// Engine-level paused state set by `pauseAll()` and cleared by
    /// `resumeAll()`/`installTracks()`/`stopAll()`. `setMuted(false)` consults
    /// this to decide whether to restart mute-paused tracks now or to defer
    /// the restart until the engine un-pauses (by promoting the mute-resume
    /// intent to `wasPlayingBeforePauseAll`).
    private var paused = false
    private var volume: Float = 1
    private var rate: Float = 1
    private var interruptionObserver: NSObjectProtocol?
    /// Tracks paused specifically by `setMuted(true)`, restarted on
    /// `setMuted(false)`. Without this, un-muting was a no-op for tracks
    /// that were mid-play when mute fired — they stayed silent until the
    /// next animation loop hit their startFrame. Identity-keyed because
    /// Track is a class.
    private var mutePausedTracks: Set<ObjectIdentifier> = []
    var onAudioError: AudioErrorHandler?

    init() {
        registerInterruptionObserver()
    }

    deinit {
        removeInterruptionObserver()
    }

    func setMuted(_ value: Bool) {
        if muted == value { return }
        muted = value
        if value {
            // Mute: pause anything mid-play and remember it so un-mute can
            // restart from the same offset.
            for track in tracks {
                if track.player.isPlaying {
                    track.player.pause()
                    mutePausedTracks.insert(ObjectIdentifier(track))
                }
            }
        } else {
            // Un-mute: restart everything we paused. If the engine is also
            // globally paused, transfer the mute-resume intent to the
            // pauseAll-resume intent so resumeAll() will pick the tracks up
            // later — without this transfer, the resume info would be silently
            // dropped (`pauseAll` couldn't have recorded it because the tracks
            // were already paused-by-mute when `pauseAll` ran).
            let toResume = mutePausedTracks
            mutePausedTracks.removeAll()
            if paused {
                for track in tracks where toResume.contains(ObjectIdentifier(track)) {
                    track.wasPlayingBeforePauseAll = true
                }
                return
            }
            for track in tracks {
                if !toResume.contains(ObjectIdentifier(track)) { continue }
                if !track.player.isPlaying { track.player.play() }
            }
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

    /// Decoded payload returned by `prepareTracks` and consumed by
    /// `installTracks`. `player` is `nil` when decode failed and `error`
    /// carries the deferred message that `installTracks` surfaces via
    /// `onAudioError` on main — we can't dispatch from the decode thread
    /// here because we don't know which engine instance will install us.
    struct PreparedTrack {
        let player: AVAudioPlayer?
        let startFrame: Int
        let endFrame: Int
        let error: String?
    }

    /// Pure (instance-free) decode pass. Call from a background thread/queue
    /// — typically the entity-load worker right after `loadEntity` returns,
    /// before the main-thread hop. The returned array preserves source order.
    static func prepareTracks(_ entity: SvgaEntity) -> [PreparedTrack] {
        return entity.movie.audios.compactMap { audio -> PreparedTrack? in
            guard let bytes = entity.audioData[audio.audioKey] else { return nil }
            do {
                let player = try AVAudioPlayer(data: bytes)
                player.prepareToPlay()
                return PreparedTrack(
                    player: player,
                    startFrame: audio.startFrame,
                    endFrame: audio.endFrame,
                    error: nil
                )
            } catch {
                return PreparedTrack(
                    player: nil,
                    startFrame: audio.startFrame,
                    endFrame: audio.endFrame,
                    error: "audio load failed for \(audio.audioKey): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Main-thread install. Replaces any current tracks atomically with
    /// the pre-decoded set from `prepareTracks`. Adopts the engine's live
    /// `volume`/`rate` at install time (a setter issued mid-decode lands on
    /// already-installed tracks but won't have touched these new ones, so we
    /// apply current values here).
    func installTracks(_ prepared: [PreparedTrack]) {
        unload()
        // A fresh install starts unpaused — the prior load's pauseAll state
        // doesn't carry over (matches Android symmetry). Mute persists
        // across loads because it's a user preference, not a transient.
        paused = false
        for p in prepared {
            if let message = p.error {
                onAudioError?(message)
                continue
            }
            guard let player = p.player else { continue }
            player.volume = volume
            player.enableRate = true
            player.rate = rate
            let track = Track(
                player: player,
                startFrame: p.startFrame,
                endFrame: p.endFrame
            )
            tracks.append(track)
        }
    }

    /// Convenience for sites that don't have a separate decode hop available.
    /// Decodes synchronously and installs in one call. Prefer the
    /// `prepareTracks` + `installTracks` pair when called on main, since
    /// decoding can take tens of ms per track and would block the UI.
    func load(_ entity: SvgaEntity) {
        installTracks(Self.prepareTracks(entity))
    }

    /// Public counterpart to `unload()` — used by the host (`HybridSvga`)
    /// when source is set to empty so the prior SVGA's AVAudioPlayers don't
    /// linger in memory until the next non-empty load. Distinct from
    /// `release()` because we want to keep the interruption observer alive
    /// across the empty interval.
    func unloadAll() {
        unload()
    }

    func onFrame(_ frame: Int) {
        if muted || paused { return }
        for track in tracks {
            if frame == track.startFrame { track.player.play() }
            if frame == track.endFrame {
                track.player.stop()
                // Track is past its end; if an interruption is active and
                // ends later, we should NOT auto-resume this track. Likewise
                // drop any "resume on un-mute" or "resume on un-pause" intent.
                track.wasPlayingBeforeInterrupt = false
                track.wasPlayingBeforePauseAll = false
                mutePausedTracks.remove(ObjectIdentifier(track))
            }
        }
    }

    func pauseAll() {
        paused = true
        for track in tracks {
            // Capture intent BEFORE pausing so resumeAll knows which tracks
            // to restart. Anything that wasn't playing (already past
            // endFrame, or hadn't started yet) stays out of the resume set.
            // Tracks paused-by-mute have isPlaying == false here too — the
            // mute->pauseAll->unmute transfer in setMuted(false) handles
            // promoting their resume intent.
            if track.player.isPlaying {
                track.wasPlayingBeforePauseAll = true
                track.player.pause()
            }
        }
    }

    func resumeAll() {
        paused = false
        if muted {
            // Engine is also muted — defer resume to the eventual
            // setMuted(false) by promoting each track's pauseAll-resume
            // intent into the mute-resume set. Without this transfer, the
            // inverse-order scenario `pauseAll → mute → resumeAll → unmute`
            // would silently drop the resume info: setMuted(true) couldn't
            // have recorded these tracks because they were already paused
            // by pauseAll when it ran, and resumeAll bails here on muted.
            for track in tracks {
                if !track.wasPlayingBeforePauseAll { continue }
                track.wasPlayingBeforePauseAll = false
                mutePausedTracks.insert(ObjectIdentifier(track))
            }
            return
        }
        for track in tracks {
            if !track.wasPlayingBeforePauseAll { continue }
            track.wasPlayingBeforePauseAll = false
            if !track.player.isPlaying { track.player.play() }
        }
    }

    func stopAll() {
        // Mark engine paused so a stale onFrame between stopAll and the
        // next play()/resumeAll() doesn't trigger startTrack. resumeAll
        // (called from `play()`) un-pauses; load() also resets this.
        paused = true
        for track in tracks {
            track.player.stop()
            track.player.currentTime = 0
            track.wasPlayingBeforeInterrupt = false
            track.wasPlayingBeforePauseAll = false
        }
        mutePausedTracks.removeAll()
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
        // All Track identities we tracked are now invalid.
        mutePausedTracks.removeAll()
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
            // Decide who actually wants to resume BEFORE touching the shared
            // audio session. If nobody is resumable, don't re-activate —
            // forcing setActive(true) when the host app uses an Ambient
            // category would override host policy unnecessarily.
            let resumable = tracks.filter {
                $0.wasPlayingBeforeInterrupt && $0.player.currentTime > 0
            }
            if resumable.isEmpty { return }
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
            for track in resumable {
                if !track.player.play() {
                    onAudioError?("audio resume failed after interruption")
                }
            }
        @unknown default:
            return
        }
    }
}
