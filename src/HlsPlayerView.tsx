import { View } from 'react-native';
import type { HlsPlayerProps } from './types';

/**
 * Web / 未支持平台的降级占位：仅渲染一个空 View，不做真正播放。
 * 原生实现见 HlsPlayerView.native.tsx。
 */
export function HlsPlayerView(props: HlsPlayerProps) {
  const { style } = props;
  return <View style={style} />;
}
