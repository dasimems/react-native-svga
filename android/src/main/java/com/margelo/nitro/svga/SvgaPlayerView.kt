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
    set(value) {
      field = value.coerceAtLeast(1L)
      // A live speed change remaps elapsed-time → frame index; re-anchor so
      // the new interval takes effect from the current frame instead of
      // jumping (old anchor measured against a new interval).
      if (playing) reanchor()
    }

  fun interface WindowVisibilityListener { fun onVisibilityChanged(visible: Boolean) }

  var onFrame: FrameListener? = null
  var onLoop: LoopListener? = null
  var onFinish: FinishListener? = null
  var onWindowVisibilityChange: WindowVisibilityListener? = null

  private var currentFrame = 0
  private var loopCount = 0
  private var playing = false
  private var hasRendered = false
  // Wall-clock anchor for time-based frame selection. `startTimeNanos` is the
  // monotonic time captured when playback (re)started; `anchorAbs` is the
  // absolute frame index (loopCount * frames + currentFrame) at that instant.
  // Each tick derives the frame from elapsed time, so a device that can't
  // sustain the authored fps DROPS frames to stay real-time instead of
  // stretching the timeline into slow motion. Re-anchored on resume, seek and
  // speed change. Long to avoid Int overflow over very long infinite loops.
  private var startTimeNanos = 0L
  private var anchorAbs = 0L

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
      // Aim the next wake at the next frame boundary relative to the play
      // anchor. advance() derives the frame from elapsed wall-clock time and
      // is self-correcting, so even a late wake resolves to the right frame
      // (dropping frames as needed); this scheduling just avoids systematic
      // drift and keeps us to ~one tick per frame.
      val intervalNanos = (frameInterval * NANOS_PER_MS).coerceAtLeast(1L)
      val sinceBoundary = (System.nanoTime() - startTimeNanos) % intervalNanos
      val delayMs = ((intervalNanos - sinceBoundary) / NANOS_PER_MS).coerceIn(0L, frameInterval)
      handler.postDelayed(this, delayMs)
    }
  }

  fun start() {
    if (playing) return
    if (entity == null) return
    playing = true
    reanchor()
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
    // Re-anchor so time-based advance continues from the sought frame rather
    // than snapping back to where elapsed wall-clock says we'd be.
    if (playing) {
      reanchor()
      onFrame?.onFrame(currentFrame, false)
    }
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
    // Clip to view bounds so `aspectFill` (and any sprite with overflowing
    // layout transforms) doesn't paint outside our rect. iOS gets this for
    // free — UIView's draw(_:) context is bounds-clipped by the system —
    // but on Android the canvas a custom View receives in onDraw inherits
    // its clip from the parent, which is unbounded when the React Native
    // host doesn't set `overflow: 'hidden'`. Without this, an aspectFill
    // 496×864 source rendered into a 200×200 slot bleeds into siblings.
    canvas.clipRect(0f, 0f, width.toFloat(), height.toFloat())
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

  /// Pin the time anchor to now and the current absolute frame, so subsequent
  /// ticks measure elapsed playback from here. Called on (re)start, seek, and
  /// speed change.
  private fun reanchor() {
    startTimeNanos = System.nanoTime()
    val total = entity?.movie?.frames ?: 0
    anchorAbs = if (total > 0) loopCount.toLong() * total + currentFrame else 0L
  }

  private fun advance() {
    val movie = entity?.movie ?: return
    val total = movie.frames
    if (total <= 0) return

    // Where elapsed wall-clock time says we should be (absolute frame index
    // since the anchor), vs. where we currently are.
    val intervalNanos = (frameInterval * NANOS_PER_MS).coerceAtLeast(1L)
    val elapsedFrames = ((System.nanoTime() - startTimeNanos) / intervalNanos).coerceAtLeast(0L)
    val targetAbs = anchorAbs + elapsedFrames
    val baseAbs = loopCount.toLong() * total + currentFrame
    if (targetAbs <= baseAbs) return

    var steps = targetAbs - baseAbs
    // Defensive cap on per-tick catch-up. Realistic gaps are a few frames (the
    // loop is paused while hidden/backgrounded and re-anchored on resume). A
    // pathological multi-second main-thread stall could otherwise replay
    // thousands of audio cues / onLoop callbacks in one tick. Past a couple of
    // loops the older history is moot — clamp the replay and re-anchor below so
    // we don't perpetually chase the backlog.
    val cap = (total.toLong() * 2).coerceAtLeast(1L)
    val capped = steps > cap
    if (capped) steps = cap

    // Step frame-by-frame so audio start/end cues and per-loop callbacks fire
    // for every crossed frame, but DRAW (invalidate) only once at the end —
    // the expensive op runs once regardless of how many frames were dropped.
    var i = 0L
    while (i < steps) {
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
      // The audio cue handler matches start/end frame equality, so every
      // crossed frame must be offered even though we invalidate once below.
      onFrame?.onFrame(currentFrame, isLast)
      i++
    }

    if (capped) {
      // Discard the unplayable backlog after an extreme stall so we resume
      // real-time pacing from here instead of running fast to chase frames
      // the user never saw.
      startTimeNanos = System.nanoTime()
      anchorAbs = loopCount.toLong() * total + currentFrame
    }

    invalidate()
  }

  companion object {
    private const val DEFAULT_FRAME_INTERVAL = 66L
    private const val NANOS_PER_MS = 1_000_000L
  }
}
