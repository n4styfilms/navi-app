#import <XCTest/XCTest.h>
#import "MWMTextToSpeech+CPP.h"
#include <CoreApi/Framework.h>

@interface MWMTextToSpeechTest : XCTestCase

@end

@implementation MWMTextToSpeechTest

- (void)testAvailableLanguagesSnapshotDuringPreparation {
  MWMTextToSpeech * tts = [MWMTextToSpeech tts];
  std::vector<std::pair<std::string, std::string>> langs = tts.availableLanguages;
  if (!tts.voiceCatalogReady) XCTAssertTrue(langs.empty());
  for (auto const & language : langs) {
    XCTAssertFalse(language.first.empty());
    XCTAssertFalse(language.second.empty());
  }
}
- (void)testStandardLanguage {
  MWMTextToSpeech * tts = [MWMTextToSpeech tts];
  std::pair<std::string, std::string> const defaultLang = std::make_pair("en-US", "English (United States)");
  XCTAssertTrue(tts.standardLanguage == defaultLang);
}
- (void)testRoutingTextLocaleExistsWhilePreparingVoices {
  XCTAssertNotNil([MWMTextToSpeech tts]);
  XCTAssertFalse(GetFramework().GetRoutingManager().GetTurnNotificationsLocale().empty());
}
- (void)testTranslateLocaleWithTwineString {
  XCTAssertEqual(tts::translateLocale("en"), "English");
}

- (void)testTranslateLocaleWithBcp47String {
  XCTAssertEqual(tts::translateLocale("en-US"), "English (United States)");
}

- (void)testTranslateLocaleWithUnknownString {
  XCTAssertEqual(tts::translateLocale("unknown"), "");
}

- (void)testNavigationSoundModeCycle {
  MWMTextToSpeech * tts = [MWMTextToSpeech tts];
  MWMNavigationSoundMode const savedMode = tts.navigationSoundMode;

  tts.navigationSoundMode = MWMNavigationSoundModeVoiceGuidance;
  [tts cycleNavigationSoundMode];
  XCTAssertEqual(tts.navigationSoundMode, MWMNavigationSoundModeSpeedCameraWarningsOnly);
  [tts cycleNavigationSoundMode];
  XCTAssertEqual(tts.navigationSoundMode, MWMNavigationSoundModeMuted);
  [tts cycleNavigationSoundMode];
  XCTAssertEqual(tts.navigationSoundMode, MWMNavigationSoundModeVoiceGuidance);

  tts.navigationSoundMode = savedMode;
}

@end
