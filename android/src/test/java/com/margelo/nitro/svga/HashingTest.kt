package com.margelo.nitro.svga

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class HashingTest {

  @Test
  fun `sha256 returns deterministic 64-char lowercase hex`() {
    val hash = Hashing.sha256("https://example.test/sample.svga")
    assertEquals(64, hash.length)
    assertEquals(hash.lowercase(), hash)
    assertEquals(hash, Hashing.sha256("https://example.test/sample.svga"))
  }

  @Test
  fun `different inputs hash to different outputs`() {
    val a = Hashing.sha256("a")
    val b = Hashing.sha256("b")
    assertNotEquals(a, b)
  }

  @Test
  fun `empty string hashes to known sha256 of empty bytes`() {
    val expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assertEquals(expected, Hashing.sha256(""))
  }

  @Test
  fun `known vector for 'abc'`() {
    val expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assertEquals(expected, Hashing.sha256("abc"))
  }
}
