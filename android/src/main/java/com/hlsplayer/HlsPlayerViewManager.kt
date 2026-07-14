package com.hlsplayer

import android.graphics.Color
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.HlsPlayerViewManagerInterface
import com.facebook.react.viewmanagers.HlsPlayerViewManagerDelegate

@ReactModule(name = HlsPlayerViewManager.NAME)
class HlsPlayerViewManager : SimpleViewManager<HlsPlayerView>(),
  HlsPlayerViewManagerInterface<HlsPlayerView> {
  private val mDelegate: ViewManagerDelegate<HlsPlayerView>

  init {
    mDelegate = HlsPlayerViewManagerDelegate(this)
  }

  override fun getDelegate(): ViewManagerDelegate<HlsPlayerView>? {
    return mDelegate
  }

  override fun getName(): String {
    return NAME
  }

  public override fun createViewInstance(context: ThemedReactContext): HlsPlayerView {
    return HlsPlayerView(context)
  }

  @ReactProp(name = "color")
  override fun setColor(view: HlsPlayerView?, color: Int?) {
    view?.setBackgroundColor(color ?: Color.TRANSPARENT)
  }

  companion object {
    const val NAME = "HlsPlayerView"
  }
}
