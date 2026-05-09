package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import java.io.File
import java.util.concurrent.ConcurrentHashMap

internal class SvgaAudioEngine(private val context: Context) {

  private data class Track(
    val soundId: Int,
    val startFrame: Int,
    val endFrame: Int,
    val tempFile: File
  )

  private val pool: SoundPool = SoundPool.Builder()
    .setMaxStreams(MAX_STREAMS)
    .setAudioAttributes(
      AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()
    )
    .build()

  private val ready = ConcurrentHashMap<Int, Boolean>()
  private val tracks = mutableListOf<Track>()
  private val activeStreams = mutableMapOf<Int, Int>()

  @Volatile private var muted = false
  @Volatile private var volume = 1f
  @Volatile private var rate = 1f

  init {
    pool.setOnLoadCompleteListener { _, sampleId, status ->
      ready[sampleId] = (status == 0)
    }
  }

  fun setMuted(value: Boolean) {
    muted = value
    if (!value) return
    for ((_, streamId) in activeStreams) pool.stop(streamId)
    activeStreams.clear()
  }

  fun setVolume(value: Float) {
    volume = value.coerceIn(0f, 1f)
    for ((_, streamId) in activeStreams) pool.setVolume(streamId, volume, volume)
  }

  fun setRate(value: Float) {
    rate = value.coerceIn(MIN_RATE, MAX_RATE)
    for ((_, streamId) in activeStreams) pool.setRate(streamId, rate)
  }

  fun load(entity: SvgaEntity) {
    unload()
    if (entity.movie.audios.isEmpty()) return
    for (audio in entity.movie.audios) {
      val bytes = entity.audioData[audio.audioKey] ?: continue
      val file = File.createTempFile("svga-audio-${audio.audioKey}-", ".bin", context.cacheDir)
      file.writeBytes(bytes)
      val soundId = pool.load(file.absolutePath, 1)
      tracks.add(Track(soundId, audio.startFrame, audio.endFrame, file))
    }
  }

  fun onFrame(frame: Int) {
    if (muted) return
    for (track in tracks) {
      if (frame == track.startFrame) startTrack(track)
      if (frame == track.endFrame) stopTrack(track)
    }
  }

  fun pauseAll() { pool.autoPause() }

  fun resumeAll() {
    if (muted) return
    pool.autoResume()
  }

  fun stopAll() {
    for ((_, streamId) in activeStreams) pool.stop(streamId)
    activeStreams.clear()
  }

  fun release() {
    stopAll()
    unload()
    pool.release()
  }

  private fun unload() {
    for (track in tracks) {
      pool.unload(track.soundId)
      track.tempFile.delete()
    }
    tracks.clear()
    ready.clear()
  }

  private fun startTrack(track: Track) {
    if (ready[track.soundId] != true) return
    val streamId = pool.play(track.soundId, volume, volume, 1, 0, rate)
    if (streamId != 0) activeStreams[track.startFrame] = streamId
  }

  private fun stopTrack(track: Track) {
    val streamId = activeStreams.remove(track.startFrame) ?: return
    pool.stop(streamId)
  }

  companion object {
    private const val MAX_STREAMS = 4
    private const val MIN_RATE = 0.5f
    private const val MAX_RATE = 2.0f
  }
}
