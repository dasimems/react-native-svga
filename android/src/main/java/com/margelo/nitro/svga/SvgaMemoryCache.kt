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
  // `val` (never reassigned) so concurrent readers in `get`/`put`/`clear`/
  // `trimToHalf` can't race with a `setMaxBytes` swap. Capacity is mutated
  // in place via `LruCache.resize` instead. A reassignment-based design
  // would let a reader hold a reference to the old cache and observe a
  // retained entity whose bitmaps `evictAll()` just recycled — `retain()`
  // happily increments the refcount but the bitmaps are gone, leaving the
  // player to silently skip-draw via the `bitmap.isRecycled` defence in
  // SvgaPlayerView.
  private val cache: LruCache<String, SvgaEntity> = build(DEFAULT_LIMIT_BYTES)

  fun ensureInit(context: Context) {
    if (initialized) return
    synchronized(this) {
      if (initialized) return
      val app = context.applicationContext
      val am = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
      val limit = explicitLimit ?: defaultLimitFor(am)
      cache.resize(limit.toCapacity())
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
      // resize() trims in place to the new capacity (releasing oldest
      // entries via entryRemoved → release()) without ever swapping the
      // cache instance. Readers holding the same `cache` reference stay
      // valid throughout.
      cache.resize(safe.toCapacity())
    }
  }

  private fun Long.toCapacity(): Int = coerceAtMost(Int.MAX_VALUE.toLong()).coerceAtLeast(1L).toInt()

  /// Returns a hit retained on behalf of the caller (+1). The caller is
  /// responsible for `release()`-ing when done. See `SvgaEntity` for the
  /// ownership convention.
  fun get(key: String): SvgaEntity? = cache[key]?.retain()

  fun put(key: String, entity: SvgaEntity) {
    // Cache holds its own +1; `entryRemoved` releases on eviction/replace.
    // If the caller's `byteSize` exceeds `cache.maxSize()`, LruCache's
    // post-put trim evicts the new entry immediately and `entryRemoved`
    // balances our `retain()` — net effect is a no-op, which is what
    // we want for an over-sized payload.
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
    return object : LruCache<String, SvgaEntity>(limit.toCapacity()) {
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
