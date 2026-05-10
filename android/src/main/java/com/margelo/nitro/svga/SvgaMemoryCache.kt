package com.margelo.nitro.svga

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.util.LruCache

internal object SvgaMemoryCache {

  private const val DEFAULT_LIMIT_BYTES = 32L * 1024 * 1024
  private const val LOW_RAM_LIMIT_BYTES = 8L * 1024 * 1024
  private const val ENTRY_HEADROOM = 1024L

  @Volatile private var initialized = false
  @Volatile private var explicitLimit: Long? = null
  @Volatile private var cache: LruCache<String, SvgaEntity> = build(DEFAULT_LIMIT_BYTES)

  fun ensureInit(context: Context) {
    if (initialized) return
    synchronized(this) {
      if (initialized) return
      val app = context.applicationContext
      val am = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
      val limit = explicitLimit ?: defaultLimitFor(am)
      cache.evictAll()
      cache = build(limit)
      app.registerComponentCallbacks(memoryCallbacks)
      // Inform the parser so its bitmap downsampling matches device class.
      SvgaParser.configureForDeviceClass(
        memoryClassMb = am?.memoryClass ?: 256,
        isLowRamDevice = am?.isLowRamDevice == true
      )
      initialized = true
    }
  }

  fun setMaxBytes(bytes: Long) {
    val safe = bytes.coerceAtLeast(0L)
    synchronized(this) {
      explicitLimit = safe
      cache.evictAll()
      cache = build(safe)
    }
  }

  /// Returns a hit retained on behalf of the caller (+1). The caller is
  /// responsible for `release()`-ing when done. See `SvgaEntity` for the
  /// ownership convention.
  fun get(key: String): SvgaEntity? = cache[key]?.retain()

  fun put(key: String, entity: SvgaEntity) {
    if (cache.maxSize() <= 0) return
    // Cache holds its own +1; `entryRemoved` releases on eviction/replace.
    cache.put(key, entity.retain())
  }

  fun clear() { cache.evictAll() }

  fun trimToHalf() {
    val target = (cache.size() / 2).coerceAtLeast(0)
    cache.trimToSize(target)
  }

  private fun defaultLimitFor(am: ActivityManager?): Long {
    if (am == null) return DEFAULT_LIMIT_BYTES
    return when {
      am.isLowRamDevice -> LOW_RAM_LIMIT_BYTES
      am.memoryClass < 128 -> LOW_RAM_LIMIT_BYTES
      am.memoryClass < 256 -> DEFAULT_LIMIT_BYTES / 2
      else -> DEFAULT_LIMIT_BYTES
    }
  }

  private fun build(limit: Long): LruCache<String, SvgaEntity> {
    val cap = limit.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    return object : LruCache<String, SvgaEntity>(cap) {
      override fun sizeOf(key: String, value: SvgaEntity): Int {
        val raw = value.byteSize + ENTRY_HEADROOM
        return raw.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
      }

      // Released here covers every removal path: explicit put-replace,
      // LRU eviction, evictAll (clear/setMaxBytes), and trimToSize
      // (memory-pressure trims). When the last live holder also releases,
      // the entity recycles its bitmaps.
      override fun entryRemoved(
        evicted: Boolean,
        key: String,
        oldValue: SvgaEntity,
        newValue: SvgaEntity?
      ) {
        oldValue.release()
      }
    }
  }

  private val memoryCallbacks = object : ComponentCallbacks2 {
    override fun onTrimMemory(level: Int) {
      when {
        level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> clear()
        level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> trimToHalf()
        level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN -> trimToHalf()
        else -> Unit
      }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {}
    override fun onLowMemory() { clear() }
  }
}
