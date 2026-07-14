package com.hlsplayer

import androidx.media3.common.util.UnstableApi
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.HlsPlayerViewManagerInterface
import com.facebook.react.viewmanagers.HlsPlayerViewManagerDelegate

@UnstableApi
@ReactModule(name = HlsPlayerViewManager.NAME)
class HlsPlayerViewManager : SimpleViewManager<HlsPlayerView>(),
  HlsPlayerViewManagerInterface<HlsPlayerView> {
  private val mDelegate: ViewManagerDelegate<HlsPlayerView> = HlsPlayerViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<HlsPlayerView> = mDelegate

  override fun getName(): String = NAME

  public override fun createViewInstance(context: ThemedReactContext): HlsPlayerView =
    HlsPlayerView(context)

  override fun onDropViewInstance(view: HlsPlayerView) {
    view.cleanup()
    super.onDropViewInstance(view)
  }

  @ReactProp(name = "sourceUrl")
  override fun setSourceUrl(view: HlsPlayerView?, value: String?) {
    view?.setSourceUrl(value)
  }

  @ReactProp(name = "keyUrl")
  override fun setKeyUrl(view: HlsPlayerView?, value: String?) {
    view?.setKeyUrl(value)
  }

  @ReactProp(name = "headers")
  override fun setHeaders(view: HlsPlayerView?, value: String?) {
    view?.setHeadersJson(value)
  }

  @ReactProp(name = "paused")
  override fun setPaused(view: HlsPlayerView?, value: Boolean) {
    view?.setPausedProp(value)
  }

  @ReactProp(name = "muted")
  override fun setMuted(view: HlsPlayerView?, value: Boolean) {
    view?.setMutedProp(value)
  }

  @ReactProp(name = "seekTo")
  override fun setSeekTo(view: HlsPlayerView?, value: Double) {
    view?.setSeekTo(value)
  }

  @ReactProp(name = "fullscreenRequest")
  override fun setFullscreenRequest(view: HlsPlayerView?, value: Int) {
    view?.setFullscreenRequest(value)
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> =
    mutableMapOf(
      "topLoad" to mutableMapOf("registrationName" to "onLoad"),
      "topProgress" to mutableMapOf("registrationName" to "onProgress"),
      "topEnd" to mutableMapOf("registrationName" to "onEnd"),
      "topError" to mutableMapOf("registrationName" to "onError"),
    )

  companion object {
    const val NAME = "HlsPlayerView"
  }
}
