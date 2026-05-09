package com.margelo.nitro.svga

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class UrlValidatorTest {

  @Test
  fun `https url resolves as remote`() {
    val r = UrlValidator.resolve("https://cdn.test/foo.svga")
    assertNotNull(r)
    assertEquals(UrlValidator.Kind.REMOTE, r!!.kind)
    assertEquals("https://cdn.test/foo.svga", r.value)
  }

  @Test
  fun `http url resolves as remote`() {
    val r = UrlValidator.resolve("http://cdn.test/foo.svga")
    assertEquals(UrlValidator.Kind.REMOTE, r!!.kind)
  }

  @Test
  fun `asset scheme resolves as bundled asset and strips prefix`() {
    val r = UrlValidator.resolve("asset://animations/cheer.svga")
    assertEquals(UrlValidator.Kind.BUNDLED_ASSET, r!!.kind)
    assertEquals("animations/cheer.svga", r.value)
  }

  @Test
  fun `file scheme resolves as local file`() {
    val r = UrlValidator.resolve("file:///tmp/sample.svga")
    assertEquals(UrlValidator.Kind.LOCAL_FILE, r!!.kind)
    assertEquals("/tmp/sample.svga", r.value)
  }

  @Test
  fun `bare absolute path resolves as local file`() {
    val r = UrlValidator.resolve("/absolute/path/sample.svga")
    assertEquals(UrlValidator.Kind.LOCAL_FILE, r!!.kind)
    assertEquals("/absolute/path/sample.svga", r.value)
  }

  @Test
  fun `path traversal is rejected`() {
    assertNull(UrlValidator.resolve("file:///tmp/../../etc/passwd"))
    assertNull(UrlValidator.resolve("/tmp/../../etc/passwd"))
  }

  @Test
  fun `empty and blank input is rejected`() {
    assertNull(UrlValidator.resolve(""))
    assertNull(UrlValidator.resolve("   "))
  }

  @Test
  fun `unknown schemes are rejected`() {
    assertNull(UrlValidator.resolve("javascript:alert(1)"))
    assertNull(UrlValidator.resolve("ftp://x.test/y"))
    assertNull(UrlValidator.resolve("data:text/plain,hi"))
  }

  @Test
  fun `https without host is rejected`() {
    assertNull(UrlValidator.resolve("https:///nohost"))
  }

  @Test
  fun `whitespace is trimmed before validation`() {
    val r = UrlValidator.resolve("  https://x.test/y.svga  ")
    assertEquals(UrlValidator.Kind.REMOTE, r!!.kind)
    assertEquals("https://x.test/y.svga", r.value)
  }
}
