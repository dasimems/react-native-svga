package com.margelo.nitro.svga

import android.content.Context
import java.io.File
import java.util.concurrent.atomic.AtomicLong

internal object SvgaDiskCache {

  private const val SVGA_DIR = "svga_cache"
  private const val SOUND_DIR = "svga_sounds"
  private const val DEFAULT_LIMIT = 50L * 1024 * 1024
  private val maxBytes = AtomicLong(DEFAULT_LIMIT)
  /// Max age (TTL) in ms. 0 disables — entries live until LRU evicts them.
  /// When set, reads of entries older than `maxAgeMs` return null (treated
  /// as a miss) and `evictExpired` walks the dir to reap them.
  private val maxAgeMs = AtomicLong(0L)
  private val writeLock = Any()

  fun setMaxBytes(bytes: Long) { maxBytes.set(bytes.coerceAtLeast(0L)) }
  fun getMaxBytes(): Long = maxBytes.get()

  fun setMaxAgeMs(ms: Long) { maxAgeMs.set(ms.coerceAtLeast(0L)) }
  fun getMaxAgeMs(): Long = maxAgeMs.get()

  /// SVGA cache slot for a `cacheKey`. We hash the key (not the URL) so
  /// callers passing an explicit cacheKey decoupled from the download URL
  /// get a stable, content-addressable file path.
  fun svgaFile(ctx: Context, cacheKey: String): File = File(svgaDir(ctx), Hashing.sha256(cacheKey))
  fun soundFile(ctx: Context, key: String): File = File(soundDir(ctx), Hashing.sha256(key))

  fun isCached(ctx: Context, cacheKey: String): Boolean {
    val f = svgaFile(ctx, cacheKey)
    if (!f.isFile) return false
    return !isExpired(f)
  }

  fun pathOrNull(ctx: Context, cacheKey: String): String? {
    val f = svgaFile(ctx, cacheKey)
    if (!f.isFile) return null
    if (isExpired(f)) return null
    return f.absolutePath
  }

  // touch on read so frequently-replayed entries don't get evicted by a
  // single one-shot save. mtime drives both LRU eviction order in
  // evictToMakeRoom AND the TTL check below — so an expired-but-touched
  // entry would silently extend its life. We deliberately do NOT touch
  // here when the entry has expired; the caller treats it as a miss and
  // re-downloads, which writes a fresh mtime via `saveSvga`.
  fun cachedFile(ctx: Context, cacheKey: String): File? {
    val f = svgaFile(ctx, cacheKey)
    if (!f.isFile) return null
    if (isExpired(f)) return null
    touch(f)
    return f
  }

  fun cachedSound(ctx: Context, key: String): File? {
    val f = soundFile(ctx, key)
    if (!f.isFile) return null
    if (isExpired(f)) return null
    touch(f)
    return f
  }

  fun saveSvga(ctx: Context, cacheKey: String, bytes: ByteArray): File {
    val file = svgaFile(ctx, cacheKey)
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

  fun totalSvgaCount(ctx: Context): Int {
    // .tmp siblings are atomic-write scratch — exclude so the count matches
    // what callers can actually read back via cachedFile().
    return svgaDir(ctx).listFiles()?.count { !it.name.endsWith(".tmp") } ?: 0
  }

  /// Walk the SVGA cache dir and remove every entry older than `maxAgeMs`.
  /// Returns the number of entries removed. No-op when TTL is disabled.
  ///
  /// Both the dir snapshot AND the per-file `lastModified()` reads run
  /// inside `writeLock` so a concurrent `saveSvga` (also under `writeLock`)
  /// can't slip a fresh write between listing and deletion. Without this,
  /// we could delete a freshly-renamed file because our snapshot was taken
  /// before the rename landed.
  fun evictExpired(ctx: Context): Int {
    val ttl = maxAgeMs.get()
    if (ttl <= 0L) return 0
    var removed = 0
    synchronized(writeLock) {
      val files = svgaDir(ctx).listFiles() ?: return 0
      val now = System.currentTimeMillis()
      for (f in files) {
        if (f.name.endsWith(".tmp")) continue
        val age = now - f.lastModified()
        if (age <= ttl) continue
        if (f.delete()) removed += 1
      }
    }
    return removed
  }

  private fun isExpired(file: File): Boolean {
    val ttl = maxAgeMs.get()
    if (ttl <= 0L) return false
    val mtime = file.lastModified()
    if (mtime <= 0L) return false
    return System.currentTimeMillis() - mtime > ttl
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
    try {
      tmp.writeBytes(bytes)
      if (tmp.renameTo(target)) return
      // Atomic rename failed (cross-volume? destination locked?). The
      // previous fallback wrote directly to `target` non-atomically, so a
      // crash mid-write would leave a partial file that subsequent reads
      // would silently load and crash on. Fail closed instead and surface
      // the failure to the caller so we don't poison the cache with a
      // truncated entry.
      tmp.delete()
      target.delete()
      throw java.io.IOException("atomic rename failed for ${target.absolutePath}")
    } catch (t: Throwable) {
      tmp.delete()
      throw t
    }
  }

  private fun touch(file: File) { file.setLastModified(System.currentTimeMillis()) }

  private fun evictToMakeRoom(dir: File, limit: Long, incoming: Long, replacing: File) {
    // .tmp siblings are atomic-write scratch — exclude so the budget
    // calculation tracks real entries only.
    val files = dir.listFiles()?.filter { !it.name.endsWith(".tmp") }?.toMutableList() ?: return
    val existingReplacement = files.firstOrNull { it.absolutePath == replacing.absolutePath }
    val replacingBytes = existingReplacement?.length() ?: 0L
    var total = files.sumOf { it.length() } - replacingBytes
    if (total + incoming <= limit) return
    // LRU: oldest mtime first so they evict before recent entries.
    files.sortBy { it.lastModified() }
    for (f in files) {
      if (total + incoming <= limit) break
      if (f.absolutePath == replacing.absolutePath) continue
      total -= f.length()
      f.delete()
    }
  }
}
