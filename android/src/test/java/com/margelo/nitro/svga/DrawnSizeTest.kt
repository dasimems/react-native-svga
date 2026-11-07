package com.margelo.nitro.svga

import org.junit.Assert.assertEquals
import org.junit.Test

class DrawnSizeTest {

  @Test
  fun `samples down to the drawn size but never below it`() {
    // 2048×1024 drawn at 400×200 (440×220 with headroom): 4 gives 512×256.
    assertEquals(4, SvgaParser.sampleSizeFor(2048, 1024, 400f to 200f, 2048))
  }

  @Test
  fun `keeps full size when drawn larger than the bitmap`() {
    assertEquals(1, SvgaParser.sampleSizeFor(300, 300, 900f to 900f, 2048))
  }

  @Test
  fun `still fits the device cap`() {
    assertEquals(2, SvgaParser.sampleSizeFor(4096, 4096, 3000f to 3000f, 2048))
  }

  @Test
  fun `without a drawn size only the device cap applies`() {
    assertEquals(1, SvgaParser.sampleSizeFor(1000, 1000, null, 2048))
    assertEquals(2, SvgaParser.sampleSizeFor(3000, 1000, null, 2048))
  }
}
