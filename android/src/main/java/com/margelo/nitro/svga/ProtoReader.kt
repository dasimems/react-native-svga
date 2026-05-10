package com.margelo.nitro.svga

internal class ProtoReader private constructor(
  private val buf: ByteArray,
  private val limit: Int,
  private var pos: Int
) {

  companion object {
    const val WIRE_VARINT = 0
    const val WIRE_FIXED64 = 1
    const val WIRE_LENGTH_DELIMITED = 2
    const val WIRE_FIXED32 = 5

    private const val MAX_VARINT_BYTES = 10
  }

  constructor(bytes: ByteArray) : this(bytes, bytes.size, 0)

  data class Tag(val field: Int, val wire: Int)

  fun hasMore(): Boolean = pos < limit

  fun readVarint(): Long {
    var result = 0L
    var shift = 0
    var read = 0
    while (pos < limit) {
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

  fun readSubReader(): ProtoReader {
    val len = checkedLength()
    val sub = ProtoReader(buf, pos + len, pos)
    pos += len
    return sub
  }

  fun readBytes(): ByteArray {
    val len = checkedLength()
    val data = buf.copyOfRange(pos, pos + len)
    pos += len
    return data
  }

  fun readString(): String {
    val len = checkedLength()
    val s = String(buf, pos, len, Charsets.UTF_8)
    pos += len
    return s
  }

  fun readInt32(): Int = readVarint().toInt()

  fun readFloat(): Float {
    if (pos + 4 > limit) throw SvgaParseException("truncated float")
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
      WIRE_LENGTH_DELIMITED -> skipBytes()
      WIRE_FIXED32 -> advance(4)
      else -> throw SvgaParseException("unknown wire type $wire")
    }
  }

  private fun skipBytes() {
    val len = checkedLength()
    pos += len
  }

  private fun advance(n: Int) {
    if (pos + n > limit) throw SvgaParseException("truncated fixed field")
    pos += n
  }

  /// Read a length-delimited length and validate it lies within the reader's
  /// window. Performed in Long arithmetic so a hostile varint near
  /// `Int.MAX_VALUE` cannot wrap `pos + len` to a small positive number and
  /// slip the bounds check, which would then trap with
  /// NegativeArraySizeException / StringIndexOutOfBoundsException further on.
  private fun checkedLength(): Int {
    val raw = readVarint()
    if (raw < 0 || raw > Int.MAX_VALUE.toLong()) {
      throw SvgaParseException("length-delimited overflow")
    }
    val len = raw.toInt()
    val end = pos.toLong() + len.toLong()
    if (end > limit.toLong()) throw SvgaParseException("length-delimited overflow")
    return len
  }
}

internal class SvgaParseException(message: String) : RuntimeException(message)
