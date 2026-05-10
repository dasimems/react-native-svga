package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * Plays the audio tracks bundled inside an `.svga` file, frame-synced to the
 * frame loop in `SvgaPlayerView`.
 *
 * Threading contract:
 *  - `prepareTracks(entity)` is called off the main thread (the entity-load
 *    coroutine in `HybridSvga`). It does the synchronous `MediaPlayer.prepare()`
 *    so that by the time tracks are installed, they're ready to play.
 *  - `installTracks` and every other public method run on the main thread.
 *  - `MediaPlayer.OnErrorListener` callbacks fire on the media thread.
 *    Track state mutated from there is `@Volatile`. All `tracks`-list access
 *    is wrapped in `synchronized(tracksLock)` because `unload()` may run on
 *    any caller thread (e.g. `release()` from `dispose()` on JS thread).
 *  - The audio-error listener is dispatched to main via `mainHandler.post`
 *    so consumers always receive errors on a known thread.
 *
 * State machine (read by `onFrame`):
 *  - `muted == true`  → `onFrame` is a no-op (caller decided audio is off).
 *  - `paused == true` → `onFrame` is a no-op. Set by `pauseAll`/`stopAll`,
 *    cleared by `resumeAll`/`installTracks`.
 *  - Both clear → `onFrame` triggers `startTrack` at `startFrame` and
 *    `stopTrack` at `endFrame`.
 */
internal class SvgaAudioEngine(private val context: Context) {

  internal class Track(
    val player: MediaPlayer,
    val startFrame: Int,
    val endFrame: Int,
    val tempFile: File?,
    val source: BytesMediaDataSource?,
  ) {
    /// Set true by `prepareOne` after `prepare()` succeeds. Public APIs that
    /// touch the player gate on this — even though we now prepare
    /// synchronously, `OnErrorListener` may flip it back to `false` if the
    /// platform decoder fails after install.
    @Volatile var prepared: Boolean = false
    /// Set by `unload()` before `player.release()`. Every code path that
    /// touches `player` must check this first — `MediaPlayer.setVolume` /
    /// `start` / `seekTo` on a released player throws IllegalStateException
    /// (and on some OEMs raises a fatal native abort).
    @Volatile var released: Boolean = false
    /// Captured by `pauseAll()` from the live `isPlaying` state. `resumeAll()`
    /// only restarts tracks where this flag is true, then clears it. This
    /// is what distinguishes "was actively playing when we paused" from
    /// "was already stopped past its endFrame" (which has currentPosition=0
    /// after stopTrack's seekTo(0)) — without it, resumeAll would
    /// incorrectly restart already-finished tracks on every background→
    /// foreground cycle.
    @Volatile var wasPlayingBeforePauseAll: Boolean = false
  }

  fun interface AudioErrorListener { fun onAudioError(message: String) }

  private val tracks = mutableListOf<Track>()
  private val tracksLock = Any()
  // Tracks paused specifically by `setMuted(true)`. On `setMuted(false)` we
  // restart these (subject to the global `paused` gate). Without this set,
  // un-muting was a no-op for tracks that were mid-play when the mute fired:
  // they stayed silent until the next animation loop hit their startFrame.
  // Guarded by `tracksLock`.
  private val mutePausedTracks = HashSet<Track>()
  private val mainHandler = Handler(Looper.getMainLooper())
  var onAudioError: AudioErrorListener? = null

  @Volatile private var muted = false
  @Volatile private var paused = false
  @Volatile private var volume = 1f
  @Volatile private var rate = 1f

  private fun snapshotTracks(): List<Track> = synchronized(tracksLock) { tracks.toList() }

  fun setMuted(value: Boolean) {
    if (muted == value) return
    muted = value
    if (value) {
      // Mute: pause anything mid-play and remember it so un-mute can restart.
      for (track in snapshotTracks()) {
        if (track.released || !track.prepared) continue
        try {
          if (track.player.isPlaying) {
            track.player.pause()
            synchronized(tracksLock) { mutePausedTracks.add(track) }
          }
        } catch (_: IllegalStateException) {}
      }
    } else {
      // Un-mute: restart everything we paused, unless the engine is also
      // globally paused (e.g. backgrounded). When engine-paused, transfer
      // the mute-resume intent to the pauseAll-resume intent so resumeAll()
      // will pick the tracks up later — without this transfer, if `mute(true)`
      // was called BEFORE `pauseAll()`, those tracks would be silently
      // stuck (pauseAll didn't see them as playing, so it didn't record
      // them; mute path drops them at this `if (paused) return`).
      val toResume: List<Track> = synchronized(tracksLock) {
        val list = mutePausedTracks.toList()
        mutePausedTracks.clear()
        list
      }
      if (paused) {
        for (track in toResume) {
          if (!track.released) track.wasPlayingBeforePauseAll = true
        }
        return
      }
      for (track in toResume) {
        if (track.released || !track.prepared) continue
        try { track.player.start() } catch (_: IllegalStateException) {}
      }
    }
  }

  fun setVolume(value: Float) {
    volume = value.coerceIn(0f, 1f)
    for (track in snapshotTracks()) {
      if (track.released || !track.prepared) continue
      try {
        track.player.setVolume(volume, volume)
      } catch (_: IllegalStateException) {}
    }
  }

  fun setRate(value: Float) {
    rate = value.coerceIn(MIN_RATE, MAX_RATE)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    for (track in snapshotTracks()) {
      if (track.released || !track.prepared) continue
      applyRate(track)
    }
  }

  /// Pre-decoded payload returned from `prepareTracks` and consumed by
  /// `installTracks`. `error` carries a deferred failure message that
  /// `installTracks` posts to `onAudioError` on main; `track` is null when
  /// decode failed. Decoupling decode from install lets the host run the
  /// expensive `prepare()` (synchronous) on the entity-load coroutine,
  /// off main, so audio is ready to play the moment `onFrame(0)` fires.
  internal class PreparedTrack(
    val track: Track?,
    val error: String?
  )

  /// Decodes + synchronously prepares MediaPlayer instances for every audio
  /// track in `entity`. Must be called off the main thread — `prepare()`
  /// blocks until the decoder is ready (typically a few ms for the local
  /// in-memory data sources we use, but not main-thread safe).
  fun prepareTracks(entity: SvgaEntity): List<PreparedTrack> {
    if (entity.movie.audios.isEmpty()) return emptyList()
    val out = ArrayList<PreparedTrack>(entity.movie.audios.size)
    for (audio in entity.movie.audios) {
      val bytes = entity.audioData[audio.audioKey] ?: continue
      out.add(prepareOne(audio, bytes))
    }
    return out
  }

  /// Release MediaPlayers from a `prepareTracks` result that never reached
  /// `installTracks` — e.g. the load coroutine was cancelled, or the apply
  /// step threw between prepare and install. Without this the host would
  /// hold prepared MediaPlayers + temp files until JVM finalisation.
  fun releasePrepared(prepared: List<PreparedTrack>) {
    for (p in prepared) {
      val track = p.track ?: continue
      track.released = true
      try {
        track.player.setOnErrorListener(null)
        track.player.reset()
      } catch (_: Exception) {}
      try { track.player.release() } catch (_: Exception) {}
      track.source?.close()
      track.tempFile?.delete()
    }
  }

  /// Main-thread install. Replaces any previously-installed tracks
  /// atomically with the pre-decoded set. Adopts engine-live volume/rate
  /// so a setter issued mid-decode lands on the new tracks too.
  fun installTracks(prepared: List<PreparedTrack>) {
    unload()
    paused = false
    val newTracks = ArrayList<Track>(prepared.size)
    for (p in prepared) {
      val message = p.error
      if (message != null) {
        reportError(message)
        continue
      }
      val track = p.track ?: continue
      try {
        track.player.setVolume(volume, volume)
        applyRate(track)
      } catch (_: IllegalStateException) {}
      newTracks.add(track)
    }
    synchronized(tracksLock) { tracks.addAll(newTracks) }
  }

  /// Convenience: decode + install in one call. Caller must be off main if
  /// it cares about UI smoothness — `prepareTracks` blocks per track.
  fun load(entity: SvgaEntity) {
    installTracks(prepareTracks(entity))
  }

  fun onFrame(frame: Int) {
    if (muted || paused) return
    // Snapshot under the lock so a concurrent unload() doesn't tear our
    // iteration. Tracks already in the snapshot may still flip `released`
    // mid-iteration — startTrack/stopTrack check that explicitly.
    for (track in snapshotTracks()) {
      if (track.released) continue
      if (frame == track.startFrame) startTrack(track)
      if (frame == track.endFrame) stopTrack(track)
    }
  }

  fun pauseAll() {
    paused = true
    for (track in snapshotTracks()) {
      if (track.released || !track.prepared) continue
      try {
        // Capture intent BEFORE pausing so resumeAll knows which tracks to
        // restart. Anything that wasn't playing (already stopped past its
        // endFrame, or hadn't started yet) stays out of the resume set.
        if (track.player.isPlaying) {
          track.wasPlayingBeforePauseAll = true
          track.player.pause()
        }
      } catch (_: IllegalStateException) {}
    }
  }

  fun resumeAll() {
    paused = false
    if (muted) {
      // Engine is also muted — defer resume to the eventual setMuted(false)
      // by promoting each track's pauseAll-resume intent into the
      // mute-resume set. Without this transfer, the inverse-order scenario
      // `pauseAll → mute → resumeAll → unmute` would silently drop the
      // resume info: setMuted(true) couldn't have recorded these tracks
      // because they were already paused-by-pauseAll when it ran, and
      // resumeAll bails here on muted.
      for (track in snapshotTracks()) {
        if (!track.wasPlayingBeforePauseAll) continue
        track.wasPlayingBeforePauseAll = false
        if (track.released) continue
        synchronized(tracksLock) { mutePausedTracks.add(track) }
      }
      return
    }
    for (track in snapshotTracks()) {
      if (track.released || !track.prepared) continue
      if (!track.wasPlayingBeforePauseAll) continue
      track.wasPlayingBeforePauseAll = false
      try {
        if (!track.player.isPlaying) track.player.start()
      } catch (_: IllegalStateException) {}
    }
  }

  fun stopAll() {
    paused = true
    for (track in snapshotTracks()) stopTrack(track)
  }

  /// Public counterpart to `unload()` so the host can drop the current
  /// load's MediaPlayers without also tearing down the engine itself
  /// (release()). Called when source is set to empty.
  fun unloadAll() {
    unload()
  }

  fun release() {
    stopAll()
    unload()
  }

  private fun unload() {
    val toRelease: List<Track> = synchronized(tracksLock) {
      val copy = tracks.toList()
      tracks.clear()
      // Drop any remembered mute-pause references — they all point at
      // tracks we're about to release.
      mutePausedTracks.clear()
      copy
    }
    for (track in toRelease) {
      // Mark released BEFORE clearing listeners + reset + release so any
      // concurrent OnErrorListener that fires after we null the listener
      // still sees the flag and short-circuits.
      track.released = true
      track.prepared = false
      try {
        track.player.setOnErrorListener(null)
        track.player.reset()
      } catch (_: Exception) {}
      try { track.player.release() } catch (_: Exception) {}
      track.source?.close()
      track.tempFile?.delete()
    }
  }

  /// Decodes + synchronously prepares one MediaPlayer for the given audio
  /// track. Must be called off the main thread — `MediaPlayer.prepare()`
  /// blocks (typically a few ms for the in-memory data sources we use, but
  /// strict-mode would flag it on main).
  private fun prepareOne(audio: AudioEntity, bytes: ByteArray): PreparedTrack {
    val player = MediaPlayer()
    player.setAudioAttributes(
      AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()
    )

    var dataSource: BytesMediaDataSource? = null
    var tempFile: File? = null

    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        dataSource = BytesMediaDataSource(bytes)
        player.setDataSource(dataSource)
      } else {
        tempFile = File.createTempFile("svga-audio-${audio.audioKey}-", ".bin", context.cacheDir)
        tempFile.writeBytes(bytes)
        player.setDataSource(tempFile.absolutePath)
      }
    } catch (e: Exception) {
      try { player.release() } catch (_: Exception) {}
      dataSource?.close()
      tempFile?.delete()
      return PreparedTrack(null, "audio source setup failed for ${audio.audioKey}: ${e.message}")
    }

    val track = Track(player, audio.startFrame, audio.endFrame, tempFile, dataSource)
    player.setOnErrorListener { _, what, extra ->
      reportError("audio playback error for ${audio.audioKey} (what=$what extra=$extra)")
      true
    }
    try {
      // Synchronous prepare. Safe for in-memory / on-disk sources; the
      // caller is responsible for keeping us off main.
      player.prepare()
    } catch (e: Exception) {
      try { player.release() } catch (_: Exception) {}
      dataSource?.close()
      tempFile?.delete()
      return PreparedTrack(null, "audio prepare failed for ${audio.audioKey}: ${e.message}")
    }
    track.prepared = true
    return PreparedTrack(track, null)
  }

  private fun startTrack(track: Track) {
    if (paused || track.released) return
    if (!track.prepared) return
    val player = track.player
    try {
      player.seekTo(0)
      applyRate(track)
      player.start()
    } catch (_: IllegalStateException) {}
  }

  private fun stopTrack(track: Track) {
    // Stopping a track invalidates both resume intents (mute and pauseAll).
    track.wasPlayingBeforePauseAll = false
    synchronized(tracksLock) { mutePausedTracks.remove(track) }
    if (track.released || !track.prepared) return
    val player = track.player
    try {
      if (player.isPlaying) player.pause()
      player.seekTo(0)
    } catch (_: IllegalStateException) {}
  }

  private fun applyRate(track: Track) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    if (track.released) return
    val player = track.player
    try {
      // setPlaybackParams with non-zero speed may auto-start a paused/prepared
      // player on Android API 23+, so capture state and restore it.
      val wasPlaying = player.isPlaying
      val params = PlaybackParams().setSpeed(rate)
      player.playbackParams = params
      if (!wasPlaying && player.isPlaying) {
        try { player.pause() } catch (_: IllegalStateException) {}
      }
    } catch (_: Exception) {
    }
  }

  private fun reportError(message: String) {
    val listener = onAudioError ?: return
    mainHandler.post { listener.onAudioError(message) }
  }

  internal class BytesMediaDataSource(private val bytes: ByteArray) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
      if (position >= bytes.size) return -1
      val available = (bytes.size - position.toInt()).coerceAtMost(size)
      System.arraycopy(bytes, position.toInt(), buffer, offset, available)
      return available
    }

    override fun getSize(): Long = bytes.size.toLong()

    override fun close() {}
  }

  companion object {
    private const val MIN_RATE = 0.5f
    private const val MAX_RATE = 2.0f
  }
}
