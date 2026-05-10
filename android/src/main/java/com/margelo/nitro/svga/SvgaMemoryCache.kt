package com.margelo.nitro.svga

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.util.LruCache
import java.util.concurrent.atomic.AtomicLong

internal object SvgaMemoryCache {

  private const val DEFAULT_LIMIT_BYTES = 32L * 1024 * 1024
  private const val LOW_RAM_LIMIT_BYTES = 8L * 1024 * 1024
  private const val ENTRY_HEADROOM = 1024L

  @Volatile private var initialized = false
  @Volatile private var explicitLimit: Long? = null
  // 0 disables — entries live until LRU evicts them. When set, hits older
  // than `maxAgeMs` are removed on access (treated as a miss). Atomic so
  // concurrent loaders don't tear the read.
  private val maxAgeMs = AtomicLong(0L)
  // Wall-clock storedAt timestamps for TTL filtering. Bumped on every
  // `put`, dropped on remove via `entryRemoved`. Synchronized on the
  // map's monitor for visibility — small map, fast updates.
  private val storedAt = HashMap<String, Long>()
  // Thread-local stash for evicted entities so `entryRemoved` (which fires
  // synchronously inside a held `synchronized(storedAt)` block during
  // `cache.remove`/`cache.put`) does NOT recycle multi-MB bitmaps while we
  // hold the monitor. Each get/put/clear creates a stash, lets entryRemoved
  // append to it, then drains it AFTER exiting the synchronized block. If
  // the stash is null (entryRemoved fired from outside our serialised
  // critical sections — e.g. trimToSize from a memory-pressure callback),
  // we fall back to releasing inline.
  private val pendingReleases = ThreadLocal<ArrayList<SvgaEntity>?>()
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
    // Match the global `storedAt → this → LruCache` lock order even though
    // a fresh cache is empty and resize won't fire entryRemoved on first
    // run — defensive against future paths that might land here after the
    // cache has entries (e.g. lazy re-init).
    synchronized(storedAt) {
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
  }

  fun setMaxBytes(bytes: Long) {
    val safe = bytes.coerceAtLeast(0L)
    // Acquire `storedAt` BEFORE the cache.resize call. Resize can trigger
    // entryRemoved (if shrinking), which itself acquires `storedAt`; if a
    // concurrent get/put on another thread is holding `storedAt` waiting
    // for LruCache's internal lock, and we held only `this` here, we'd
    // deadlock — get's storedAt → LruCache, ours LruCache → storedAt.
    // Establishing storedAt → LruCache as the global order on every
    // operation that may fire entryRemoved keeps the graph acyclic.
    withDeferredReleases {
      synchronized(storedAt) {
        synchronized(this) {
          explicitLimit = safe
          cache.resize(safe.toCapacity())
        }
      }
    }
  }

  fun setMaxAgeMs(ms: Long) { maxAgeMs.set(ms.coerceAtLeast(0L)) }

  private fun Long.toCapacity(): Int = coerceAtMost(Int.MAX_VALUE.toLong()).coerceAtLeast(1L).toInt()

  /// Returns a hit retained on behalf of the caller (+1). The caller is
  /// responsible for `release()`-ing when done. Stale entries (TTL exceeded)
  /// are removed on access and treated as misses — a fresh load through
  /// SvgaSourceLoader replaces them with a freshly-stamped entry.
  ///
  /// The `synchronized(storedAt)` block spans the staleness decision AND the
  /// `cache.remove` call so a concurrent `put` (which also takes this lock)
  /// can never race in a fresh entity between our check and our removal.
  /// Bitmap recycling triggered by `cache.remove`/`cache.put` is deferred
  /// via `pendingReleases` so we don't hold the monitor across a multi-MB
  /// JNI-heavy `Bitmap.recycle()` chain.
  fun get(key: String): SvgaEntity? {
    val ttl = maxAgeMs.get()
    if (ttl > 0L) {
      val hit = withDeferredReleases {
        synchronized(storedAt) {
          val stored = storedAt[key]
          if (stored != null && System.currentTimeMillis() - stored > ttl) {
            cache.remove(key)
            null
          } else {
            cache[key]?.retain()
          }
        }
      }
      return hit
    }
    return cache[key]?.retain()
  }

  /// Both the storedAt timestamp write and the `cache.put` happen under the
  /// same monitor so `get` (which holds the same monitor while checking
  /// staleness) can never observe a half-written state — either both the
  /// fresh stamp and fresh entity are visible, or neither is. Releases
  /// triggered by an LRU-trim during this put are deferred outside the lock.
  fun put(key: String, entity: SvgaEntity) {
    withDeferredReleases {
      synchronized(storedAt) {
        storedAt[key] = System.currentTimeMillis()
        // Cache holds its own +1; `entryRemoved` releases on eviction/replace.
        // If the caller's `byteSize` exceeds `cache.maxSize()`, LruCache's
        // post-put trim evicts the new entry immediately and `entryRemoved`
        // balances our `retain()` — net effect is a no-op, which is what
        // we want for an over-sized payload.
        cache.put(key, entity.retain())
      }
    }
  }

  fun clear() {
    withDeferredReleases {
      synchronized(storedAt) {
        cache.evictAll()
        storedAt.clear()
      }
    }
  }

  /// Memory-pressure trim. Acquires `storedAt` first to match the global
  /// `storedAt → LruCache lock` order established by `get`/`put`/`clear`/
  /// `setMaxBytes`; without this, a concurrent `get` holding `storedAt` and
  /// awaiting LruCache's internal lock could deadlock against our
  /// `cache.trimToSize` (which holds LruCache and fires entryRemoved
  /// requesting `storedAt`). Bitmap recycles are deferred outside the lock.
  fun trimToHalf() {
    withDeferredReleases {
      synchronized(storedAt) {
        val target = (cache.size() / 2).coerceAtLeast(0)
        cache.trimToSize(target)
      }
    }
  }

  /// Wrap a critical section so any `entryRemoved` that fires inside it
  /// stashes the evicted entity instead of recycling synchronously. The
  /// stash drains AFTER `block` returns, with no lock held — bitmap recycle
  /// (and any future expensive teardown) runs unblocked. The `try/finally`
  /// guarantees we drain even on exception.
  private inline fun <T> withDeferredReleases(block: () -> T): T {
    val list = ArrayList<SvgaEntity>()
    pendingReleases.set(list)
    try {
      return block()
    } finally {
      pendingReleases.set(null)
      for (e in list) e.release()
    }
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
      // the entity recycles its bitmaps. Drop the storedAt entry too so
      // we don't leak entries in the TTL map after the cache forgets them.
      //
      // Defer the actual `release()` to after the surrounding critical
      // section exits — `Bitmap.recycle()` is JNI-heavy and serialising
      // it under our monitor would block other gets/puts on unrelated
      // keys. If we're called outside one of our wrapped sections (e.g.
      // a low-RAM `evictAll` from a system callback), the stash is null
      // and we recycle inline as before.
      override fun entryRemoved(
        evicted: Boolean,
        key: String,
        oldValue: SvgaEntity,
        newValue: SvgaEntity?
      ) {
        val stash = pendingReleases.get()
        if (stash != null) stash.add(oldValue) else oldValue.release()
        // Only erase storedAt when the slot is actually vacated (no
        // newValue). A `put` that replaces an entry already wrote the
        // fresh storedAt before this callback fires, and we mustn't
        // clobber it here.
        if (newValue == null) {
          // Re-entrant acquire — when entryRemoved fires inside one of our
          // wrapped sections (get/put/clear/trim/setMaxBytes/ensureInit),
          // the calling thread already holds `storedAt`. Java `synchronized`
          // is reentrant on the same monitor, so this is safe. If `storedAt`
          // ever changes to a non-reentrant lock primitive, this site needs
          // to switch to a "skip if already held" pattern.
          synchronized(storedAt) { storedAt.remove(key) }
        }
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
