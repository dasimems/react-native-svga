package com.margelo.nitro.svga

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.test.assertFailsWith

class ProtoReaderTest {

  @Test
  fun `single-byte varint`() {
    val r = ProtoReader(byteArrayOf(0x05))
    assertEquals(5L, r.readVarint())
    assertFalse(r.hasMore())
  }

  @Test
  fun `multi-byte varint`() {
    // 300 = 0xAC 0x02 (little-endian groups of 7 bits)
    val r = ProtoReader(byteArrayOf(0xAC.toByte(), 0x02))
    assertEquals(300L, r.readVarint())
  }

  @Test
  fun `tag splits field and wire type`() {
    // field 1, wire type 2 => (1 << 3) | 2 = 0x0A
    val r = ProtoReader(byteArrayOf(0x0A))
    val tag = r.readTag()
    assertEquals(1, tag.field)
    assertEquals(ProtoReader.WIRE_LENGTH_DELIMITED, tag.wire)
  }

  @Test
  fun `length-delimited bytes`() {
    val r = ProtoReader(byteArrayOf(0x03, 0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte()))
    val out = r.readBytes()
    assertEquals(3, out.size)
    assertEquals(0xAA.toByte(), out[0])
    assertEquals(0xBB.toByte(), out[1])
    assertEquals(0xCC.toByte(), out[2])
  }

  @Test
  fun `string round-trips`() {
    val s = "hello"
    val bytes = s.toByteArray(Charsets.UTF_8)
    val r = ProtoReader(byteArrayOf(bytes.size.toByte()) + bytes)
    assertEquals("hello", r.readString())
  }

  @Test
  fun `little-endian float`() {
    // 1.0f = 0x3F800000 little endian: 00 00 80 3F
    val r = ProtoReader(byteArrayOf(0x00, 0x00, 0x80.toByte(), 0x3F))
    assertEquals(1.0f, r.readFloat(), 0.0001f)
  }

  @Test
  fun `truncated varint throws`() {
    val r = ProtoReader(byteArrayOf(0x80.toByte())) // continuation bit set, no follow-up
    assertFailsWith<SvgaParseException> { r.readVarint() }
  }

  @Test
  fun `length-delimited overflow throws`() {
    val r = ProtoReader(byteArrayOf(0x10, 0x00, 0x01)) // claims 16 bytes but only 2 follow
    assertFailsWith<SvgaParseException> { r.readBytes() }
  }

  @Test
  fun `truncated float throws`() {
    val r = ProtoReader(byteArrayOf(0x00, 0x00))
    assertFailsWith<SvgaParseException> { r.readFloat() }
  }

  @Test
  fun `skip handles all wire types`() {
    val r = ProtoReader(byteArrayOf(0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
    r.skip(ProtoReader.WIRE_VARINT)    // consumes 0x05
    r.skip(ProtoReader.WIRE_FIXED64)   // consumes 8 bytes
    assertFalse(r.hasMore())
  }

  @Test
  fun `unknown wire type throws`() {
    val r = ProtoReader(byteArrayOf(0x00))
    assertFailsWith<SvgaParseException> { r.skip(7) }
  }

  @Test
  fun `hasMore reports remaining bytes`() {
    val r = ProtoReader(byteArrayOf(0x01, 0x02))
    assertTrue(r.hasMore())
    r.readVarint()
    assertTrue(r.hasMore())
    r.readVarint()
    assertFalse(r.hasMore())
  }
}
