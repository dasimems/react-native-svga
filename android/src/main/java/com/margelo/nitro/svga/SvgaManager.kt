package com.margelo.nitro.svgamanager

import com.facebook.proguard.annotations.DoNotStrip

@DoNotStrip
class SvgaManager : HybridSvgaManagerSpec() {
  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }
}
