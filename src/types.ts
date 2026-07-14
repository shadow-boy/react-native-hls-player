import type { ViewProps } from 'react-native';

export interface HlsLoadEvent {
  duration: number;
}

export interface HlsProgressEvent {
  currentTime: number;
  duration: number;
}

export interface HlsErrorEvent {
  message: string;
}

export interface HlsPlayerProps extends ViewProps {
  /** HLS 播放地址（http/https）。 */
  sourceUrl?: string;
  /** AES-128 密钥地址。 */
  keyUrl?: string;
  /** 附加请求头（会以 JSON 传给原生）。 */
  headers?: Record<string, string>;
  paused?: boolean;
  muted?: boolean;
  /** 目标进度（秒），变化即 seek。 */
  seekTo?: number;
  /** 全屏请求计数，递增一次触发一次全屏。 */
  fullscreenRequest?: number;
  onLoad?: (event: HlsLoadEvent) => void;
  onProgress?: (event: HlsProgressEvent) => void;
  onEnd?: () => void;
  onError?: (event: HlsErrorEvent) => void;
}
