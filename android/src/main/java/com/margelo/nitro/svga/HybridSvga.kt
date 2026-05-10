package com.margelo.nitro.svga

import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.ThemedReactContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
  private var entity: SvgaEntity? = null
  private var pendingPlayOnLoad = false
  private var wasPlayingBeforeWindowGone = false
  private var userPaused = false
  private var loadToken = 0L
  @Volatile private var disposed = false

  override val view: View = playerView

  override var source: String = ""
    set(value) {
      val previous = field
      field = value
      if (value == previous) return
      handleSource(value)
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
    playerView.onFrame = SvgaPlayerView.FrameListener { frame, _ -> audio.onFrame(frame) }
    playerView.onLoop = SvgaPlayerView.LoopListener { count -> onLoop?.invoke(count.toDouble()) }
    playerView.onFinish = SvgaPlayerView.FinishListener {
      audio.stopAll()
      onFinish?.invoke()
    }
    playerView.onWindowVisibilityChange = SvgaPlayerView.WindowVisibilityListener { visible ->
      if (playInBackground) return@WindowVisibilityListener
      if (visible) handleWindowReturned() else handleWindowGone()
    }
    audio.onAudioError = SvgaAudioEngine.AudioErrorListener { message ->
      main.post { onError?.invoke(message) }
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
    loadJob?.cancel()
    scope.cancel()
    playerView.release()
    audio.release()
    // Release our +1 on the entity so its bitmaps can recycle when the
    // last holder (cache or another player) drops too. playerView.release
    // already cleared its own retain; this drops ours.
    entity?.release()
    entity = null
  }

  private fun handleSource(value: String) {
    if (disposed) return
    loadJob?.cancel()
    loadToken += 1
    val token = loadToken
    pendingPlayOnLoad = false
    wasPlayingBeforeWindowGone = false
    userPaused = false
    if (value.isEmpty()) {
      entity?.release()
      entity = null
      playerView.stop()
      playerView.entity = null
      audio.stopAll()
      return
    }
    loadJob = scope.launch {
      try {
        // loadEntity returns +1; we own it from here. Either we transfer
        // ownership into `applyEntity`, or release on the cancel/dispose
        // paths so bitmaps can reach refcount zero.
        val parsed = SvgaSourceLoader.loadEntity(context.applicationContext, value)
        withContext(Dispatchers.Main) {
          if (token != loadToken || disposed) {
            parsed.release()
            return@withContext
          }
          applyEntity(parsed)
        }
      } catch (e: kotlinx.coroutines.CancellationException) {
        return@launch
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
      }
    }
  }

  // Caller transfers a +1 ownership of `parsed` into this method.
  private fun applyEntity(parsed: SvgaEntity) {
    val prior = entity
    entity = parsed  // consume the loader's +1
    prior?.release()
    playerView.entity = parsed  // setter takes its own +1
    playerView.scaleMode = scaleMode
    applySpeed()
    audio.setMuted(muteBuiltInAudio)
    audio.setVolume(builtInAudioVolume.toFloat())
    audio.setRate(speed.toFloat())
    audio.load(parsed)
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
