#import <XCTest/XCTest.h>
#import "NaviRouteBridge+Core.h"
#import <CoreApi/Framework.h>
#include "map/routing_manager.hpp"

@interface NaviRouteBridgeTests : XCTestCase
@end

@implementation NaviRouteBridgeTests
- (void)testSearchViewportNeedsNoLegacyRenderer {
  void (^check)(void) = ^{
    auto &framework = GetFramework();
    XCTAssertFalse(framework.IsDrapeEngineCreated());
    // Debug builds assert if this operation reads Drape's uninitialized visual
    // parameters. Include the equator/meridian and extreme zoom inputs.
    [NaviRouteBridge setSearchViewportLatitude:43.7295 longitude:7.4208 zoom:16];
    [NaviRouteBridge setSearchViewportLatitude:0 longitude:0 zoom:0];
    [NaviRouteBridge setSearchViewportLatitude:43.7295 longitude:7.4208 zoom:300];
    XCTAssertFalse(framework.IsDrapeEngineCreated());
  };
  if (NSThread.isMainThread) check();
  else dispatch_sync(dispatch_get_main_queue(), check);
}
- (void)testCopiedValuesAndGeometryRevision {
  navi::RouteSnapshot core;
  core.revision = 42;
  core.state = navi::RouteState::Navigating;
  core.geometry = {{43.7295, 7.4208}, {43.745, 7.427}};
  core.totalDistanceMeters = 120000.125;
  core.remainingDistanceMeters = 123.75;
  core.totalTimeSeconds = 4200.25;
  core.remainingTimeSeconds = 81.5;
  core.distanceToTurnMeters = 9.125;
  core.speedLimitKmh = 50;
  core.nextTurn = 7;
  core.street = "Straße 🚗";
  core.nextStreet = "東京";
  core.turnNotifications = {"Rechts abbiegen"};
  core.roadWarnings = {{navi::RoadWarningType::Toll, {43.7, 7.4}, 2.25},
                       {navi::RoadWarningType::Ferry, {44.7, 7.4}, 3.25},
                       {navi::RoadWarningType::Unpaved, {45.7, 7.4}, 4.25}};
  core.trafficLights = {{43.74, 7.43}};
  core.errorCode = 9;
  auto copied = NaviSnapshotFromCore(core, std::nullopt);
  XCTAssertEqual(copied.revision, 42);
  XCTAssertEqual(copied.state, NaviRouteStateNavigating);
  XCTAssertTrue(copied.geometryIncluded);
  XCTAssertEqual(copied.geometry.count, 2);
  XCTAssertEqual(copied.geometry[0].latitude, 43.7295);
  XCTAssertEqual(copied.geometry[0].longitude, 7.4208);
  XCTAssertEqualObjects(copied.totalDistanceMeters, @120000.125);
  XCTAssertEqualObjects(copied.remainingDistanceMeters, @123.75);
  XCTAssertEqualObjects(copied.totalTimeSeconds, @4200.25);
  XCTAssertEqualObjects(copied.remainingTimeSeconds, @81.5);
  XCTAssertEqualObjects(copied.distanceToTurnMeters, @9.125);
  XCTAssertEqualObjects(copied.speedLimitKmh, @50);
  XCTAssertEqual(copied.nextTurn, 7);
  XCTAssertEqualObjects(copied.street, @"Straße 🚗");
  XCTAssertEqualObjects(copied.nextStreet, @"東京");
  XCTAssertEqualObjects(copied.turnNotifications, (@[@"Rechts abbiegen"]));
  for (NSInteger i = 0; i < 3; ++i) {
    XCTAssertEqual(copied.roadWarnings[i].type, i);
    XCTAssertEqual(copied.roadWarnings[i].position.latitude, 43.7 + i);
    XCTAssertEqual(copied.roadWarnings[i].distanceMeters, 2.25 + i);
  }
  XCTAssertEqual(copied.trafficLights[0].longitude, 7.43);
  XCTAssertEqual(copied.errorCode, 9);
  auto progress = NaviSnapshotFromCore(core, 42);
  XCTAssertFalse(progress.geometryIncluded);
  XCTAssertEqual(progress.geometry.count, 0);
  XCTAssertEqualObjects(progress.remainingDistanceMeters, @123.75);
  core.speedLimitKmh.reset();
  XCTAssertNil(NaviSnapshotFromCore(core, std::nullopt).speedLimitKmh);
  core = {};
  core.revision = 43;
  auto cancelled = NaviSnapshotFromCore(core, 42);
  XCTAssertEqual(cancelled.state, NaviRouteStateNone);
  XCTAssertTrue(cancelled.geometryIncluded);
  XCTAssertEqual(cancelled.geometry.count, 0);
  XCTAssertNil(cancelled.totalDistanceMeters);
  XCTAssertNil(cancelled.remainingDistanceMeters);
  XCTAssertNil(cancelled.totalTimeSeconds);
  XCTAssertNil(cancelled.remainingTimeSeconds);
  XCTAssertNil(cancelled.distanceToTurnMeters);
  XCTAssertNil(cancelled.speedLimitKmh);
  XCTAssertEqual(copied.geometry.count, 2);
  XCTAssertEqualObjects(copied.totalDistanceMeters, @120000.125);
}

// Actual Framework lifecycle, distinct from the mapping test above. No renderer is created here.
- (void)testCoreCancellationInvalidatesRevisionAndIsRepeatable {
  void (^check)(void) = ^{
    auto & manager = GetFramework().GetRoutingManager();
    manager.CloseRouting(true);
    auto first = NaviRouteBridge.snapshot;
    manager.CloseRouting(true);
    auto second = NaviRouteBridge.snapshot;
    XCTAssertEqual(first.state, NaviRouteStateNone);
    XCTAssertEqual(second.state, NaviRouteStateNone);
    XCTAssertGreaterThan(second.revision, first.revision);
    XCTAssertNil(second.totalDistanceMeters);
    XCTAssertEqual(second.geometry.count, 0);
    XCTAssertNil(first.totalDistanceMeters);
  };
  if (NSThread.isMainThread) check();
  else dispatch_sync(dispatch_get_main_queue(), check);
}
@end
