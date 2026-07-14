import React from 'react';
import type { NativeSyntheticEvent } from 'react-native';
import NativeHlsPlayerView from './HlsPlayerViewNativeComponent';
import type {
  HlsErrorEvent,
  HlsLoadEvent,
  HlsPlayerProps,
  HlsProgressEvent,
} from './types';

/**
 * 原生 HLS AES-128 播放视图：密钥下发与清单改写全部留在原生层。
 * 对外暴露友好的 props（headers 用对象、事件回调直接拿 payload），
 * 内部转换成 codegen 组件所需的形态（headers 序列化为 JSON）。
 */
export function HlsPlayerView({
  headers,
  onLoad,
  onProgress,
  onEnd,
  onError,
  ...rest
}: HlsPlayerProps) {
  const headersJson = React.useMemo(
    () => (headers ? JSON.stringify(headers) : undefined),
    [headers]
  );

  return (
    <NativeHlsPlayerView
      {...rest}
      headers={headersJson}
      onLoad={
        onLoad
          ? (event: NativeSyntheticEvent<HlsLoadEvent>) =>
              onLoad(event.nativeEvent)
          : undefined
      }
      onProgress={
        onProgress
          ? (event: NativeSyntheticEvent<HlsProgressEvent>) =>
              onProgress(event.nativeEvent)
          : undefined
      }
      onEnd={onEnd ? () => onEnd() : undefined}
      onError={
        onError
          ? (event: NativeSyntheticEvent<HlsErrorEvent>) =>
              onError(event.nativeEvent)
          : undefined
      }
    />
  );
}
