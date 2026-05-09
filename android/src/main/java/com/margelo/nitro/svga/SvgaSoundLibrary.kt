package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import java.io.File
import java.util.concurrent.ConcurrentHashMap

internal class SvgaSoundLibrary(private val context: Context) {

  private data class Track(val soundId: Int, var streamId: Int = 0)

  private val pool: SoundPool = SoundPool.Builder()
    .setMaxStreams(MAX_STREAMS)
    .setAudioAttributes(
      AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()
    )
    .build()

  private val tracks = ConcurrentHashMap<String, Track>()
  private val ready = ConcurrentHashMap<Int, Boolean>()

  init {
    pool.setOnLoadCompleteListener { _, sampleId, status ->
      ready[sampleId] = (status == 0)
    }
  }

  fun load(key: String, file: File) {
    val existing = tracks[key]
    if (existing != null) return
    val soundId = pool.load(file.absolutePath, 1)
    tracks[key] = Track(soundId)
  }

  fun play(key: String, volume: Float) {
    val track = tracks[key] ?: return
    if (ready[track.soundId] != true) return
    val v = volume.coerceIn(0f, 1f)
    track.streamId = pool.play(track.soundId, v, v, 1, 0, 1f)
  }

  fun stop(key: String) {
    val track = tracks[key] ?: return
    if (track.streamId == 0) return
    pool.stop(track.streamId)
    track.streamId = 0
  }

  fun stopAll() {
    for ((_, track) in tracks) {
      if (track.streamId == 0) continue
      pool.stop(track.streamId)
      track.streamId = 0
    }
  }

  fun unload(key: String) {
    val track = tracks.remove(key) ?: return
    if (track.streamId != 0) pool.stop(track.streamId)
    pool.unload(track.soundId)
    ready.remove(track.soundId)
  }

  fun release() {
    stopAll()
    tracks.clear()
    ready.clear()
    pool.release()
  }

  companion object {
    private const val MAX_STREAMS = 8
  }
}
