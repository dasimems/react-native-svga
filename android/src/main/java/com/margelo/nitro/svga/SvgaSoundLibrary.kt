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
        // Remove from the map first (under the lock), THEN defer the
        // blocking reset()/release() to the disposer thread — once the
        // track is unreachable, no play/stop can race the teardown. Keeps
        // the lock hold time (and the caller's thread) free of media-server
        // IPC; see SvgaMediaDisposer.
        tracks.remove(key)
        SvgaMediaDisposer.dispose(existing.player)
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

  // play/stop/stopAll hold `loadLock` for the same reason `load`/`unload` do:
  // the lookup in `tracks` and the subsequent `player.setVolume/seekTo/start`
  // must be atomic against a concurrent `unload`/`release`. Teardown removes
  // the track from the map UNDER THIS LOCK and only then hands the player to
  // `SvgaMediaDisposer`, so a player is never physically released while any
  // lock-holding caller can still reach it. iOS sidesteps this by serialising
  // every public method on a single dispatch queue; this lock mirrors that.
  // ReentrantLock makes nested calls (e.g. test harnesses that call
  // load→play synchronously) safe.
  fun play(key: String, volume: Float) {
    loadLock.withLock {
      val track = tracks[key] ?: return
      val v = volume.coerceIn(0f, 1f)
      try {
        track.player.setVolume(v, v)
        track.player.seekTo(0)
        track.player.start()
      } catch (_: IllegalStateException) {}
    }
  }

  fun stop(key: String) {
    loadLock.withLock {
      val track = tracks[key] ?: return
      try {
        if (track.player.isPlaying) track.player.pause()
        track.player.seekTo(0)
      } catch (_: IllegalStateException) {}
    }
  }

  fun stopAll() {
    loadLock.withLock {
      for ((_, track) in tracks) {
        try {
          if (track.player.isPlaying) track.player.pause()
          track.player.seekTo(0)
        } catch (_: IllegalStateException) {}
      }
    }
  }

  fun unload(key: String) {
    loadLock.withLock {
      val track = tracks.remove(key) ?: return
      SvgaMediaDisposer.dispose(track.player)
    }
  }

  fun release() {
    loadLock.withLock {
      for ((_, track) in tracks) {
        SvgaMediaDisposer.dispose(track.player)
      }
      tracks.clear()
    }
  }
}
