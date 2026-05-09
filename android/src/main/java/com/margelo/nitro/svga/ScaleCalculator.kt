package com.margelo.nitro.svga

internal object ScaleCalculator {

  data class Result(val scaleX: Float, val scaleY: Float, val translateX: Float, val translateY: Float)

  fun compute(
    mode: ScaleMode,
    viewWidth: Float,
    viewHeight: Float,
    contentWidth: Float,
    contentHeight: Float
  ): Result {
    if (contentWidth <= 0f || contentHeight <= 0f) return Result(1f, 1f, 0f, 0f)

    if (mode == ScaleMode.FILL) {
      return Result(viewWidth / contentWidth, viewHeight / contentHeight, 0f, 0f)
    }

    val sx = viewWidth / contentWidth
    val sy = viewHeight / contentHeight
    val scale = when (mode) {
      ScaleMode.ASPECTFILL -> maxOf(sx, sy)
      else -> minOf(sx, sy)
    }
    val tx = (viewWidth - contentWidth * scale) / 2f
    val ty = (viewHeight - contentHeight * scale) / 2f
    return Result(scale, scale, tx, ty)
  }
}
