#import "HlsPlayerView.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

#import <react/renderer/components/HlsPlayerViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/HlsPlayerViewSpec/EventEmitters.h>
#import <react/renderer/components/HlsPlayerViewSpec/Props.h>
#import <react/renderer/components/HlsPlayerViewSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

static NSString *const kResourceScheme = @"miying-hls";

/**
 * 与 splitbill.ipa 播放器边界一致：AVAsset 只看到自定义 scheme，清单/分片请求由
 * AVAssetResourceLoader 转发；清单中的 #EXT-X-KEY URI 被替换成真实 keyUrl，并把
 * keyUrl 作为 `key` 请求头下发。逻辑由原 Swift 版原样移植为 Objective-C++。
 */
@interface HlsPlayerView () <AVAssetResourceLoaderDelegate>
@end

@implementation HlsPlayerView {
  AVPlayerLayer *_playerLayer;
  AVPlayer *_player;
  AVURLAsset *_asset;
  NSURLSession *_session;
  dispatch_queue_t _loaderQueue;

  id _timeObserver;
  id _endObserver;

  // props 镜像
  NSString *_sourceUrl;
  NSString *_keyUrl;
  NSString *_headersJson;
  NSDictionary<NSString *, NSString *> *_headers;
  BOOL _paused;
  BOOL _muted;
  double _seekTo;
  NSInteger _fullscreenRequest;

  BOOL _scheduledReload;
  NSInteger _lastFullscreenRequest;
  double _pendingSeekSeconds;
  BOOL _hasPendingSeek;
  __weak AVPlayerViewController *_fullscreenController;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<HlsPlayerViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const HlsPlayerViewProps>();
    _props = defaultProps;

    _headers = @{};
    _seekTo = NAN;
    _loaderQueue = dispatch_queue_create("com.miyingvideo.hls-resource-loader", DISPATCH_QUEUE_SERIAL);

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:configuration];

    self.backgroundColor = [UIColor blackColor];
    _playerLayer = [AVPlayerLayer layer];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.layer addSublayer:_playerLayer];
  }
  return self;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  [self syncPlayerLayerFrame];
}

// Fabric 通过 updateLayoutMetrics 下发尺寸；全屏/内联切换重挂载时同步图层 frame，避免 0 尺寸黑屏。
- (void)updateLayoutMetrics:(const LayoutMetrics &)layoutMetrics
           oldLayoutMetrics:(const LayoutMetrics &)oldLayoutMetrics
{
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  [self syncPlayerLayerFrame];
}

- (void)syncPlayerLayerFrame
{
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _playerLayer.frame = self.bounds;
  [CATransaction commit];
}

- (void)prepareForRecycle
{
  [self tearDownPlayer];
  _sourceUrl = nil;
  _keyUrl = nil;
  _headersJson = nil;
  _headers = @{};
  _paused = NO;
  _muted = NO;
  _seekTo = NAN;
  _fullscreenRequest = 0;
  _lastFullscreenRequest = 0;
  [super prepareForRecycle];
}

- (void)dealloc
{
  [self tearDownPlayer];
}

#pragma mark - Fabric props

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &newViewProps = *std::static_pointer_cast<HlsPlayerViewProps const>(props);

  // 与自身 ivar 比对（而非 oldProps）：Fabric 回收复用视图后 ivar 被重置为 nil，
  // 即使新 props 与回收前相同也能正确触发 reload，避免全屏 remount 后黑屏不播放。
  BOOL needsReload = NO;

  NSString *newSource = [self toNSString:newViewProps.sourceUrl];
  if (![self isString:newSource equalTo:_sourceUrl]) {
    _sourceUrl = newSource;
    needsReload = YES;
  }
  NSString *newKey = [self toNSString:newViewProps.keyUrl];
  if (![self isString:newKey equalTo:_keyUrl]) {
    _keyUrl = newKey;
    needsReload = YES;
  }
  NSString *newHeadersJson = [self toNSString:newViewProps.headers];
  if (![self isString:newHeadersJson equalTo:_headersJson]) {
    _headersJson = newHeadersJson;
    _headers = [self parseHeaders:newHeadersJson];
    needsReload = YES;
  }
  if (newViewProps.muted != _muted) {
    _muted = newViewProps.muted;
    _player.muted = _muted;
  }
  if (newViewProps.paused != _paused) {
    _paused = newViewProps.paused;
    [self updatePlaybackState];
  }
  if (newViewProps.seekTo != _seekTo) {
    _seekTo = newViewProps.seekTo;
    [self seekIfNeeded];
  }
  if (newViewProps.fullscreenRequest != _fullscreenRequest) {
    _fullscreenRequest = newViewProps.fullscreenRequest;
    [self presentFullscreen];
  }

  if (needsReload) {
    [self scheduleReload];
  }

  [super updateProps:props oldProps:oldProps];
}

- (BOOL)isString:(NSString *)a equalTo:(NSString *)b
{
  if (a == b) {
    return YES;
  }
  if (a == nil || b == nil) {
    return NO;
  }
  return [a isEqualToString:b];
}

- (NSString *)toNSString:(const std::string &)value
{
  if (value.empty()) {
    return nil;
  }
  return [NSString stringWithUTF8String:value.c_str()];
}

- (NSDictionary<NSString *, NSString *> *)parseHeaders:(NSString *)json
{
  if (json.length == 0) {
    return @{};
  }
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return @{};
  }
  NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
  [(NSDictionary *)parsed enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    if (![key isKindOfClass:[NSString class]]) {
      return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
      values[key] = obj;
    } else if ([obj isKindOfClass:[NSNumber class]]) {
      values[key] = [(NSNumber *)obj stringValue];
    }
  }];
  return values;
}

#pragma mark - Player lifecycle

- (void)scheduleReload
{
  if (_scheduledReload) {
    return;
  }
  _scheduledReload = YES;
  __weak HlsPlayerView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    HlsPlayerView *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    strongSelf->_scheduledReload = NO;
    [strongSelf reload];
  });
}

- (void)reload
{
  if (_sourceUrl.length == 0 || _keyUrl.length == 0) {
    return;
  }
  NSURL *source = [NSURL URLWithString:_sourceUrl];
  NSURL *intercepted = [self interceptedURLFrom:source];
  if (!intercepted) {
    [self reportError:@"播放地址格式无效"];
    return;
  }

  double requestedSeek = _seekTo;
  [self tearDownPlayer];
  if (isfinite(requestedSeek)) {
    _pendingSeekSeconds = MAX(0, requestedSeek);
    _hasPendingSeek = YES;
  }

  NSMutableDictionary<NSString *, NSString *> *requestHeaders = [self stringHeaders];
  requestHeaders[@"key"] = _keyUrl;
  // 原版插件使用同名 AVURLAsset option；SDK 未公开该常量，按平台约定传字符串键。
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:intercepted
                                          options:@{@"AVURLAssetHTTPHeaderFieldsKey": requestHeaders}];
  [asset.resourceLoader setDelegate:self queue:_loaderQueue];
  _asset = asset;

  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
  AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
  player.muted = _muted;
  _player = player;
  _playerLayer.player = player;

  [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:nil];
  [item addObserver:self forKeyPath:@"duration" options:NSKeyValueObservingOptionNew context:nil];

  __weak HlsPlayerView *weakSelf = self;
  _timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1, 600)
                                                       queue:dispatch_get_main_queue()
                                                  usingBlock:^(CMTime time) {
    [weakSelf emitProgress:CMTimeGetSeconds(time)];
  }];
  _endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                  object:item
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification *note) {
    [weakSelf emitEnd];
  }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
  AVPlayerItem *item = _player.currentItem;
  if (object != item) {
    return;
  }
  if ([keyPath isEqualToString:@"status"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      switch (item.status) {
        case AVPlayerItemStatusReadyToPlay:
          [self emitLoad];
          [self updatePlaybackState];
          break;
        case AVPlayerItemStatusFailed:
          [self reportError:item.error.localizedDescription ?: @"视频资源加载失败"];
          break;
        default:
          break;
      }
    });
  } else if ([keyPath isEqualToString:@"duration"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self emitLoad];
    });
  }
}

- (void)tearDownPlayer
{
  _hasPendingSeek = NO;
  AVPlayerItem *item = _player.currentItem;
  if (item) {
    @try {
      [item removeObserver:self forKeyPath:@"status"];
      [item removeObserver:self forKeyPath:@"duration"];
    } @catch (__unused NSException *exception) {
    }
  }
  if (_timeObserver) {
    [_player removeTimeObserver:_timeObserver];
    _timeObserver = nil;
  }
  if (_endObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
    _endObserver = nil;
  }
  [_player pause];
  _player = nil;
  _playerLayer.player = nil;
  [_asset.resourceLoader setDelegate:nil queue:nil];
  _asset = nil;
}

- (void)updatePlaybackState
{
  if (!_player) {
    return;
  }
  if (_paused) {
    [_player pause];
  } else {
    [_player play];
  }
}

- (void)seekIfNeeded
{
  if (!isfinite(_seekTo)) {
    return;
  }
  [self seekToSeconds:_seekTo];
}

- (void)seekToSeconds:(double)seconds
{
  double target = MAX(0, seconds);
  _pendingSeekSeconds = target;
  _hasPendingSeek = YES;
  if (!_player) {
    return;
  }
  __weak HlsPlayerView *weakSelf = self;
  [_player seekToTime:CMTimeMakeWithSeconds(target, 600)
      toleranceBefore:kCMTimeZero
       toleranceAfter:kCMTimeZero
    completionHandler:^(BOOL finished) {
    if (!finished) {
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      HlsPlayerView *strongSelf = weakSelf;
      if (strongSelf && strongSelf->_hasPendingSeek && strongSelf->_pendingSeekSeconds == target) {
        [strongSelf emitProgress:target];
        strongSelf->_hasPendingSeek = NO;
      }
    });
  }];
}

#pragma mark - Events

- (std::shared_ptr<const HlsPlayerViewEventEmitter>)emitter
{
  if (!_eventEmitter) {
    return nullptr;
  }
  return std::static_pointer_cast<HlsPlayerViewEventEmitter const>(_eventEmitter);
}

- (void)emitLoad
{
  AVPlayerItem *item = _player.currentItem;
  if (!item) {
    return;
  }
  double seconds = CMTimeGetSeconds(item.duration);
  double duration = isfinite(seconds) ? MAX(0, seconds) : 0;
  if (auto emitter = [self emitter]) {
    emitter->onLoad(HlsPlayerViewEventEmitter::OnLoad{duration});
  }
  if (_hasPendingSeek) {
    [self seekToSeconds:_pendingSeekSeconds];
  }
}

- (void)emitProgress:(double)seconds
{
  if (!isfinite(seconds)) {
    return;
  }
  double durationSeconds = _player.currentItem ? CMTimeGetSeconds(_player.currentItem.duration) : 0;
  double duration = isfinite(durationSeconds) ? MAX(0, durationSeconds) : 0;
  if (auto emitter = [self emitter]) {
    emitter->onProgress(HlsPlayerViewEventEmitter::OnProgress{MAX(0, seconds), duration});
  }
}

- (void)emitEnd
{
  if (auto emitter = [self emitter]) {
    emitter->onEnd(HlsPlayerViewEventEmitter::OnEnd{});
  }
}

- (void)reportError:(NSString *)message
{
  if (auto emitter = [self emitter]) {
    emitter->onError(HlsPlayerViewEventEmitter::OnError{std::string(message.UTF8String ?: "")});
  }
}

#pragma mark - Header / URL helpers

- (NSMutableDictionary<NSString *, NSString *> *)stringHeaders
{
  return [_headers mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (NSURL *)interceptedURLFrom:(NSURL *)source
{
  NSURLComponents *components = [NSURLComponents componentsWithURL:source resolvingAgainstBaseURL:NO];
  components.scheme = kResourceScheme;
  return components.URL;
}

- (NSURL *)remoteURLFromIntercepted:(NSURL *)intercepted
{
  NSURLComponents *components = [NSURLComponents componentsWithURL:intercepted resolvingAgainstBaseURL:NO];
  components.scheme = [_sourceUrl hasPrefix:@"http://"] ? @"http" : @"https";
  return components.URL;
}

- (NSURL *)remoteURLForRequested:(NSURL *)requested
{
  NSString *scheme = requested.scheme.lowercaseString;
  if ([scheme isEqualToString:kResourceScheme]) {
    return [self remoteURLFromIntercepted:requested];
  }
  if ([scheme isEqualToString:@"key"] && _keyUrl.length > 0) {
    return [NSURL URLWithString:_keyUrl];
  }
  return nil;
}

- (NSURLRequest *)mediaRequestForRemote:(NSURL *)remote
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remote];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = 15;
  NSMutableDictionary<NSString *, NSString *> *requestHeaders = [self stringHeaders];
  if (_keyUrl.length > 0) {
    requestHeaders[@"key"] = _keyUrl;
  }
  [requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    [request setValue:value forHTTPHeaderField:key];
  }];
  return request;
}

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{
  NSURL *requested = loadingRequest.request.URL;
  NSURL *remote = [self remoteURLForRequested:requested];
  if (!remote) {
    return NO;
  }
  NSURLRequest *request = [self mediaRequestForRemote:remote];
  // HLS 的 .ts 不能只回填自定义 scheme 数据：先返回 302 让 CoreMedia 用真实 URL 识别资源类型，
  // 再由下载任务向该 loadingRequest 交付数据。
  loadingRequest.redirect = request;
  loadingRequest.response = [[NSHTTPURLResponse alloc] initWithURL:remote
                                                        statusCode:302
                                                       HTTPVersion:@"HTTP/1.1"
                                                      headerFields:nil];
  [self load:request remote:remote forLoadingRequest:loadingRequest];
  return YES;
}

- (void)load:(NSURLRequest *)request remote:(NSURL *)remote forLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
  __weak HlsPlayerView *weakSelf = self;
  NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    HlsPlayerView *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    if (error) {
      [strongSelf finishLoadingRequest:loadingRequest withError:error];
      return;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    if (!httpResponse || httpResponse.statusCode < 200 || httpResponse.statusCode > 299 || !data) {
      NSError *failure = [NSError errorWithDomain:@"MiyingHlsPlayer"
                                             code:httpResponse ? httpResponse.statusCode : -1
                                         userInfo:@{NSLocalizedDescriptionKey: @"播放资源请求失败"}];
      [strongSelf finishLoadingRequest:loadingRequest withError:failure];
      return;
    }
    NSData *body = [strongSelf rewritePlaylistIfNeeded:data remote:remote];
    [strongSelf respond:body toLoadingRequest:loadingRequest];
  }];
  [task resume];
}

- (NSData *)rewritePlaylistIfNeeded:(NSData *)data remote:(NSURL *)remote
{
  if (_keyUrl.length == 0) {
    return data;
  }
  NSString *playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!playlist) {
    return data;
  }
  NSString *lowerPath = remote.path.lowercaseString;
  BOOL isPlaylist = [lowerPath hasSuffix:@".m3u8"] || [playlist hasPrefix:@"#EXTM3U"] || [playlist containsString:@"#EXT-X-KEY"];
  if (!isPlaylist) {
    return data;
  }
  NSString *pattern = @"(#EXT-X-KEY:[^\\r\\n]*URI\\s*=\\s*[\"'])([^\"'\\r\\n]+)([\"'])";
  NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                              options:NSRegularExpressionAnchorsMatchLines
                                                                                error:nil];
  if (!expression) {
    return data;
  }
  NSMutableString *mutablePlaylist = [playlist mutableCopy];
  NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:mutablePlaylist options:0 range:NSMakeRange(0, mutablePlaylist.length)];
  for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
    if (match.numberOfRanges != 4) {
      continue;
    }
    [mutablePlaylist replaceCharactersInRange:[match rangeAtIndex:2] withString:_keyUrl];
  }
  return [mutablePlaylist dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

- (void)respond:(NSData *)data toLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
  // 已经设置 302 的真实 HTTPURLResponse；不要向 contentType 传 MIME 字符串（该字段要求 UTI）。
  [loadingRequest.dataRequest respondWithData:data];
  [loadingRequest finishLoading];
}

- (void)finishLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest withError:(NSError *)error
{
  [loadingRequest finishLoadingWithError:error];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self reportError:error.localizedDescription];
  });
}

#pragma mark - Fullscreen

- (void)presentFullscreen
{
  if (_fullscreenRequest <= _lastFullscreenRequest || !_player || _fullscreenController) {
    return;
  }
  _lastFullscreenRequest = _fullscreenRequest;
  AVPlayerViewController *controller = [[AVPlayerViewController alloc] init];
  controller.player = _player;
  _fullscreenController = controller;
  UIViewController *top = [self topViewControllerFrom:self.window.rootViewController];
  [top presentViewController:controller animated:YES completion:nil];
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)root
{
  if (root.presentedViewController) {
    return [self topViewControllerFrom:root.presentedViewController];
  }
  if ([root isKindOfClass:[UINavigationController class]]) {
    return [self topViewControllerFrom:[(UINavigationController *)root visibleViewController]];
  }
  if ([root isKindOfClass:[UITabBarController class]]) {
    return [self topViewControllerFrom:[(UITabBarController *)root selectedViewController]];
  }
  return root;
}

@end

Class<RCTComponentViewProtocol> HlsPlayerViewCls(void)
{
  return HlsPlayerView.class;
}
