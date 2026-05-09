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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal object SvgaSourceLoader {

  private const val CONNECT_TIMEOUT_MS = 15_000
  private const val READ_TIMEOUT_MS = 30_000
  private const val MAX_DOWNLOAD_BYTES = 64L * 1024 * 1024

  class SourceException(message: String, cause: Throwable? = null) : IOException(message, cause)

  private val inFlightEntities = ConcurrentHashMap<String, CompletableDeferred<SvgaEntity>>()

  suspend fun loadEntity(ctx: Context, source: String): SvgaEntity {
    SvgaMemoryCache.get(source)?.let { return it }

    val deferred = CompletableDeferred<SvgaEntity>()
    val existing = inFlightEntities.putIfAbsent(source, deferred)
    if (existing != null) {
      deferred.cancel()
      return existing.await()
    }

    try {
      val parsed = withContext(Dispatchers.IO) { loadEntityBlocking(ctx, source) }
      SvgaMemoryCache.put(source, parsed)
      deferred.complete(parsed)
      return parsed
    } catch (e: Throwable) {
      deferred.completeExceptionally(e)
      throw e
    } finally {
      inFlightEntities.remove(source)
    }
  }

  private fun loadEntityBlocking(ctx: Context, source: String): SvgaEntity {
    val stream = openStream(ctx, source)
    return stream.use { SvgaParser.parse(it) }
  }

  fun preloadRemote(ctx: Context, url: String): File {
    val existing = SvgaDiskCache.cachedFile(ctx, url)
    if (existing != null) return existing
    val bytes = downloadBytes(url)
    return SvgaDiskCache.saveSvga(ctx, url, bytes)
  }

  fun loadSoundBytes(ctx: Context, key: String, url: String): File {
    val existing = SvgaDiskCache.soundFile(ctx, key).takeIf { it.isFile }
    if (existing != null) return existing
    val resolved = UrlValidator.resolve(url) ?: throw SourceException("invalid sound url: $url")
    if (resolved.kind == UrlValidator.Kind.LOCAL_FILE) return File(resolved.value)
    if (resolved.kind == UrlValidator.Kind.BUNDLED_ASSET) {
      val bytes = readAssetBytes(ctx, resolved.value)
      return SvgaDiskCache.saveSound(ctx, key, bytes)
    }
    val bytes = downloadBytes(resolved.value)
    return SvgaDiskCache.saveSound(ctx, key, bytes)
  }

  private fun openStream(ctx: Context, source: String): InputStream {
    val resolved = UrlValidator.resolve(source) ?: throw SourceException("invalid source: $source")
    if (resolved.kind == UrlValidator.Kind.LOCAL_FILE) return File(resolved.value).inputStream()
    if (resolved.kind == UrlValidator.Kind.BUNDLED_ASSET) return ctx.assets.open(resolved.value)
    val cached = SvgaDiskCache.cachedFile(ctx, resolved.value)
    if (cached != null) return cached.inputStream()
    val bytes = downloadBytes(resolved.value)
    val saved = SvgaDiskCache.saveSvga(ctx, resolved.value, bytes)
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
      if (code !in 200..299) throw SourceException("http $code for $url")
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
