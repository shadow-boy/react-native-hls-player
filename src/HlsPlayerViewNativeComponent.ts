import type { HostComponent, ViewProps } from 'react-native';
import type {
  Double,
  Int32,
  DirectEventHandler,
} from 'react-native/Libraries/Types/CodegenTypes';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

type LoadEvent = Readonly<{ duration: Double }>;
type ProgressEvent = Readonly<{ currentTime: Double; duration: Double }>;
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
  seekTo?: Double;
  /** 全屏请求计数（递增触发一次全屏）。 */
  fullscreenRequest?: Int32;
  onLoad?: DirectEventHandler<LoadEvent>;
  onProgress?: DirectEventHandler<ProgressEvent>;
  onEnd?: DirectEventHandler<EndEvent>;
  onError?: DirectEventHandler<ErrorEvent>;
}

export default codegenNativeComponent<NativeProps>(
  'HlsPlayerView'
) as HostComponent<NativeProps>;
