package com.margelo.nitro.svga

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

@DoNotStrip
@Keep
class HybridSvgaManager : HybridSvgaManagerSpec() {

  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
  private val preloadGate = Semaphore(MAX_CONCURRENT_PRELOADS)
  private val context get() = NitroModules.applicationContext
    ?: throw IllegalStateException("Application context unavailable")
  private val sounds = SvgaSoundLibrary(context)

  init { SvgaMemoryCache.ensureInit(context) }

  override fun preload(urls: Array<String>): Promise<Unit> {
    return Promise.async(scope) {
      coroutineScope {
        urls.map { source ->
          async { preloadGate.withPermit { preloadOne(source) } }
        }.awaitAll()
      }
      Unit
    }
  }

  override fun preloadDecoded(urls: Array<String>): Promise<Unit> {
    return Promise.async(scope) {
      coroutineScope {
        urls.map { source ->
          async {
            preloadGate.withPermit {
              try {
                SvgaSourceLoader.loadEntity(context, source)
              } catch (e: CancellationException) {
                throw e
              } catch (_: Throwable) {
                // best-effort warmup; failures are reported per-play via onError
              }
            }
          }
        }.awaitAll()
      }
      Unit
    }
  }

  override fun isCached(url: String): Boolean {
    val resolved = UrlValidator.resolve(url) ?: return false
    return when (resolved.kind) {
      UrlValidator.Kind.REMOTE -> SvgaDiskCache.isCached(context, resolved.value)
      UrlValidator.Kind.LOCAL_FILE -> java.io.File(resolved.value).isFile
      UrlValidator.Kind.BUNDLED_ASSET -> assetExists(resolved.value)
    }
  }

  override fun getCachePath(url: String): String? {
    val resolved = UrlValidator.resolve(url) ?: return null
    return when (resolved.kind) {
      UrlValidator.Kind.REMOTE -> SvgaDiskCache.pathOrNull(context, resolved.value)
      UrlValidator.Kind.LOCAL_FILE -> java.io.File(resolved.value).takeIf { it.isFile }?.absolutePath
      UrlValidator.Kind.BUNDLED_ASSET -> if (assetExists(resolved.value)) resolved.value else null
    }
  }

  private fun assetExists(name: String): Boolean {
    return try {
      context.assets.open(name).use { true }
    } catch (_: java.io.IOException) {
      false
    }
  }

  override fun clearCache() {
    SvgaDiskCache.clearSvga(context)
    SvgaDiskCache.clearSounds(context)
    SvgaMemoryCache.clear()
  }

  override fun getCacheSize(): Promise<Double> {
    return Promise.async(scope) { SvgaDiskCache.totalSvgaBytes(context).toDouble() }
  }

  override fun setCacheLimit(bytes: Double) {
    SvgaDiskCache.setMaxBytes(bytes.toLong())
  }

  override fun setMemoryLimit(bytes: Double) {
    SvgaMemoryCache.setMaxBytes(bytes.toLong())
  }

  override fun loadSound(key: String, url: String): Promise<Unit> {
    return Promise.async(scope) {
      val file = SvgaSourceLoader.loadSoundBytes(context, url)
      sounds.load(key, file)
    }
  }

  override fun playSound(key: String, volume: Double) {
    sounds.play(key, volume.toFloat())
  }

  override fun stopSound(key: String) { sounds.stop(key) }
  override fun stopAllSounds() { sounds.stopAll() }
  override fun unloadSound(key: String) { sounds.unload(key) }

  override fun dispose() {
    scope.cancel()
    sounds.release()
  }

  private suspend fun preloadOne(source: String) {
    val resolved = UrlValidator.resolve(source) ?: return
    if (resolved.kind != UrlValidator.Kind.REMOTE) return
    SvgaSourceLoader.preloadRemote(context, resolved.value)
  }

  companion object {
    private const val MAX_CONCURRENT_PRELOADS = 4
  }
}
