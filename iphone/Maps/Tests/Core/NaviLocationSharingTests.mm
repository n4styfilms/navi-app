#import <XCTest/XCTest.h>
#import <CoreLocation/CoreLocation.h>
#import "MWMLocationManager.h"
#import <CoreApi/Framework.h>
#include "platform/location.hpp"

// Exercise the real existing provider's delivery path with synthetic fixes.
@interface MWMLocationManager (NaviSharingTestAccess)
+ (MWMLocationManager *)manager;
+ (void)setFriendsSharingActive:(BOOL)active;
- (void)onLocationUpdate:(CLLocation *)location source:(location::TLocationSource)source;
@end

@interface NaviRawLocationProbe : NSObject<MWMLocationObserver>
@property(nonatomic) NSInteger rawCount;
@property(nonatomic) NSInteger displayCount;
@property(nonatomic, strong) CLLocation * lastRaw;
@end
@implementation NaviRawLocationProbe
- (void)onRawLocationUpdate:(CLLocation *)location { self.rawCount += 1; self.lastRaw = location; }
- (void)onLocationUpdate:(CLLocation *)location { self.displayCount += 1; }
@end

@interface NaviLocationSharingTests : XCTestCase
@end
@implementation NaviLocationSharingTests
- (void)testPredictionDoesNotBecomeAFreshSharedFix {
  XCTestExpectation * finished = [self expectationWithDescription:@"Actual queued location observer delivery"];
  dispatch_async(dispatch_get_main_queue(), ^{
    XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
    NaviRawLocationProbe * probe = [NaviRawLocationProbe new];
    CLLocation * raw = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(43.7295, 7.4208)
      altitude:0 horizontalAccuracy:4 verticalAccuracy:5 course:180 speed:6 timestamp:NSDate.date];
    CLLocation * prediction = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(43.7305, 7.4218)
      altitude:0 horizontalAccuracy:4 verticalAccuracy:5 course:180 speed:6 timestamp:NSDate.date];
    [MWMLocationManager addObserver:probe];
    // Both add/remove enqueue their work. Drain each before injecting a fix;
    // registration may also replay the provider's previous cached location.
    dispatch_async(dispatch_get_main_queue(), ^{
      probe.rawCount = 0; probe.displayCount = 0; probe.lastRaw = nil;
      @try {
        [[MWMLocationManager manager] onLocationUpdate:raw source:location::EAppleNative];
        [[MWMLocationManager manager] onLocationUpdate:prediction source:location::EPredictor];
        XCTAssertEqual(probe.displayCount, 2);
        XCTAssertEqual(probe.rawCount, 1);
        XCTAssertEqualWithAccuracy(probe.lastRaw.coordinate.latitude, raw.coordinate.latitude, 0.0000001);
        XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
      } @finally { [MWMLocationManager removeObserver:probe]; }
      dispatch_async(dispatch_get_main_queue(), ^{
        [[MWMLocationManager manager] onLocationUpdate:raw source:location::EAppleNative];
        XCTAssertEqual(probe.rawCount, 1);
        XCTAssertEqual(probe.displayCount, 2);
        [finished fulfill];
      });
    });
  });
  [self waitForExpectationsWithTimeout:10 handler:nil];
}
- (void)testSharingDemandComposesWithExistingBackgroundConsumers {
  void (^check)(void) = ^{
    BOOL const previous = [MWMLocationManager shouldKeepRunningInBackground];
    @try {
      [MWMLocationManager setFriendsSharingActive:YES];
      XCTAssertTrue([MWMLocationManager shouldKeepRunningInBackground]);
    } @finally { [MWMLocationManager setFriendsSharingActive:NO]; }
    XCTAssertEqual([MWMLocationManager shouldKeepRunningInBackground], previous);
    XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
  };
  if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
}
@end
