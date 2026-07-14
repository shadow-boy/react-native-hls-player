package com.hlsplayer

import android.app.Dialog
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.ui.PlayerView
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * 与 iOS 版对齐的 HLS AES-128 播放视图：
 * - 所有清单/分片/密钥请求都带上外部 headers 以及 `key` 头；
 * - 清单里的 #EXT-X-KEY URI 会被改写成真实 keyUrl，让 ExoPlayer 直接向真实密钥地址取密钥。
 */
@UnstableApi
class HlsPlayerView(context: Context) : FrameLayout(context) {
  private val playerView = PlayerView(context)
  private var player: ExoPlayer? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  private var sourceUrl: String? = null
  private var keyUrl: String? = null
  private var headers: Map<String, String> = emptyMap()
  private var paused = false
  private var muted = false
  private var pendingSeekSeconds: Double? = null
  private var lastFullscreenRequest = 0

  private var reloadScheduled = false
  private var fullscreenDialog: Dialog? = null

  private val progressRunnable = object : Runnable {
    override fun run() {
      emitProgress()
      mainHandler.postDelayed(this, 1000)
    }
  }

  init {
    setBackgroundColor(android.graphics.Color.BLACK)
    playerView.useController = false
    playerView.setKeepContentOnPlayerReset(true)
    addView(
      playerView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    )
  }

  // region props
  fun setSourceUrl(value: String?) {
    if (value != sourceUrl) {
      sourceUrl = value
      scheduleReload()
    }
  }

  fun setKeyUrl(value: String?) {
    if (value != keyUrl) {
      keyUrl = value
      scheduleReload()
    }
  }

  fun setHeadersJson(value: String?) {
    headers = parseHeaders(value)
    scheduleReload()
  }

  fun setPausedProp(value: Boolean) {
    paused = value
    player?.playWhenReady = !value
  }

  fun setMutedProp(value: Boolean) {
    muted = value
    player?.volume = if (value) 0f else 1f
  }

  fun setSeekTo(seconds: Double) {
    if (seconds.isFinite()) {
      seekTo(seconds)
    }
  }

  fun setFullscreenRequest(request: Int) {
    if (request > lastFullscreenRequest) {
      lastFullscreenRequest = request
      presentFullscreen()
    }
  }
  // endregion

  private fun parseHeaders(json: String?): Map<String, String> {
    if (json.isNullOrEmpty()) return emptyMap()
    return runCatching {
      val obj = JSONObject(json)
      buildMap {
        obj.keys().forEach { key -> put(key, obj.optString(key)) }
      }
    }.getOrDefault(emptyMap())
  }

  private fun scheduleReload() {
    if (reloadScheduled) return
    reloadScheduled = true
    mainHandler.post {
      reloadScheduled = false
      reload()
    }
  }

  private fun reload() {
    val source = sourceUrl
    val key = keyUrl
    if (source.isNullOrEmpty() || key.isNullOrEmpty()) return

    tearDownPlayer()

    val requestHeaders = HashMap(headers).apply { put("key", key) }
    val client = OkHttpClient.Builder().build()
    val httpFactory = OkHttpDataSource.Factory(client).setDefaultRequestProperties(requestHeaders)
    val dataSourceFactory = DataSource.Factory { PlaylistRewritingDataSource(httpFactory.createDataSource(), key) }

    val mediaSource = HlsMediaSource.Factory(dataSourceFactory)
      .createMediaSource(MediaItem.fromUri(Uri.parse(source)))

    val exo = ExoPlayer.Builder(context).build()
    exo.setMediaSource(mediaSource)
    exo.playWhenReady = !paused
    exo.volume = if (muted) 0f else 1f
    exo.addListener(playerListener)
    exo.prepare()

    player = exo
    playerView.player = exo
    mainHandler.postDelayed(progressRunnable, 1000)
  }

  private val playerListener = object : Player.Listener {
    override fun onPlaybackStateChanged(state: Int) {
      when (state) {
        Player.STATE_READY -> emitLoad()
        Player.STATE_ENDED -> dispatchEvent(EndEvent(surfaceId(), id))
        else -> Unit
      }
    }

    override fun onPlayerError(error: PlaybackException) {
      dispatchEvent(ErrorEvent(surfaceId(), id, error.message ?: "视频资源加载失败"))
    }
  }

  private fun emitLoad() {
    val current = player ?: return
    val duration = if (current.duration == C.TIME_UNSET) 0.0 else current.duration / 1000.0
    dispatchEvent(LoadEvent(surfaceId(), id, duration))
    pendingSeekSeconds?.let {
      seekTo(it)
      pendingSeekSeconds = null
    }
  }

  private fun emitProgress() {
    val current = player ?: return
    val position = current.currentPosition / 1000.0
    val duration = if (current.duration == C.TIME_UNSET) 0.0 else current.duration / 1000.0
    dispatchEvent(ProgressEvent(surfaceId(), id, position, duration))
  }

  private fun seekTo(seconds: Double) {
    val target = seconds.coerceAtLeast(0.0)
    val current = player
    if (current == null) {
      pendingSeekSeconds = target
      return
    }
    current.seekTo((target * 1000).toLong())
  }

  private fun tearDownPlayer() {
    mainHandler.removeCallbacks(progressRunnable)
    player?.let {
      it.removeListener(playerListener)
      it.release()
    }
    player = null
    playerView.player = null
  }

  private fun presentFullscreen() {
    val exo = player ?: return
    if (fullscreenDialog != null) return
    val dialog = Dialog(context, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
    val fullscreenView = PlayerView(context)
    fullscreenView.useController = true
    PlayerView.switchTargetView(exo, playerView, fullscreenView)
    dialog.setContentView(
      fullscreenView,
      ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    )
    dialog.window?.setLayout(
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT
    )
    dialog.setOnDismissListener {
      PlayerView.switchTargetView(exo, fullscreenView, playerView)
      fullscreenDialog = null
    }
    fullscreenDialog = dialog
    dialog.show()
  }

  fun cleanup() {
    fullscreenDialog?.dismiss()
    fullscreenDialog = null
    tearDownPlayer()
  }

  private fun surfaceId(): Int = UIManagerHelper.getSurfaceId(this)

  private fun dispatchEvent(event: Event<*>) {
    val reactContext = context as? ThemedReactContext ?: return
    UIManagerHelper.getEventDispatcherForReactTag(reactContext, id)?.dispatchEvent(event)
  }

  // region events
  private class LoadEvent(surfaceId: Int, viewId: Int, private val duration: Double) :
    Event<LoadEvent>(surfaceId, viewId) {
    override fun getEventName() = "topLoad"
    override fun getEventData(): WritableMap = Arguments.createMap().apply { putDouble("duration", duration) }
  }

  private class ProgressEvent(
    surfaceId: Int,
    viewId: Int,
    private val currentTime: Double,
    private val duration: Double,
  ) : Event<ProgressEvent>(surfaceId, viewId) {
    override fun getEventName() = "topProgress"
    override fun getEventData(): WritableMap = Arguments.createMap().apply {
      putDouble("currentTime", currentTime)
      putDouble("duration", duration)
    }
  }

  private class EndEvent(surfaceId: Int, viewId: Int) : Event<EndEvent>(surfaceId, viewId) {
    override fun getEventName() = "topEnd"
    override fun getEventData(): WritableMap = Arguments.createMap()
  }

  private class ErrorEvent(surfaceId: Int, viewId: Int, private val message: String) :
    Event<ErrorEvent>(surfaceId, viewId) {
    override fun getEventName() = "topError"
    override fun getEventData(): WritableMap = Arguments.createMap().apply { putString("message", message) }
  }
  // endregion

  /**
   * 包装上游 OkHttp DataSource：遇到 .m3u8 清单时整体读入并把 #EXT-X-KEY 的 URI 改写成 keyUrl，
   * 再用 ByteArrayDataSource 交付；其它请求（分片、密钥）直接透传（headers 已在工厂里注入）。
   */
  private class PlaylistRewritingDataSource(
    private val upstream: DataSource,
    private val keyUrl: String,
  ) : DataSource {
    private var active: DataSource = upstream
    private val listeners = mutableListOf<TransferListener>()

    override fun addTransferListener(transferListener: TransferListener) {
      listeners.add(transferListener)
      upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
      val path = dataSpec.uri.lastPathSegment ?: ""
      if (!path.endsWith(".m3u8", ignoreCase = true)) {
        active = upstream
        return upstream.open(dataSpec)
      }
      upstream.open(dataSpec)
      val raw = readFully(upstream)
      upstream.close()
      val rewritten = rewritePlaylist(raw)
      val bytesSource = ByteArrayDataSource(rewritten)
      listeners.forEach { bytesSource.addTransferListener(it) }
      active = bytesSource
      return bytesSource.open(
        dataSpec.buildUpon().setPosition(0).setLength(C.LENGTH_UNSET.toLong()).build()
      )
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
      active.read(buffer, offset, length)

    override fun getUri(): Uri? = active.uri

    override fun getResponseHeaders(): Map<String, List<String>> = active.responseHeaders

    override fun close() {
      active.close()
    }

    private fun readFully(source: DataSource): ByteArray {
      val output = ByteArrayOutputStream()
      val buffer = ByteArray(8 * 1024)
      while (true) {
        val read = source.read(buffer, 0, buffer.size)
        if (read == C.RESULT_END_OF_INPUT) break
        output.write(buffer, 0, read)
      }
      return output.toByteArray()
    }

    private fun rewritePlaylist(data: ByteArray): ByteArray {
      val text = String(data, Charsets.UTF_8)
      if (!text.contains("#EXT-X-KEY")) return data
      val regex = Regex("(#EXT-X-KEY:[^\\r\\n]*URI\\s*=\\s*[\"'])([^\"'\\r\\n]+)([\"'])")
      val replaced = regex.replace(text) { match ->
        "${match.groupValues[1]}$keyUrl${match.groupValues[3]}"
      }
      return replaced.toByteArray(Charsets.UTF_8)
    }
  }
}
