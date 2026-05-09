package com.margelo.nitro.svga

internal class ProtoReader(private val buf: ByteArray) {

  companion object {
    const val WIRE_VARINT = 0
    const val WIRE_FIXED64 = 1
    const val WIRE_LENGTH_DELIMITED = 2
    const val WIRE_FIXED32 = 5

    private const val MAX_VARINT_BYTES = 10
  }

  data class Tag(val field: Int, val wire: Int)

  private var pos = 0

  fun hasMore(): Boolean = pos < buf.size

  fun readVarint(): Long {
    var result = 0L
    var shift = 0
    var read = 0
    while (pos < buf.size) {
      if (read >= MAX_VARINT_BYTES) throw SvgaParseException("varint too long")
      val b = buf[pos].toLong() and 0xFF
      pos++
      read++
      result = result or ((b and 0x7F) shl shift)
      if ((b and 0x80) == 0L) return result
      shift += 7
    }
    throw SvgaParseException("truncated varint")
  }

  fun readTag(): Tag {
    val raw = readVarint().toInt()
    return Tag(raw ushr 3, raw and 0x7)
  }

  fun readBytes(): ByteArray {
    val len = readVarint().toInt()
    if (len < 0 || pos + len > buf.size) throw SvgaParseException("length-delimited overflow")
    val data = buf.copyOfRange(pos, pos + len)
    pos += len
    return data
  }

  fun readString(): String = String(readBytes(), Charsets.UTF_8)

  fun readInt32(): Int = readVarint().toInt()

  fun readFloat(): Float {
    if (pos + 4 > buf.size) throw SvgaParseException("truncated float")
    val bits = (buf[pos].toInt() and 0xFF) or
      ((buf[pos + 1].toInt() and 0xFF) shl 8) or
      ((buf[pos + 2].toInt() and 0xFF) shl 16) or
      ((buf[pos + 3].toInt() and 0xFF) shl 24)
    pos += 4
    return java.lang.Float.intBitsToFloat(bits)
  }

  fun skip(wire: Int) {
    when (wire) {
      WIRE_VARINT -> readVarint()
      WIRE_FIXED64 -> advance(8)
      WIRE_LENGTH_DELIMITED -> readBytes()
      WIRE_FIXED32 -> advance(4)
      else -> throw SvgaParseException("unknown wire type $wire")
    }
  }

  private fun advance(n: Int) {
    if (pos + n > buf.size) throw SvgaParseException("truncated fixed field")
    pos += n
  }
}

internal class SvgaParseException(message: String) : RuntimeException(message)
