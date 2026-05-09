package com.margelo.nitro.svga

import java.security.MessageDigest

internal object Hashing {

  private const val HEX = "0123456789abcdef"

  fun sha256(input: String): String {
    val bytes = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
    val out = CharArray(bytes.size * 2)
    var i = 0
    for (b in bytes) {
      val v = b.toInt() and 0xFF
      out[i++] = HEX[v ushr 4]
      out[i++] = HEX[v and 0x0F]
    }
    return String(out)
  }
}
