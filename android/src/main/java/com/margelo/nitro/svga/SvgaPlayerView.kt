package com.margelo.nitro.svga

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.view.View

internal class SvgaPlayerView(context: Context) : View(context) {

  fun interface FrameListener { fun onFrame(frame: Int, isLastFrameOfLoop: Boolean) }
  fun interface LoopListener { fun onLoop(count: Int) }
  fun interface FinishListener { fun onFinish() }

  var entity: SvgaEntity? = null
    set(value) {
      // Hold our own +1 ownership while displayed, so cache eviction or
      // a rapid source switch can't recycle the bitmaps under our draw
      // pass. Release the prior entity AFTER assigning the new one — if
      // both refer to the same cached entity (rare but possible) the
      // refcount never dips to zero.
      val prior = field
      field = value?.retain()
      prior?.release()
      reset()
      hasRendered = false
      if (value == null) {
        playing = false
        handler.removeCallbacks(tick)
      }
      invalidate()
    }

  var scaleMode: ScaleMode = ScaleMode.ASPECTFIT
    set(value) { field = value; invalidate() }

  var maxLoops: Int = 0
  var frameInterval: Long = DEFAULT_FRAME_INTERVAL

  fun interface WindowVisibilityListener { fun onVisibilityChanged(visible: Boolean) }

  var onFrame: FrameListener? = null
  var onLoop: LoopListener? = null
  var onFinish: FinishListener? = null
  var onWindowVisibilityChange: WindowVisibilityListener? = null

  private var currentFrame = 0
  private var loopCount = 0
  private var playing = false
  private var hasRendered = false
  private var nextFrameAt = 0L

  fun isPlaying(): Boolean = playing

  private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
  private val handler = Handler(Looper.getMainLooper())

  init {
    setBackgroundColor(Color.TRANSPARENT)
    isClickable = false
  }

  private val tick = object : Runnable {
    override fun run() {
      if (!playing) return
      // advance() invokes user-supplied onFrame/onLoop/onFinish callbacks.
      // An exception in user code must not propagate out of run() — that
      // would stop the Choreographer-style loop and silently freeze the
      // player. Catch and log; the user's onError surface is intentionally
      // not used here to avoid feedback loops if onError itself throws.
      try {
        advance()
      } catch (t: Throwable) {
        android.util.Log.e("SvgaPlayerView", "user callback threw during frame tick", t)
      }
      // Re-check `playing` after advance: a user callback (onFinish in
      // particular) may have called stop()/pause() reentrantly. Without
      // this check we'd post one more tick that would no-op at the gate
      // above — harmless but wasteful, and it leaves a stale runnable in
      // the handler queue across the (very brief) restart-before-tick
      // window.
      if (!playing) return
      val nowMs = System.currentTimeMillis()
      val drift = nowMs - nextFrameAt
      val delay = (frameInterval - drift).coerceAtLeast(0L)
      nextFrameAt = nowMs + delay
      handler.postDelayed(this, delay)
    }
  }

  fun start() {
    if (playing) return
    if (entity == null) return
    playing = true
    nextFrameAt = System.currentTimeMillis() + frameInterval
    if (!hasRendered) {
      hasRendered = true
      try {
        onFrame?.onFrame(currentFrame, false)
      } catch (t: Throwable) {
        android.util.Log.e("SvgaPlayerView", "onFrame callback threw", t)
      }
      invalidate()
    }
    handler.postDelayed(tick, frameInterval)
  }

  fun pause() {
    if (!playing) return
    playing = false
    handler.removeCallbacks(tick)
  }

  fun stop() {
    playing = false
    handler.removeCallbacks(tick)
    reset()
    invalidate()
  }

  fun seekToFrame(frame: Int) {
    val total = entity?.movie?.frames ?: return
    if (total <= 0) return
    currentFrame = frame.coerceIn(0, total - 1)
    if (playing) onFrame?.onFrame(currentFrame, false)
    invalidate()
  }

  fun release() {
    handler.removeCallbacks(tick)
    playing = false
    // NOTE: do NOT clear `entity` here. release() is invoked from
    // onDetachedFromWindow, and RN re-attaches native views in scrollers,
    // FlatLists, and navigation reuse. Clearing entity here would leave
    // the view permanently blank on re-attach because there is no path
    // that re-installs entity from the host. End-of-life entity drop
    // happens in HybridSvga.dispose() instead.
  }

  override fun onDraw(canvas: Canvas) {
    val e = entity ?: return
    val movie = e.movie
    if (movie.frames <= 0) return

    val scale = ScaleCalculator.compute(
      scaleMode,
      width.toFloat(), height.toFloat(),
      movie.viewBoxWidth, movie.viewBoxHeight
    )

    canvas.save()
    canvas.translate(scale.translateX, scale.translateY)
    canvas.scale(scale.scaleX, scale.scaleY)

    for (sprite in movie.sprites) {
      drawSprite(canvas, e, sprite)
    }
    canvas.restore()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    onWindowVisibilityChange?.onVisibilityChanged(true)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    onWindowVisibilityChange?.onVisibilityChanged(false)
    release()
  }

  private fun drawSprite(canvas: Canvas, entity: SvgaEntity, sprite: SpriteEntity) {
    val frames = sprite.frames
    if (currentFrame >= frames.size) return
    val frame = frames[currentFrame]
    if (!frame.hasContent || frame.alpha <= 0f) return
    val bitmap = entity.bitmaps[sprite.imageKey] ?: return
    // Defensive: refcount should keep this alive while we hold `entity`,
    // but if a host app passed a bitmap it later recycled (or a refcount
    // bug slips through), drawBitmap on a recycled bitmap throws and the
    // exception propagates out of onDraw → ANR.
    if (bitmap.isRecycled) return
    val bw = bitmap.width
    val bh = bitmap.height
    if (bw <= 0 || bh <= 0) return

    paint.alpha = (frame.alpha * 255f).toInt().coerceIn(0, 255)
    canvas.drawBitmap(bitmap, frame.transform, paint)
  }

  private fun reset() {
    currentFrame = 0
    loopCount = 0
    hasRendered = false
  }

  private fun advance() {
    val movie = entity?.movie ?: return
    val total = movie.frames
    if (total <= 0) return

    val nextFrame = currentFrame + 1
    val isLast = nextFrame >= total
    if (isLast) {
      currentFrame = 0
      if (loopCount < Int.MAX_VALUE) loopCount += 1
      onLoop?.onLoop(loopCount)
      if (maxLoops in 1..loopCount) {
        playing = false
        invalidate()
        onFinish?.onFinish()
        return
      }
    } else {
      currentFrame = nextFrame
    }

    onFrame?.onFrame(currentFrame, isLast)
    invalidate()
  }

  companion object {
    private const val DEFAULT_FRAME_INTERVAL = 66L
  }
}
