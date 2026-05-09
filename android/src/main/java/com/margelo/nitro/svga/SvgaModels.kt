package com.margelo.nitro.svga

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF

internal data class SvgaEntity(
  val movie: MovieEntity,
  val bitmaps: Map<String, Bitmap>,
  val audioData: Map<String, ByteArray>
) {
  val byteSize: Long by lazy { computeByteSize() }

  private fun computeByteSize(): Long {
    var total = 0L
    for (bmp in bitmaps.values) total += bmp.byteCount.toLong()
    for (bytes in audioData.values) total += bytes.size.toLong()
    var totalFrames = 0
    for (sprite in movie.sprites) totalFrames += sprite.frames.size
    // FrameEntity (Matrix + RectF + flags) ~80 B per frame; SpriteEntity overhead ~64 B.
    total += totalFrames.toLong() * 80L
    total += movie.sprites.size.toLong() * 64L
    return total
  }
}

internal data class MovieEntity(
  val viewBoxWidth: Float,
  val viewBoxHeight: Float,
  val fps: Int,
  val frames: Int,
  val sprites: List<SpriteEntity>,
  val audios: List<AudioEntity>
)

internal data class SpriteEntity(
  val imageKey: String,
  val frames: List<FrameEntity>
)

internal data class FrameEntity(
  val alpha: Float,
  val layout: RectF,
  val transform: Matrix,
  val hasContent: Boolean
)

internal data class AudioEntity(
  val audioKey: String,
  val startFrame: Int,
  val endFrame: Int,
  val startTime: Int,
  val totalTime: Int
)
