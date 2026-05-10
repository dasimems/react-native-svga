package com.margelo.nitro.svga

import android.content.Context
import java.io.File
import java.util.concurrent.atomic.AtomicLong

internal object SvgaDiskCache {

  private const val SVGA_DIR = "svga_cache"
  private const val SOUND_DIR = "svga_sounds"
  private const val DEFAULT_LIMIT = 50L * 1024 * 1024
  private val maxBytes = AtomicLong(DEFAULT_LIMIT)
  private val writeLock = Any()

  fun setMaxBytes(bytes: Long) { maxBytes.set(bytes.coerceAtLeast(0L)) }
  fun getMaxBytes(): Long = maxBytes.get()

  fun svgaFile(ctx: Context, url: String): File = File(svgaDir(ctx), Hashing.sha256(url))
  fun soundFile(ctx: Context, key: String): File = File(soundDir(ctx), Hashing.sha256(key))

  fun isCached(ctx: Context, url: String): Boolean = svgaFile(ctx, url).isFile
  fun pathOrNull(ctx: Context, url: String): String? = svgaFile(ctx, url).takeIf { it.isFile }?.absolutePath

  // touch on read so frequently-replayed entries don't get evicted by a
  // single one-shot save. mtime drives eviction order in evictToMakeRoom.
  fun cachedFile(ctx: Context, url: String): File? {
    val f = svgaFile(ctx, url)
    if (!f.isFile) return null
    touch(f)
    return f
  }

  fun cachedSound(ctx: Context, key: String): File? {
    val f = soundFile(ctx, key)
    if (!f.isFile) return null
    touch(f)
    return f
  }

  fun saveSvga(ctx: Context, url: String, bytes: ByteArray): File {
    val file = svgaFile(ctx, url)
    synchronized(writeLock) {
      evictToMakeRoom(svgaDir(ctx), maxBytes.get(), bytes.size.toLong(), file)
      writeAtomic(file, bytes)
      touch(file)
    }
    return file
  }

  fun saveSound(ctx: Context, key: String, bytes: ByteArray): File {
    val file = soundFile(ctx, key)
    synchronized(writeLock) {
      evictToMakeRoom(soundDir(ctx), maxBytes.get(), bytes.size.toLong(), file)
      writeAtomic(file, bytes)
      touch(file)
    }
    return file
  }

  fun clearSvga(ctx: Context) { deleteAll(svgaDir(ctx)) }
  fun clearSounds(ctx: Context) { deleteAll(soundDir(ctx)) }

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

  private fun evictToMakeRoom(dir: File, limit: Long, incoming: Long, replacing: File) {
    val files = dir.listFiles()?.toMutableList() ?: return
    val existingReplacement = files.firstOrNull { it.absolutePath == replacing.absolutePath }
    val replacingBytes = existingReplacement?.length() ?: 0L
    var total = files.sumOf { it.length() } - replacingBytes
    if (total + incoming <= limit) return
    files.sortBy { it.lastModified() }
    for (f in files) {
      if (total + incoming <= limit) break
      if (f.absolutePath == replacing.absolutePath) continue
      total -= f.length()
      f.delete()
    }
  }
}
