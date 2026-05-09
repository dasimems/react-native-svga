package com.margelo.nitro.svga

import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.RectF
import java.io.InputStream
import java.util.zip.ZipInputStream

internal object SvgaParser {

  private const val MAX_BUNDLE_BYTES = 64 * 1024 * 1024L
  private const val MAX_ENTRY_BYTES = 32 * 1024 * 1024L
  private const val MAX_FRAMES = 100_000
  private const val MAX_SPRITES = 10_000
  private const val DEFAULT_FPS = 15

  fun parse(input: InputStream): SvgaEntity {
    val zip = ZipInputStream(input)
    var movieBinary: ByteArray? = null
    val imageData = LinkedHashMap<String, ByteArray>()
    val audioData = LinkedHashMap<String, ByteArray>()
    var totalBytes = 0L

    try {
      while (true) {
        val entry = zip.nextEntry ?: break
        val name = entry.name

        if (!isSafeEntryName(name)) {
          zip.closeEntry()
          continue
        }

        val bytes = readEntryBounded(zip)
        totalBytes += bytes.size
        if (totalBytes > MAX_BUNDLE_BYTES) throw SvgaParseException("svga bundle exceeds size limit")

        when {
          name == "movie.binary" -> movieBinary = bytes
          name.startsWith("images/") -> imageData[stripFolder(name, "images/")] = bytes
          name.startsWith("audio/") -> audioData[stripFolder(name, "audio/")] = bytes
        }
        zip.closeEntry()
      }
    } finally {
      zip.close()
    }

    val binary = movieBinary ?: throw SvgaParseException("movie.binary missing")
    val movie = parseMovie(binary)
    val bitmaps = decodeBitmaps(imageData)
    return SvgaEntity(movie, bitmaps, audioData)
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

  private fun readEntryBounded(zip: ZipInputStream): ByteArray {
    val buffer = ByteArray(8 * 1024)
    val out = java.io.ByteArrayOutputStream()
    var total = 0L
    while (true) {
      val n = zip.read(buffer)
      if (n <= 0) break
      total += n
      if (total > MAX_ENTRY_BYTES) throw SvgaParseException("zip entry exceeds size limit")
      out.write(buffer, 0, n)
    }
    return out.toByteArray()
  }

  private fun decodeBitmaps(imageData: Map<String, ByteArray>): Map<String, android.graphics.Bitmap> {
    val opts = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888 }
    val out = HashMap<String, android.graphics.Bitmap>(imageData.size)
    for ((key, bytes) in imageData) {
      val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: continue
      out[key] = bmp
    }
    return out
  }

  private fun parseMovie(bytes: ByteArray): MovieEntity {
    val reader = ProtoReader(bytes)
    var width = 0f
    var height = 0f
    var fps = DEFAULT_FPS
    var frames = 0
    val sprites = ArrayList<SpriteEntity>()
    val audios = ArrayList<AudioEntity>()

    while (reader.hasMore()) {
      val tag = reader.readTag()
      when (tag.field) {
        1 -> {
          val params = parseParams(reader.readBytes())
          width = params.width
          height = params.height
          fps = params.fps
          frames = params.frames
        }
        3 -> {
          if (sprites.size >= MAX_SPRITES) throw SvgaParseException("too many sprites")
          sprites.add(parseSprite(reader.readBytes()))
        }
        4 -> audios.add(parseAudio(reader.readBytes()))
        else -> reader.skip(tag.wire)
      }
    }
    return MovieEntity(width, height, fps, frames, sprites, audios)
  }

  private data class MovieParams(val width: Float, val height: Float, val fps: Int, val frames: Int)

  private fun parseParams(bytes: ByteArray): MovieParams {
    val r = ProtoReader(bytes)
    var width = 0f
    var height = 0f
    var fps = DEFAULT_FPS
    var frames = 0
    while (r.hasMore()) {
      val tag = r.readTag()
      when (tag.field) {
        1 -> width = r.readInt32().toFloat()
        2 -> height = r.readInt32().toFloat()
        3 -> {
          frames = r.readInt32()
          if (frames < 0 || frames > MAX_FRAMES) throw SvgaParseException("frame count out of range")
        }
        4 -> fps = r.readInt32().coerceAtLeast(1)
        else -> r.skip(tag.wire)
      }
    }
    return MovieParams(width, height, fps, frames)
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
}
