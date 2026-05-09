package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import java.io.File
import java.util.concurrent.ConcurrentHashMap

internal class SvgaSoundLibrary(private val context: Context) {

  private data class Track(val player: MediaPlayer, val file: File)

  private val tracks = ConcurrentHashMap<String, Track>()

  fun load(key: String, source: File) {
    if (tracks.containsKey(key)) return
    val player = MediaPlayer()
    player.setAudioAttributes(
      AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()
    )
    try {
      player.setDataSource(source.absolutePath)
      player.prepare()
      tracks[key] = Track(player, source)
    } catch (e: Exception) {
      player.release()
      throw e
    }
  }

  fun play(key: String, volume: Float) {
    val track = tracks[key] ?: return
    val v = volume.coerceIn(0f, 1f)
    val player = track.player
    try {
      player.setVolume(v, v)
      player.seekTo(0)
      player.start()
    } catch (_: IllegalStateException) {}
  }

  fun stop(key: String) {
    val track = tracks[key] ?: return
    val player = track.player
    try {
      if (player.isPlaying) player.pause()
      player.seekTo(0)
    } catch (_: IllegalStateException) {}
  }

  fun stopAll() {
    for ((_, track) in tracks) {
      val player = track.player
      try {
        if (player.isPlaying) player.pause()
        player.seekTo(0)
      } catch (_: IllegalStateException) {}
    }
  }

  fun unload(key: String) {
    val track = tracks.remove(key) ?: return
    try { track.player.reset() } catch (_: Exception) {}
    track.player.release()
  }

  fun release() {
    for ((_, track) in tracks) {
      try { track.player.reset() } catch (_: Exception) {}
      track.player.release()
    }
    tracks.clear()
  }
}
