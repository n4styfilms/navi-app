#import <XCTest/XCTest.h>
#import <CoreApi/Framework.h>
#include "map/gps_track.hpp"
#include "map/track_statistics.hpp"
#include <chrono>
#include <thread>

namespace {
bool WaitForTrackSize(GpsTrack const & track, size_t size) {
  auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (track.GetSize() != size && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return track.GetSize() == size;
}
}

@interface NaviTrackRecordingTests : XCTestCase
@end
@implementation NaviTrackRecordingTests
- (void)testHeadlessRecordingRestoresProgressAndMeasurementQuality {
  XCTestExpectation * finished = [self expectationWithDescription:@"Actual recorder worker without drawing callback"];
  NSString * path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [@"navi-track-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  dispatch_async(dispatch_get_main_queue(), ^{
    XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      location::GpsInfo first;
      first.m_timestamp = 1000; first.m_latitude = 43.7295; first.m_longitude = 7.4208;
      first.m_speed = 5; first.m_horizontalAccuracy = 4; first.m_source = location::EAppleNative;
      auto second = first; second.m_timestamp += 1; second.m_longitude += 0.001;
      {
        GpsTrack track(path.UTF8String);
        track.AddPoints({first, second});
        XCTAssertTrue(WaitForTrackSize(track, 2), @"Recording progress requires an attached renderer");
        XCTAssertFalse(track.IsEmpty());
        XCTAssertGreaterThan(track.GetTrackStatistics().m_length, 50.0);
      } // Join the real worker and close its flushed storage before reopening.
      {
        GpsTrack restored(path.UTF8String);
        restored.AddPoints({});
        XCTAssertTrue(WaitForTrackSize(restored, 2), @"Stored recording was not restored without drawing");
        size_t count = 0;
        restored.ForEachPoint([&](location::GpsInfo const & point, size_t) {
          ++count;
          XCTAssertEqual(point.m_source, location::EAppleNative);
          XCTAssertEqual(point.m_horizontalAccuracy, 4);
          XCTAssertEqual(point.m_speed, 5);
          return true;
        });
        XCTAssertEqual(count, 2);
        restored.Clear();
        XCTAssertTrue(WaitForTrackSize(restored, 0));
      }
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        XCTAssertFalse(GetFramework().IsDrapeEngineCreated());
        [finished fulfill];
      });
    });
  });
  [self waitForExpectationsWithTimeout:12 handler:nil];
}
@end
