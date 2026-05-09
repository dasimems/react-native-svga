package com.margelo.nitro.svga

import org.junit.Assert.assertEquals
import org.junit.Test

class ScaleCalculatorTest {

  private val eps = 0.001f

  @Test
  fun `fill stretches to view dimensions with no translation`() {
    val r = ScaleCalculator.compute(ScaleMode.FILL, 200f, 100f, 100f, 100f)
    assertEquals(2f, r.scaleX, eps)
    assertEquals(1f, r.scaleY, eps)
    assertEquals(0f, r.translateX, eps)
    assertEquals(0f, r.translateY, eps)
  }

  @Test
  fun `aspect fit uses smaller scale and centers content`() {
    val r = ScaleCalculator.compute(ScaleMode.ASPECTFIT, 200f, 100f, 100f, 100f)
    assertEquals(1f, r.scaleX, eps)
    assertEquals(1f, r.scaleY, eps)
    assertEquals(50f, r.translateX, eps)
    assertEquals(0f, r.translateY, eps)
  }

  @Test
  fun `aspect fill uses larger scale and centers content`() {
    val r = ScaleCalculator.compute(ScaleMode.ASPECTFILL, 200f, 100f, 100f, 100f)
    assertEquals(2f, r.scaleX, eps)
    assertEquals(2f, r.scaleY, eps)
    assertEquals(0f, r.translateX, eps)
    assertEquals(-50f, r.translateY, eps)
  }

  @Test
  fun `zero content dimensions return identity transform`() {
    val r = ScaleCalculator.compute(ScaleMode.ASPECTFIT, 200f, 100f, 0f, 0f)
    assertEquals(1f, r.scaleX, eps)
    assertEquals(1f, r.scaleY, eps)
    assertEquals(0f, r.translateX, eps)
    assertEquals(0f, r.translateY, eps)
  }

  @Test
  fun `aspect fit with portrait content in landscape view`() {
    val r = ScaleCalculator.compute(ScaleMode.ASPECTFIT, 400f, 200f, 100f, 200f)
    assertEquals(1f, r.scaleX, eps)
    assertEquals(1f, r.scaleY, eps)
    assertEquals(150f, r.translateX, eps)
    assertEquals(0f, r.translateY, eps)
  }
}
