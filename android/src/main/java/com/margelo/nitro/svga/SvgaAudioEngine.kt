package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import java.io.File

internal class SvgaAudioEngine(private val context: Context) {

  private data class Track(
    val player: MediaPlayer,
    val startFrame: Int,
    val endFrame: Int,
    val tempFile: File
  )

  private val tracks = mutableListOf<Track>()

  @Volatile private var muted = false
  @Volatile private var volume = 1f
  @Volatile private var rate = 1f

  fun setMuted(value: Boolean) {
    muted = value
    if (!value) return
    for (track in tracks) {
      if (track.player.isPlaying) track.player.pause()
    }
  }

  fun setVolume(value: Float) {
    volume = value.coerceIn(0f, 1f)
    for (track in tracks) track.player.setVolume(volume, volume)
  }

  fun setRate(value: Float) {
    rate = value.coerceIn(MIN_RATE, MAX_RATE)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    for (track in tracks) applyRate(track.player)
  }

  fun load(entity: SvgaEntity) {
    unload()
    if (entity.movie.audios.isEmpty()) return
    for (audio in entity.movie.audios) {
      val bytes = entity.audioData[audio.audioKey] ?: continue
      val file = File.createTempFile("svga-audio-${audio.audioKey}-", ".bin", context.cacheDir)
      try {
        file.writeBytes(bytes)
        val player = newPlayer(file) ?: continue
        tracks.add(Track(player, audio.startFrame, audio.endFrame, file))
      } catch (_: Exception) {
        file.delete()
      }
    }
  }

  fun onFrame(frame: Int) {
    if (muted) return
    for (track in tracks) {
      if (frame == track.startFrame) startTrack(track)
      if (frame == track.endFrame) stopTrack(track)
    }
  }

  fun pauseAll() {
    for (track in tracks) {
      if (track.player.isPlaying) track.player.pause()
    }
  }

  fun resumeAll() {
    if (muted) return
    for (track in tracks) {
      val player = track.player
      if (!player.isPlaying && player.currentPosition > 0) {
        try { player.start() } catch (_: IllegalStateException) {}
      }
    }
  }

  fun stopAll() {
    for (track in tracks) stopTrack(track)
  }

  fun release() {
    stopAll()
    unload()
  }

  private fun unload() {
    for (track in tracks) {
      try { track.player.reset() } catch (_: Exception) {}
      track.player.release()
      track.tempFile.delete()
    }
    tracks.clear()
  }

  private fun newPlayer(file: File): MediaPlayer? {
    val player = MediaPlayer()
    player.setAudioAttributes(
      AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()
    )
    return try {
      player.setDataSource(file.absolutePath)
      player.prepare()
      player.setVolume(volume, volume)
      applyRate(player)
      player
    } catch (_: Exception) {
      player.release()
      null
    }
  }

  private fun startTrack(track: Track) {
    val player = track.player
    try {
      player.seekTo(0)
      applyRate(player)
      player.start()
    } catch (_: IllegalStateException) {}
  }

  private fun stopTrack(track: Track) {
    val player = track.player
    try {
      if (player.isPlaying) player.pause()
      player.seekTo(0)
    } catch (_: IllegalStateException) {}
  }

  private fun applyRate(player: MediaPlayer) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    try {
      val wasPlaying = player.isPlaying
      val params = PlaybackParams().setSpeed(rate)
      player.playbackParams = params
      if (!wasPlaying) {
        // setPlaybackParams forces playback to start on some devices; pause again.
        try { if (player.isPlaying) player.pause() } catch (_: IllegalStateException) {}
      }
    } catch (_: Exception) {
      // Some codecs don't support rate changes; ignore.
    }
  }

  companion object {
    private const val MIN_RATE = 0.5f
    private const val MAX_RATE = 2.0f
  }
}
