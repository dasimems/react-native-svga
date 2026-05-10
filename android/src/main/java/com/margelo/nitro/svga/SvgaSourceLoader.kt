package com.margelo.nitro.svga

import android.content.Context
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext

internal object SvgaSourceLoader {

  private const val CONNECT_TIMEOUT_MS = 15_000
  private const val READ_TIMEOUT_MS = 30_000
  private const val MAX_DOWNLOAD_BYTES = 64L * 1024 * 1024

  class SourceException(message: String, cause: Throwable? = null) : IOException(message, cause)

  // Dedup by cache key — two concurrent loads for the same content
  // (same key) coalesce into one fetch even if they passed slightly
  // different signed URLs. Different cacheKeys never coalesce: rotating
  // the key means "new identity", which is the whole point of the API.
  private val inFlightEntities = ConcurrentHashMap<String, CompletableDeferred<SvgaEntity>>()

  // Loads run on a SupervisorJob-backed scope decoupled from any single
  // caller's coroutine. Otherwise, if the leader caller (the one that
  // started the load) gets cancelled by its parent (e.g. HybridSvga.dispose),
  // the catch arm would propagate the CancellationException to the shared
  // deferred, poisoning every other awaiter who was reusing the in-flight
  // load via the dedup table.
  private val loaderScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

  /// Effective cache key for a source — falls back to the source itself when
  /// the caller didn't supply one. Keeps memory/disk caches keyed identically
  /// to pre-cacheKey behaviour for string-only callers.
  private fun resolveKey(source: String, explicit: String?): String {
    if (explicit != null && explicit.isNotEmpty()) return explicit
    return source
  }

  suspend fun loadEntity(ctx: Context, source: String, cacheKey: String? = null): SvgaEntity {
    val key = resolveKey(source, cacheKey)
    // SvgaMemoryCache.get returns the entity already retained on our behalf
    // (+1). Caller owns that ref and must release.
    SvgaMemoryCache.get(key)?.let { return it }

    val deferred = CompletableDeferred<SvgaEntity>()
    val existing = inFlightEntities.putIfAbsent(key, deferred)
    if (existing != null) {
      // Lost the leader race; await the leader's value and retain on
      // hand-off so each awaiter owns its own +1.
      return existing.await().retain()
    }

    loaderScope.launch {
      try {
        val parsed = runInterruptible { loadEntityBlocking(ctx, source, key) }
        // Cache takes its own +1. Awaiters retain on hand-off below; if no
        // awaiter survives (cancellation), the cache still has its retain
        // and the bitmaps stay alive until eviction.
        SvgaMemoryCache.put(key, parsed)
        deferred.complete(parsed)
      } catch (e: Throwable) {
        deferred.completeExceptionally(e)
      } finally {
        inFlightEntities.remove(key)
      }
    }

    return deferred.await().retain()
  }

  private fun loadEntityBlocking(ctx: Context, source: String, cacheKey: String): SvgaEntity {
    val stream = openStream(ctx, source, cacheKey)
    return stream.use { SvgaParser.parse(it) }
  }

  private fun sanitizeForLog(url: String): String {
    val q = url.indexOf('?')
    return if (q < 0) url else url.substring(0, q)
  }

  suspend fun preloadRemote(ctx: Context, url: String, cacheKey: String? = null): File {
    val key = resolveKey(url, cacheKey)
    return withContext(Dispatchers.IO) {
      runInterruptible { preloadRemoteBlocking(ctx, url, key) }
    }
  }

  private fun preloadRemoteBlocking(ctx: Context, url: String, cacheKey: String): File {
    val existing = SvgaDiskCache.cachedFile(ctx, cacheKey)
    if (existing != null) return existing
    val bytes = downloadBytes(url)
    return SvgaDiskCache.saveSvga(ctx, cacheKey, bytes)
  }

  suspend fun loadSoundBytes(ctx: Context, url: String): File {
    return withContext(Dispatchers.IO) {
      runInterruptible { loadSoundBytesBlocking(ctx, url) }
    }
  }

  private fun loadSoundBytesBlocking(ctx: Context, url: String): File {
    val resolved = UrlValidator.resolve(url) ?: throw SourceException("invalid sound url")
    if (resolved.kind == UrlValidator.Kind.LOCAL_FILE) return File(resolved.value)
    // Disk-cache key is the URL (content-addressable). Keying by the user
    // play-handle would make the cache stale when the same handle is
    // reassigned to a different URL.
    val cacheKey = resolved.value
    val existing = SvgaDiskCache.cachedSound(ctx, cacheKey)
    if (existing != null) return existing
    if (resolved.kind == UrlValidator.Kind.BUNDLED_ASSET) {
      val bytes = readAssetBytes(ctx, resolved.value)
      return SvgaDiskCache.saveSound(ctx, cacheKey, bytes)
    }
    val bytes = downloadBytes(resolved.value)
    return SvgaDiskCache.saveSound(ctx, cacheKey, bytes)
  }

  private fun openStream(ctx: Context, source: String, cacheKey: String): InputStream {
    val resolved = UrlValidator.resolve(source) ?: throw SourceException("invalid source")
    if (resolved.kind == UrlValidator.Kind.LOCAL_FILE) return File(resolved.value).inputStream()
    if (resolved.kind == UrlValidator.Kind.BUNDLED_ASSET) return ctx.assets.open(resolved.value)
    val cached = SvgaDiskCache.cachedFile(ctx, cacheKey)
    if (cached != null) return cached.inputStream()
    val bytes = downloadBytes(resolved.value)
    val saved = SvgaDiskCache.saveSvga(ctx, cacheKey, bytes)
    return saved.inputStream()
  }

  private fun readAssetBytes(ctx: Context, name: String): ByteArray {
    return ctx.assets.open(name).use { it.readBytes() }
  }

  private fun downloadBytes(url: String): ByteArray {
    val conn = URL(url).openConnection() as HttpURLConnection
    conn.connectTimeout = CONNECT_TIMEOUT_MS
    conn.readTimeout = READ_TIMEOUT_MS
    conn.instanceFollowRedirects = true
    conn.requestMethod = "GET"
    if (conn is HttpsURLConnection) {
      // default trust manager + hostname verifier - explicit assignment for clarity
      conn.hostnameVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
    }
    try {
      val code = conn.responseCode
      if (code !in 200..299) throw SourceException("http $code for ${sanitizeForLog(url)}")
      val declared = conn.contentLengthLong
      if (declared > MAX_DOWNLOAD_BYTES) throw SourceException("payload exceeds size limit")
      return conn.inputStream.use { readBounded(it, MAX_DOWNLOAD_BYTES) }
    } finally {
      conn.disconnect()
    }
  }

  private fun readBounded(input: InputStream, limit: Long): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(16 * 1024)
    var total = 0L
    while (true) {
      val n = input.read(buf)
      if (n <= 0) break
      total += n
      if (total > limit) throw SourceException("payload exceeds size limit")
      out.write(buf, 0, n)
    }
    return out.toByteArray()
  }
}
