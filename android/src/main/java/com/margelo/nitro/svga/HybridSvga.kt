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

  override var scaleMode: ScaleMode = ScaleMode.ASPECTFIT
    set(value) { field = value; playerView.scaleMode = value }

  override var onStart: (() -> Unit)? = null
  override var onFinish: (() -> Unit)? = null
  override var onLoop: ((count: Double) -> Unit)? = null
  override var onError: ((message: String) -> Unit)? = null

  init {
    playerView.onFrame = SvgaPlayerView.FrameListener { frame, _ -> audio.onFrame(frame) }
    playerView.onLoop = SvgaPlayerView.LoopListener { count -> onLoop?.invoke(count.toDouble()) }
    playerView.onFinish = SvgaPlayerView.FinishListener {
      audio.stopAll()
      onFinish?.invoke()
    }
  }

  override fun play() {
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
    playerView.pause()
    audio.pauseAll()
  }

  override fun stop() {
    playerView.stop()
    audio.stopAll()
  }

  override fun seekToFrame(frame: Double) { playerView.seekToFrame(frame.toInt()) }

  override fun seekToProgress(progress: Double) {
    val total = entity?.movie?.frames ?: return
    val clamped = progress.coerceIn(0.0, 1.0)
    playerView.seekToFrame((clamped * total).toInt())
  }

  override fun onDestroy() {
    loadJob?.cancel()
    scope.cancel()
    playerView.release()
    audio.release()
  }

  private fun handleSource(value: String) {
    loadJob?.cancel()
    if (value.isEmpty()) {
      entity = null
      playerView.stop()
      playerView.entity = null
      audio.stopAll()
      return
    }
    loadJob = scope.launch {
      try {
        val parsed = SvgaSourceLoader.loadEntity(context.applicationContext, value)
        withContext(Dispatchers.Main) { applyEntity(parsed) }
      } catch (e: Exception) {
        main.post { onError?.invoke(e.message ?: "Failed to load svga") }
      }
    }
  }

  private fun applyEntity(parsed: SvgaEntity) {
    entity = parsed
    playerView.entity = parsed
    playerView.scaleMode = scaleMode
    applySpeed()
    audio.setMuted(muteBuiltInAudio)
    audio.setVolume(builtInAudioVolume.toFloat())
    audio.setRate(speed.toFloat())
    audio.load(parsed)
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
