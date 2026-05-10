package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class SvgaSoundLibrary(private val context: Context) {

  private class Track(val player: MediaPlayer, val sourcePath: String)

  private val tracks = ConcurrentHashMap<String, Track>()
  private val loadLock = ReentrantLock()

  fun load(key: String, source: File) {
    val newPath = source.absolutePath
    loadLock.withLock {
      val existing = tracks[key]
      if (existing != null && existing.sourcePath == newPath) return
      if (existing != null) {
        try { existing.player.reset() } catch (_: Exception) {}
        existing.player.release()
        tracks.remove(key)
      }
      val player = MediaPlayer()
      player.setAudioAttributes(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .build()
      )
      try {
        player.setDataSource(newPath)
        player.prepare()
        tracks[key] = Track(player, newPath)
      } catch (e: Exception) {
        player.release()
        throw e
      }
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
    loadLock.withLock {
      val track = tracks.remove(key) ?: return
      try { track.player.reset() } catch (_: Exception) {}
      track.player.release()
    }
  }

  fun release() {
    loadLock.withLock {
      for ((_, track) in tracks) {
        try { track.player.reset() } catch (_: Exception) {}
        track.player.release()
      }
      tracks.clear()
    }
  }
}
