package com.margelo.nitro.svga

import android.content.Context
import java.io.File
import java.util.concurrent.atomic.AtomicLong

internal object SvgaDiskCache {

  private const val SVGA_DIR = "svga_cache"
  private const val SOUND_DIR = "svga_sounds"
  private const val DEFAULT_LIMIT = 50L * 1024 * 1024
  private val maxBytes = AtomicLong(DEFAULT_LIMIT)

  fun setMaxBytes(bytes: Long) { maxBytes.set(bytes.coerceAtLeast(0L)) }
  fun getMaxBytes(): Long = maxBytes.get()

  fun svgaFile(ctx: Context, url: String): File = File(svgaDir(ctx), Hashing.sha256(url))
  fun soundFile(ctx: Context, key: String): File = File(soundDir(ctx), Hashing.sha256(key))

  fun isCached(ctx: Context, url: String): Boolean = svgaFile(ctx, url).isFile
  fun pathOrNull(ctx: Context, url: String): String? = svgaFile(ctx, url).takeIf { it.isFile }?.absolutePath
  fun cachedFile(ctx: Context, url: String): File? = svgaFile(ctx, url).takeIf { it.isFile }

  fun saveSvga(ctx: Context, url: String, bytes: ByteArray): File {
    val file = svgaFile(ctx, url)
    writeAtomic(file, bytes)
    touch(file)
    evict(svgaDir(ctx), maxBytes.get())
    return file
  }

  fun saveSound(ctx: Context, key: String, bytes: ByteArray): File {
    val file = soundFile(ctx, key)
    writeAtomic(file, bytes)
    touch(file)
    return file
  }

  fun clearSvga(ctx: Context) { deleteAll(svgaDir(ctx)) }

  fun totalSvgaBytes(ctx: Context): Long {
    return svgaDir(ctx).listFiles()?.sumOf { it.length() } ?: 0L
  }

  private fun svgaDir(ctx: Context): File = ensureDir(File(ctx.cacheDir, SVGA_DIR))
  private fun soundDir(ctx: Context): File = ensureDir(File(ctx.cacheDir, SOUND_DIR))

  private fun ensureDir(dir: File): File {
    if (!dir.exists()) dir.mkdirs()
    return dir
  }

  private fun deleteAll(dir: File) {
    dir.listFiles()?.forEach { it.delete() }
  }

  private fun writeAtomic(target: File, bytes: ByteArray) {
    val tmp = File(target.parentFile, target.name + ".tmp")
    tmp.writeBytes(bytes)
    if (!tmp.renameTo(target)) {
      target.writeBytes(bytes)
      tmp.delete()
    }
  }

  private fun touch(file: File) { file.setLastModified(System.currentTimeMillis()) }

  private fun evict(dir: File, limit: Long) {
    val files = dir.listFiles()?.toMutableList() ?: return
    var total = files.sumOf { it.length() }
    if (total <= limit) return
    files.sortBy { it.lastModified() }
    for (f in files) {
      if (total <= limit) break
      total -= f.length()
      f.delete()
    }
  }
}
