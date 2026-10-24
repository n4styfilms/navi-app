#import "MWMSpeechVoiceCatalog.h"

@implementation MWMSpeechVoiceCatalog {
  NSArray<AVSpeechSynthesisVoice *> * (^_provider)(void);
  NSMutableArray<void (^)(NSArray<AVSpeechSynthesisVoice *> *)> *_completions;
  NSArray<AVSpeechSynthesisVoice *> *_voices;
  BOOL _loading;
  BOOL _ready;
}
- (instancetype)initWithProvider:(NSArray<AVSpeechSynthesisVoice *> * (^)(void))provider {
  self = [super init];
  if (self) {
    _provider = [provider copy];
    _completions = [NSMutableArray array];
    _voices = @[];
  }
  return self;
}
- (BOOL)isReady { return _ready; }
- (NSArray<AVSpeechSynthesisVoice *> *)voices { return _voices; }
- (void)loadWithCompletion:(void (^)(NSArray<AVSpeechSynthesisVoice *> *))completion {
  NSAssert(NSThread.isMainThread, @"Speech snapshots require the main thread");
  if (_ready) { completion(_voices); return; }
  [_completions addObject:[completion copy]];
  if (_loading) return;
  _loading = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSArray<AVSpeechSynthesisVoice *> *voices = [self->_provider() copy] ?: @[];
      dispatch_async(dispatch_get_main_queue(), ^{
        self->_voices = voices;
        self->_ready = YES;
        self->_provider = nil;
        NSArray *callbacks = [self->_completions copy];
        [self->_completions removeAllObjects];
        for (void (^callback)(NSArray *) in callbacks) callback(voices);
      });
    }
  });
}
@end
