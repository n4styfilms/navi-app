#import <Foundation/Foundation.h>
#import "MWMSpeechVoiceCatalog.h"
#include <atomic>

static void require(BOOL value, NSString *message) {
  if (!value) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
static void pumpUntil(BOOL (^done)(void), NSTimeInterval seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done() && [deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  require(done(), @"Main-loop observation timed out");
}
int main() {
  @autoreleasepool {
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    std::atomic<int> calls{0};
    auto *counter = &calls;
    __block BOOL providerOnMain = NO;
    MWMSpeechVoiceCatalog *catalog = [[MWMSpeechVoiceCatalog alloc] initWithProvider:^{
      providerOnMain = NSThread.isMainThread;
      ++(*counter);
      dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
      return @[];
    }];
    __block NSUInteger delivered = 0;
    __block BOOL callbackOffMain = NO;
    void (^completion)(NSArray *) = ^(NSArray *voices) {
      callbackOffMain |= !NSThread.isMainThread;
      require(voices.count == 0, @"An empty voice catalog must remain empty");
      ++delivered;
    };
    [catalog loadWithCompletion:completion];
    [catalog loadWithCompletion:completion];
    __block BOOL heartbeat = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ heartbeat = YES; });
    pumpUntil(^{ return heartbeat && counter->load() == 1; }, 2);
    require(!providerOnMain && !catalog.ready && delivered == 0,
            @"A blocked voice provider must not block the main thread or publish readiness");
    dispatch_semaphore_signal(release);
    pumpUntil(^{ return delivered == 2; }, 2);
    require(catalog.ready && catalog.voices.count == 0 && !callbackOffMain,
            @"Voice snapshot completion must be delivered on the main thread");
    [catalog loadWithCompletion:completion];
    pumpUntil(^{ return delivered == 3; }, 2);
    require(counter->load() == 1, @"Repeated requests must reuse one completed discovery");
    puts("speech_catalog_main_responsive=true");
    puts("speech_catalog_provider_once=true");
    puts("speech_catalog_completions_main=true");
  }
}
