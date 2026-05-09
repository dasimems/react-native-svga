package com.margelo.nitro.svga

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import java.io.File

internal class SvgaAudioEngine(private val context: Context) {

  private class Track(
    val player: MediaPlayer,
    val startFrame: Int,
    val endFrame: Int,
    val tempFile: File?,
    val source: BytesMediaDataSource?,
    var prepared: Boolean,
    var pendingStart: Boolean
  )

  fun interface AudioErrorListener { fun onAudioError(message: String) }

  private val tracks = mutableListOf<Track>()
  var onAudioError: AudioErrorListener? = null

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
    for (track in tracks) {
      if (track.prepared) track.player.setVolume(volume, volume)
    }
  }

  fun setRate(value: Float) {
    rate = value.coerceIn(MIN_RATE, MAX_RATE)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    for (track in tracks) {
      if (track.prepared) applyRate(track.player)
    }
  }

  fun load(entity: SvgaEntity) {
    unload()
    if (entity.movie.audios.isEmpty()) return
    for (audio in entity.movie.audios) {
      val bytes = entity.audioData[audio.audioKey] ?: continue
      val track = newTrack(audio, bytes) ?: continue
      tracks.add(track)
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
      if (track.prepared && track.player.isPlaying) track.player.pause()
    }
  }

  fun resumeAll() {
    if (muted) return
    for (track in tracks) {
      val player = track.player
      if (!track.prepared) continue
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
      track.source?.close()
      track.tempFile?.delete()
    }
    tracks.clear()
  }

  private fun newTrack(audio: AudioEntity, bytes: ByteArray): Track? {
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
      onAudioError?.onAudioError("audio source setup failed for ${audio.audioKey}: ${e.message}")
      try { player.release() } catch (_: Exception) {}
      dataSource?.close()
      tempFile?.delete()
      return null
    }

    val track = Track(player, audio.startFrame, audio.endFrame, tempFile, dataSource, prepared = false, pendingStart = false)
    player.setOnPreparedListener {
      track.prepared = true
      try {
        player.setVolume(volume, volume)
        applyRate(player)
        if (track.pendingStart && !muted) {
          track.pendingStart = false
          player.seekTo(0)
          player.start()
        }
      } catch (_: IllegalStateException) {}
    }
    player.setOnErrorListener { _, what, extra ->
      onAudioError?.onAudioError("audio playback error for ${audio.audioKey} (what=$what extra=$extra)")
      track.prepared = false
      true
    }
    try {
      player.prepareAsync()
    } catch (e: Exception) {
      onAudioError?.onAudioError("audio prepare failed for ${audio.audioKey}: ${e.message}")
      try { player.release() } catch (_: Exception) {}
      dataSource?.close()
      tempFile?.delete()
      return null
    }
    return track
  }

  private fun startTrack(track: Track) {
    if (!track.prepared) {
      track.pendingStart = true
      return
    }
    val player = track.player
    try {
      player.seekTo(0)
      applyRate(player)
      player.start()
    } catch (_: IllegalStateException) {}
  }

  private fun stopTrack(track: Track) {
    track.pendingStart = false
    if (!track.prepared) return
    val player = track.player
    try {
      if (player.isPlaying) player.pause()
      player.seekTo(0)
    } catch (_: IllegalStateException) {}
  }

  private fun applyRate(player: MediaPlayer) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    try {
      val params = PlaybackParams().setSpeed(rate)
      player.playbackParams = params
    } catch (_: Exception) {
    }
  }

  private class BytesMediaDataSource(private val bytes: ByteArray) : MediaDataSource() {
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
