package com.margelo.nitro.svga

import android.util.LruCache

internal object SvgaMemoryCache {

  private const val DEFAULT_LIMIT_BYTES = 32L * 1024 * 1024
  private const val ENTRY_HEADROOM = 1024L

  @Volatile
  private var cache: LruCache<String, SvgaEntity> = build(DEFAULT_LIMIT_BYTES)

  fun setMaxBytes(bytes: Long) {
    val safe = bytes.coerceAtLeast(0L)
    synchronized(this) {
      cache.evictAll()
      cache = build(safe)
    }
  }

  fun get(key: String): SvgaEntity? = cache[key]

  fun put(key: String, entity: SvgaEntity) {
    if (cache.maxSize() <= 0) return
    cache.put(key, entity)
  }

  fun clear() { cache.evictAll() }

  private fun build(limit: Long): LruCache<String, SvgaEntity> {
    val cap = limit.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    return object : LruCache<String, SvgaEntity>(cap) {
      override fun sizeOf(key: String, value: SvgaEntity): Int {
        val raw = value.byteSize + ENTRY_HEADROOM
        return raw.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
      }
    }
  }
}
