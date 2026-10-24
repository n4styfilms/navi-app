#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Main-thread snapshots; the system voice provider may block and runs once off-main.
@interface MWMSpeechVoiceCatalog : NSObject
- (instancetype)initWithProvider:(NSArray<AVSpeechSynthesisVoice *> * (^)(void))provider;
- (void)loadWithCompletion:(void (^)(NSArray<AVSpeechSynthesisVoice *> *voices))completion;
@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly) NSArray<AVSpeechSynthesisVoice *> *voices;
@end
NS_ASSUME_NONNULL_END
