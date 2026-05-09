package com.margelo.nitro.svga

import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.RectF
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater
import java.util.zip.ZipInputStream

internal object SvgaParser {

  private const val MAX_BUNDLE_BYTES = 64 * 1024 * 1024L
  private const val MAX_ENTRY_BYTES = 32 * 1024 * 1024L
  private const val MAX_INFLATED_BYTES = 64 * 1024 * 1024L
  private const val MAX_FRAMES = 100_000
  private const val MAX_SPRITES = 10_000
  private const val DEFAULT_FPS = 15

  fun parse(input: InputStream): SvgaEntity {
    val bytes = input.use { readAllBounded(it, MAX_BUNDLE_BYTES) }
    if (isZip(bytes)) return parseZip(bytes)
    if (isZlib(bytes)) return parseFromMovieBinary(inflateZlibStream(bytes))
    if (isGzip(bytes)) return parseFromMovieBinary(inflateGzipStream(bytes))
    if (looksLikeProtobuf(bytes)) return parseFromMovieBinary(bytes)
    throw SvgaParseException("unrecognised svga payload")
  }

  private fun isZip(bytes: ByteArray): Boolean {
    if (bytes.size < 4) return false
    return bytes[0] == 0x50.toByte() && bytes[1] == 0x4B.toByte() &&
      bytes[2] == 0x03.toByte() && bytes[3] == 0x04.toByte()
  }

  private fun isZlib(bytes: ByteArray): Boolean {
    if (bytes.size < 2) return false
    if (bytes[0] != 0x78.toByte()) return false
    val flg = bytes[1].toInt() and 0xFF
    val cmf = bytes[0].toInt() and 0xFF
    return ((cmf shl 8) or flg) % 31 == 0
  }

  private fun isGzip(bytes: ByteArray): Boolean {
    if (bytes.size < 3) return false
    return bytes[0] == 0x1F.toByte() && bytes[1] == 0x8B.toByte() && bytes[2] == 0x08.toByte()
  }

  private fun looksLikeProtobuf(bytes: ByteArray): Boolean {
    if (bytes.isEmpty()) return false
    val tag = bytes[0].toInt() and 0xFF
    val field = tag ushr 3
    val wire = tag and 0x7
    if (field == 0 || field > 5) return false
    return wire == ProtoReader.WIRE_VARINT ||
      wire == ProtoReader.WIRE_LENGTH_DELIMITED ||
      wire == ProtoReader.WIRE_FIXED32
  }

  private fun parseZip(bytes: ByteArray): SvgaEntity {
    var movieBinary: ByteArray? = null
    val imageBytes = LinkedHashMap<String, ByteArray>()
    val audioBytes = LinkedHashMap<String, ByteArray>()
    var totalBytes = 0L

    val zip = ZipInputStream(bytes.inputStream())
    try {
      while (true) {
        val entry = zip.nextEntry ?: break
        val name = entry.name
        if (!isSafeEntryName(name)) {
          zip.closeEntry()
          continue
        }
        val payload = readEntryBounded(zip)
        totalBytes += payload.size
        if (totalBytes > MAX_BUNDLE_BYTES) throw SvgaParseException("svga bundle exceeds size limit")

        when {
          name == "movie.binary" -> movieBinary = payload
          name.startsWith("images/") -> imageBytes[stripFolder(name, "images/")] = payload
          name.startsWith("audio/") -> audioBytes[stripFolder(name, "audio/")] = payload
        }
        zip.closeEntry()
      }
    } finally {
      zip.close()
    }

    val binary = movieBinary ?: throw SvgaParseException("movie.binary missing")
    val parsed = parseMovie(binary)
    for ((key, blob) in parsed.inlineBlobs) {
      if (imageBytes[key] == null && audioBytes[key] == null) imageBytes[key] = blob
    }
    val bitmaps = decodeBitmaps(imageBytes)
    return SvgaEntity(parsed.movie, bitmaps, audioBytes)
  }

  private fun parseFromMovieBinary(bytes: ByteArray): SvgaEntity {
    val parsed = parseMovie(bytes)
    val (imageBytes, audioBytes) = classifyBlobs(parsed)
    val bitmaps = decodeBitmaps(imageBytes)
    return SvgaEntity(parsed.movie, bitmaps, audioBytes)
  }

  private fun classifyBlobs(parsed: ParsedMovie): Pair<Map<String, ByteArray>, Map<String, ByteArray>> {
    val images = LinkedHashMap<String, ByteArray>()
    val audios = LinkedHashMap<String, ByteArray>()
    val imageKeys = parsed.movie.sprites.map { it.imageKey }.toHashSet()
    val audioKeys = parsed.movie.audios.map { it.audioKey }.toHashSet()
    for ((key, blob) in parsed.inlineBlobs) {
      when {
        audioKeys.contains(key) -> audios[key] = blob
        imageKeys.contains(key) -> images[key] = blob
        else -> images[key] = blob
      }
    }
    return images to audios
  }

  private fun isSafeEntryName(name: String): Boolean {
    if (name.isEmpty()) return false
    if (name.contains("..")) return false
    if (name.startsWith("/")) return false
    return true
  }

  private fun stripFolder(name: String, prefix: String): String {
    return name.removePrefix(prefix).substringBeforeLast(".")
  }

  private fun readAllBounded(input: InputStream, limit: Long): ByteArray {
    val buf = ByteArray(16 * 1024)
    val out = ByteArrayOutputStream()
    var total = 0L
    while (true) {
      val n = input.read(buf)
      if (n <= 0) break
      total += n
      if (total > limit) throw SvgaParseException("payload exceeds size limit")
      out.write(buf, 0, n)
    }
    return out.toByteArray()
  }

  private fun readEntryBounded(zip: ZipInputStream): ByteArray {
    val buf = ByteArray(8 * 1024)
    val out = ByteArrayOutputStream()
    var total = 0L
    while (true) {
      val n = zip.read(buf)
      if (n <= 0) break
      total += n
      if (total > MAX_ENTRY_BYTES) throw SvgaParseException("zip entry exceeds size limit")
      out.write(buf, 0, n)
    }
    return out.toByteArray()
  }

  private fun decodeBitmaps(source: Map<String, ByteArray>): Map<String, android.graphics.Bitmap> {
    val opts = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888 }
    val out = HashMap<String, android.graphics.Bitmap>(source.size)
    for ((key, blob) in source) {
      val bmp = BitmapFactory.decodeByteArray(blob, 0, blob.size, opts) ?: continue
      out[key] = bmp
    }
    return out
  }

  private data class ParsedMovie(val movie: MovieEntity, val inlineBlobs: Map<String, ByteArray>)

  private fun parseMovie(bytes: ByteArray): ParsedMovie {
    val reader = ProtoReader(bytes)
    var width = 0f
    var height = 0f
    var fps = DEFAULT_FPS
    var frames = 0
    val sprites = ArrayList<SpriteEntity>()
    val audios = ArrayList<AudioEntity>()
    val inlineBlobs = LinkedHashMap<String, ByteArray>()

    while (reader.hasMore()) {
      val tag = reader.readTag()
      when (tag.field) {
        1 -> reader.readString() // version, ignored
        2 -> {
          val params = parseParams(reader.readBytes())
          width = params.viewBoxWidth
          height = params.viewBoxHeight
          fps = params.fps
          frames = params.frames
        }
        3 -> {
          val entry = parseImageEntry(reader.readBytes())
          inlineBlobs[entry.key] = entry.value
        }
        4 -> {
          if (sprites.size >= MAX_SPRITES) throw SvgaParseException("too many sprites")
          sprites.add(parseSprite(reader.readBytes()))
        }
        5 -> audios.add(parseAudio(reader.readBytes()))
        else -> reader.skip(tag.wire)
      }
    }
    val movie = MovieEntity(width, height, fps, frames, sprites, audios)
    return ParsedMovie(movie, inlineBlobs)
  }

  private data class MovieParams(val viewBoxWidth: Float, val viewBoxHeight: Float, val fps: Int, val frames: Int)

  private fun parseParams(bytes: ByteArray): MovieParams {
    val r = ProtoReader(bytes)
    var width = 0f
    var height = 0f
    var fps = DEFAULT_FPS
    var frames = 0
    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> width = r.readFloat()
        2 -> height = r.readFloat()
        3 -> fps = r.readInt32().coerceAtLeast(1)
        4 -> {
          frames = r.readInt32()
          if (frames < 0 || frames > MAX_FRAMES) throw SvgaParseException("frame count out of range")
        }
        else -> r.skip(tag.wire)
      }
    }
    return MovieParams(width, height, fps, frames)
  }

  private data class ImageEntry(val key: String, val value: ByteArray)

  private fun parseImageEntry(bytes: ByteArray): ImageEntry {
    val r = ProtoReader(bytes)
    var key = ""
    var value = ByteArray(0)
    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> key = r.readString()
        2 -> value = r.readBytes()
        else -> r.skip(tag.wire)
      }
    }
    return ImageEntry(key, value)
  }

  private fun parseSprite(bytes: ByteArray): SpriteEntity {
    val r = ProtoReader(bytes)
    var imageKey = ""
    val frames = ArrayList<FrameEntity>()
    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> imageKey = r.readString()
        2 -> frames.add(parseFrame(r.readBytes()))
        else -> r.skip(tag.wire)
      }
    }
    return SpriteEntity(imageKey, frames)
  }

  private fun parseFrame(bytes: ByteArray): FrameEntity {
    val r = ProtoReader(bytes)
    var alpha = 0f
    var x = 0f; var y = 0f; var w = 0f; var h = 0f
    var a = 1f; var b = 0f; var c = 0f
    var d = 1f; var tx = 0f; var ty = 0f
    var hasContent = false

    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> {
          alpha = r.readFloat()
          hasContent = alpha > 0f
        }
        2 -> {
          val lr = ProtoReader(r.readBytes())
          while (lr.hasMore()) {
            val lt = lr.readTag()
            when (lt.field) {
              1 -> x = lr.readFloat()
              2 -> y = lr.readFloat()
              3 -> w = lr.readFloat()
              4 -> h = lr.readFloat()
              else -> lr.skip(lt.wire)
            }
          }
        }
        3 -> {
          val tr = ProtoReader(r.readBytes())
          while (tr.hasMore()) {
            val tt = tr.readTag()
            when (tt.field) {
              1 -> a = tr.readFloat()
              2 -> b = tr.readFloat()
              3 -> c = tr.readFloat()
              4 -> d = tr.readFloat()
              5 -> tx = tr.readFloat()
              6 -> ty = tr.readFloat()
              else -> tr.skip(tt.wire)
            }
          }
        }
        else -> r.skip(tag.wire)
      }
    }

    val matrix = Matrix()
    matrix.setValues(floatArrayOf(a, c, tx, b, d, ty, 0f, 0f, 1f))
    return FrameEntity(alpha, RectF(x, y, x + w, y + h), matrix, hasContent)
  }

  private fun parseAudio(bytes: ByteArray): AudioEntity {
    val r = ProtoReader(bytes)
    var key = ""
    var startFrame = 0
    var endFrame = 0
    var startTime = 0
    var totalTime = 0
    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> key = r.readString()
        2 -> startFrame = r.readInt32()
        3 -> endFrame = r.readInt32()
        4 -> startTime = r.readInt32()
        5 -> totalTime = r.readInt32()
        else -> r.skip(tag.wire)
      }
    }
    return AudioEntity(key, startFrame, endFrame, startTime, totalTime)
  }

  private fun inflateZlibStream(bytes: ByteArray): ByteArray {
    val inflater = Inflater()
    inflater.setInput(bytes)
    val out = ByteArrayOutputStream()
    val buf = ByteArray(64 * 1024)
    try {
      while (!inflater.finished()) {
        val n = inflater.inflate(buf)
        if (n == 0) {
          if (inflater.needsInput() || inflater.needsDictionary()) {
            throw SvgaParseException("truncated zlib stream")
          }
          break
        }
        out.write(buf, 0, n)
        if (out.size() > MAX_INFLATED_BYTES) {
          throw SvgaParseException("inflated payload exceeds size limit")
        }
      }
    } catch (e: java.util.zip.DataFormatException) {
      throw SvgaParseException("zlib decode error: ${e.message}")
    } finally {
      inflater.end()
    }
    return out.toByteArray()
  }

  private fun inflateGzipStream(bytes: ByteArray): ByteArray {
    GZIPInputStream(bytes.inputStream()).use { gz ->
      val out = ByteArrayOutputStream()
      val buf = ByteArray(64 * 1024)
      while (true) {
        val n = gz.read(buf)
        if (n <= 0) break
        out.write(buf, 0, n)
        if (out.size() > MAX_INFLATED_BYTES) {
          throw SvgaParseException("inflated payload exceeds size limit")
        }
      }
      return out.toByteArray()
    }
  }
}
