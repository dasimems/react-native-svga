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
