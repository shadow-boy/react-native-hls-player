import type {
  CodegenTypes,
  HostComponent,
  ViewProps,
} from 'react-native';
import { codegenNativeComponent } from 'react-native';

type LoadEvent = Readonly<{ duration: CodegenTypes.Double }>;
type ProgressEvent = Readonly<{
  currentTime: CodegenTypes.Double;
  duration: CodegenTypes.Double;
}>;
type ErrorEvent = Readonly<{ message: string }>;
type EndEvent = Readonly<{}>;

export interface NativeProps extends ViewProps {
  /** HLS 播放地址（http/https）。 */
  sourceUrl?: string;
  /** AES-128 密钥地址；会被写进清单的 #EXT-X-KEY URI，并作为 `key` 请求头下发。 */
  keyUrl?: string;
  /** 附加请求头，序列化为 JSON 字符串（原生侧解析）。 */
  headers?: string;
  paused?: boolean;
  muted?: boolean;
  /** 目标进度（秒）。 */
  seekTo?: CodegenTypes.Double;
  /** 全屏请求计数（递增触发一次全屏）。 */
  fullscreenRequest?: CodegenTypes.Int32;
  onLoad?: CodegenTypes.DirectEventHandler<LoadEvent>;
  onProgress?: CodegenTypes.DirectEventHandler<ProgressEvent>;
  onEnd?: CodegenTypes.DirectEventHandler<EndEvent>;
  onError?: CodegenTypes.DirectEventHandler<ErrorEvent>;
}

export default codegenNativeComponent<NativeProps>(
  'HlsPlayerView'
) as HostComponent<NativeProps>;
