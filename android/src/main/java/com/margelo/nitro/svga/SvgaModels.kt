package com.margelo.nitro.svga

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/// Reference-counted SVGA payload.
///
/// Background: `Bitmap` holds native (off-heap) memory on every Android
/// version, but on API < 28 the native allocation is only released through
/// `Bitmap.recycle()` or finalisation. With multi-MB sprites in flight,
/// relying on finalisation OOMs low-RAM devices. We can't unconditionally
/// recycle on cache eviction either — multiple `SvgaPlayerView` instances
/// can share the same cached entity. Refcount instead: each holder
/// (`SvgaMemoryCache`, `SvgaPlayerView.entity`, `HybridSvga.entity`,
/// `SvgaSourceLoader` returns) takes a retain; recycle when the count
/// reaches zero.
///
/// Ownership convention:
///   - `SvgaMemoryCache.put`     retains; `entryRemoved` releases.
///   - `SvgaMemoryCache.get`     returns +1 (caller releases when done).
///   - `SvgaSourceLoader.loadEntity` returns +1.
///   - `SvgaPlayerView.entity` setter retains the new value, releases the prior.
///   - `HybridSvga.entity` field holds +1 ownership; assignment transfers.
///
/// All retain/release calls are thread-safe.
internal class SvgaEntity(
  val movie: MovieEntity,
  val bitmaps: Map<String, Bitmap>,
  val audioData: Map<String, ByteArray>
) {
  private val refCount = AtomicInteger(0)
  private val recycled = AtomicBoolean(false)

  val byteSize: Long by lazy { computeByteSize() }

  fun retain(): SvgaEntity {
    refCount.incrementAndGet()
    return this
  }

  fun release() {
    val newCount = refCount.decrementAndGet()
    if (newCount > 0) return
    // newCount < 0 means we've over-released — log defensively. We don't
    // throw because raising here from a finaliser-adjacent path could
    // crash the process, and the entity is already gone.
    if (newCount < 0) {
      android.util.Log.w("SvgaEntity", "release() called more times than retain()")
      return
    }
    if (recycled.compareAndSet(false, true)) {
      for (bmp in bitmaps.values) {
        // isRecycled is the cheap fast-path: skip bitmaps the host app
        // already recycled (e.g. via setImageBitmap reuse).
        if (!bmp.isRecycled) {
          try {
            bmp.recycle()
          } catch (_: Throwable) {
            // some OEM bitmaps throw on recycle — ignore; GC will reclaim
          }
        }
      }
    }
  }

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
