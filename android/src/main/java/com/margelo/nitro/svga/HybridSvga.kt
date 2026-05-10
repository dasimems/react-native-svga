package com.margelo.nitro.svga

import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.ThemedReactContext
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@DoNotStrip
@Keep
class HybridSvga(private val context: ThemedReactContext) : HybridSvgaSpec() {

  private val playerView = SvgaPlayerView(context)
  private val audio = SvgaAudioEngine(context)
  private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
  private val main = Handler(Looper.getMainLooper())

  private var loadJob: Job? = null
  // @Volatile because in-flight callbacks (audio error post, load completion
  // hop to main, view-detach listener) read this off the main thread before
  // committing observable state. Cheap insurance even though the dominant
  // access pattern is main-only today.
  @Volatile private var entity: SvgaEntity? = null
  private var pendingPlayOnLoad = false
  private var wasPlayingBeforeWindowGone = false
  private var userPaused = false
  private var loadToken = 0L
  @Volatile private var disposed = false
  // Bumped on every `source`/`cacheKey` change. The deferred reload checks
  // whether its captured generation is still current — if a later setter
  // bumped it, we skip, so a single React commit that sets BOTH props
  // triggers exactly one load (the second), not two with the first
  // cancelled mid-flight. AtomicLong because Nitro setters can fire from
  // a non-main thread under the new architecture.
  private val reloadGeneration = AtomicLong(0L)

  override val view: View = playerView

  override var source: String = ""
    set(value) {
      val previous = field
      field = value
      if (value == previous) return
      scheduleReload()
    }

  /// Empty string ≡ "no override" — `handleSource` falls back to `source`.
  /// Re-loads when the key changes (with the same source) because the cache
  /// identity is what determines disk/memory hits.
  override var cacheKey: String = ""
    set(value) {
      val previous = field
      field = value
      if (value == previous) return
      scheduleReload()
    }

  /// Coalescing reload scheduler — see iOS HybridSvga for the rationale.
  /// React typically commits `source` and `cacheKey` as two consecutive
  /// Nitro property writes; without this, the first setter would fire a
  /// load that the second would immediately cancel.
  ///
  /// We snapshot `source`/`cacheKey` on the SETTER thread (where the
  /// calling setter just wrote `field = value`) and pass the snapshot into
  /// the posted runnable. Reading them later from the main thread without
  /// a snapshot would have no guaranteed happens-before with the setter
  /// thread, risking a stale-source load. `main.post` provides the fence
  /// that publishes our snapshot to the main thread.
  private fun scheduleReload() {
    val myGen = reloadGeneration.incrementAndGet()
    val snapshotSource = source
    val snapshotKey = cacheKey
    main.post {
      if (disposed) return@post
      if (reloadGeneration.get() != myGen) return@post
      handleSource(snapshotSource, snapshotKey)
    }
  }

  override var loops: Double = 0.0
    set(value) {
      field = value
      playerView.maxLoops = value.toInt().coerceAtLeast(0)
    }

  override var autoPlay: Boolean = true

  override var speed: Double = 1.0
    set(value) {
      field = value
      applySpeed()
      audio.setRate(value.toFloat())
    }

  override var muteBuiltInAudio: Boolean = false
    set(value) { field = value; audio.setMuted(value) }

  override var builtInAudioVolume: Double = 1.0
    set(value) { field = value; audio.setVolume(value.toFloat()) }

  override var playInBackground: Boolean = false

  override var scaleMode: ScaleMode = ScaleMode.ASPECTFIT
    set(value) { field = value; playerView.scaleMode = value }

  override var onStart: (() -> Unit)? = null
  override var onFinish: (() -> Unit)? = null
  override var onLoop: ((count: Double) -> Unit)? = null
  override var onError: ((message: String) -> Unit)? = null

  init {
    SvgaMemoryCache.ensureInit(context.applicationContext)
    playerView.onFrame = SvgaPlayerView.FrameListener { frame, _ ->
      if (disposed) return@FrameListener
      audio.onFrame(frame)
    }
    playerView.onLoop = SvgaPlayerView.LoopListener { count ->
      if (disposed) return@LoopListener
      onLoop?.invoke(count.toDouble())
    }
    playerView.onFinish = SvgaPlayerView.FinishListener {
      if (disposed) return@FinishListener
      audio.stopAll()
      onFinish?.invoke()
    }
    playerView.onWindowVisibilityChange = SvgaPlayerView.WindowVisibilityListener { visible ->
      if (disposed) return@WindowVisibilityListener
      if (playInBackground) return@WindowVisibilityListener
      if (visible) handleWindowReturned() else handleWindowGone()
    }
    audio.onAudioError = SvgaAudioEngine.AudioErrorListener { message ->
      main.post {
        if (disposed) return@post
        onError?.invoke(message)
      }
    }
  }

  private fun handleWindowGone() {
    wasPlayingBeforeWindowGone = playerView.isPlaying()
    playerView.pause()
    audio.pauseAll()
  }

  private fun handleWindowReturned() {
    if (!wasPlayingBeforeWindowGone) return
    wasPlayingBeforeWindowGone = false
    playerView.start()
    audio.resumeAll()
  }

  override fun play() {
    if (disposed) return
    userPaused = false
    val current = entity
    if (current == null) {
      pendingPlayOnLoad = true
      return
    }
    val wasIdle = !playerView.isPlaying()
    playerView.start()
    audio.resumeAll()
    if (wasIdle) onStart?.invoke()
  }

  override fun pause() {
    if (disposed) return
    userPaused = true
    pendingPlayOnLoad = false
    wasPlayingBeforeWindowGone = false
    playerView.pause()
    audio.pauseAll()
  }

  override fun stop() {
    if (disposed) return
    pendingPlayOnLoad = false
    wasPlayingBeforeWindowGone = false
    userPaused = false
    playerView.stop()
    audio.stopAll()
  }

  override fun seekToFrame(frame: Double) {
    if (disposed) return
    playerView.seekToFrame(frame.toInt())
  }

  override fun seekToProgress(progress: Double) {
    if (disposed) return
    val total = entity?.movie?.frames ?: return
    val clamped = progress.coerceIn(0.0, 1.0)
    playerView.seekToFrame((clamped * total).toInt())
  }

  override fun isPlaying(): Boolean = !disposed && playerView.isPlaying()

  // Nitro's eager-cleanup hook. JS calls this via dispose(), and we also
  // call it ourselves from SvgaPlayer.tsx unmount because the auto-generated
  // ViewManager.onDropViewInstance does NOT call dispose() — it only removes
  // the view from its lookup map. Without an explicit dispose, the loadJob,
  // CoroutineScope, audio engine, and MediaPlayers leak until JVM GC.
  override fun dispose() {
    if (disposed) return
    disposed = true
    // Cancel coroutines synchronously — these are thread-safe and we want
    // them to halt as soon as possible regardless of caller thread.
    loadJob?.cancel()
    scope.cancel()
    // The view-side teardown calls `View.invalidate()` (via the entity
    // setter), which is UI-thread-only on attached views. Nitro can call
    // dispose() from the JS thread, so we hop to main if needed. We read
    // `entity` INSIDE the cleanup closure (not at capture time) so that an
    // in-flight applyEntity that runs between dispose() and cleanup — its
    // own disposed-check may have already passed — still gets its retain
    // released. (`applyEntity` sets `entity = parsed` consuming the
    // loader's +1; if we captured `priorEntity` here we'd miss that.)
    val cleanup = Runnable {
      playerView.entity = null
      playerView.release()
      audio.release()
      entity?.release()
      entity = null
    }
    if (Looper.myLooper() == Looper.getMainLooper()) {
      cleanup.run()
    } else {
      main.post(cleanup)
    }
  }

  private fun handleSource(value: String, rawKey: String) {
    if (disposed) return
    loadJob?.cancel()
    loadToken += 1
    val token = loadToken
    pendingPlayOnLoad = false
    wasPlayingBeforeWindowGone = false
    userPaused = false
    // Empty cacheKey means "no override" → fall back to the source URL.
    val resolvedKey: String? = if (rawKey.isEmpty()) null else rawKey
    if (value.isEmpty()) {
      entity?.release()
      entity = null
      playerView.stop()
      playerView.entity = null
      // unloadAll (vs stopAll) so the prior SVGA's MediaPlayers are released
      // immediately. Without this they linger until the next non-empty source
      // triggers audio.load() (which internally unloads), or until dispose().
      audio.unloadAll()
      return
    }
    loadJob = scope.launch {
      var parsed: SvgaEntity? = null
      var preparedAudio: List<SvgaAudioEngine.PreparedTrack> = emptyList()
      try {
        // loadEntity returns +1; we own it from here. The hop+apply is
        // wrapped in NonCancellable so a cancel between loadEntity returning
        // and applyEntity finishing can't leak the +1 — without it,
        // withContext's suspension would throw CancellationException at the
        // hop boundary, the catch arm would swallow it, and `parsed` would
        // never be released.
        parsed = SvgaSourceLoader.loadEntity(context.applicationContext, value, resolvedKey)
        // Pre-decode + synchronously prepare audio tracks on this IO
        // coroutine, BEFORE the main hop. `MediaPlayer.prepare()` blocks
        // for a few ms per track; doing it here means the tracks are
        // ready to play the instant `playerView.start()` fires `onFrame(0)`.
        // The previous async-prepare path left a window where video had
        // started but audio was still preparing, so the first cue (often
        // `startFrame == 0`) silently missed.
        preparedAudio = audio.prepareTracks(parsed)
        withContext(NonCancellable + Dispatchers.Main) {
          if (token != loadToken || disposed) {
            audio.releasePrepared(preparedAudio)
            return@withContext
          }
          val toApply = parsed!!
          parsed = null  // ownership transferring into applyEntity
          applyEntity(toApply, preparedAudio)
          preparedAudio = emptyList()  // ownership transferred to engine
        }
      } catch (_: kotlinx.coroutines.CancellationException) {
        // job was cancelled; finally below releases parsed if we got it
      } catch (t: Throwable) {
        // Catching `Throwable` (not just `Exception`) because
        // `BitmapFactory.decodeByteArray` can raise OutOfMemoryError on a
        // low-RAM device — that's an `Error`, escapes a `catch (Exception)`,
        // and crashes the host process. We can't rescue every Error
        // (StackOverflowError, etc.), but OOM during a media decode is
        // recoverable: just surface it via onError and let the user retry.
        main.post {
          if (token != loadToken || disposed) return@post
          onError?.invoke(t.message ?: "Failed to load svga")
        }
      } finally {
        // If applyEntity ran, parsed was nulled and this is a no-op;
        // otherwise (early-return path or any throw) we release the +1.
        parsed?.release()
        // Release any prepared MediaPlayers that didn't make it into an
        // engine install (cancelled load, or pre-install throw).
        if (preparedAudio.isNotEmpty()) audio.releasePrepared(preparedAudio)
      }
    }
  }

  // Caller transfers a +1 ownership of `parsed` into this method.
  private fun applyEntity(parsed: SvgaEntity, preparedAudio: List<SvgaAudioEngine.PreparedTrack>) {
    val prior = entity
    entity = parsed  // consume the loader's +1
    prior?.release()
    playerView.entity = parsed  // setter takes its own +1
    playerView.scaleMode = scaleMode
    applySpeed()
    audio.setMuted(muteBuiltInAudio)
    audio.setVolume(builtInAudioVolume.toFloat())
    audio.setRate(speed.toFloat())
    audio.installTracks(preparedAudio)
    if (userPaused) {
      pendingPlayOnLoad = false
      return
    }
    if (autoPlay || pendingPlayOnLoad) {
      pendingPlayOnLoad = false
      play()
    }
  }

  private fun applySpeed() {
    val fps = entity?.movie?.fps ?: DEFAULT_FPS
    val rate = speed.coerceAtLeast(MIN_SPEED)
    playerView.frameInterval = (1000.0 / (fps * rate)).toLong().coerceAtLeast(1L)
  }

  companion object {
    private const val DEFAULT_FPS = 15
    private const val MIN_SPEED = 0.05
  }
}
