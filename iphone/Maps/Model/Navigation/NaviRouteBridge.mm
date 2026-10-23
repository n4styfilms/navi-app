#import "NaviRouteBridge+Core.h"
#import <CoreApi/Framework.h>
#import "MWMRouter.h"
#import "MWMLocationManager.h"
#import <CoreLocation/CoreLocation.h>
#import "SwiftBridge.h"

#include "map/routing_manager.hpp"
#include "map/search_api.hpp"
#include "drape_frontend/visual_params.hpp"
#include "routing/following_info.hpp"
#include "geometry/mercator.hpp"
#include "3party/utfcpp/source/utf8.h"
#include <iterator>
#include <algorithm>

@interface NaviLatLon ()
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude;
@end
@implementation NaviLatLon
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude {
  if ((self = [super init])) {
    _latitude = latitude;
    _longitude = longitude;
  }
  return self;
}
@end

@interface NaviRoadWarning ()
- (instancetype)initWithCore:(navi::RoadWarning const &)warning;
@end
@implementation NaviRoadWarning
- (instancetype)initWithCore:(navi::RoadWarning const &)warning {
  if ((self = [super init])) {
    _type = static_cast<NaviRoadWarningType>(warning.type);
    _position = [[NaviLatLon alloc] initWithLatitude:warning.position.latitude longitude:warning.position.longitude];
    _distanceMeters = warning.distanceMeters;
  }
  return self;
}
@end

namespace {
NSString *Text(std::string const &text) {
  std::string valid;
  utf8::replace_invalid(text.begin(), text.end(), std::back_inserter(valid));
  return [[NSString alloc] initWithBytes:valid.data() length:valid.size() encoding:NSUTF8StringEncoding];
}
NSNumber *Metric(std::optional<double> const &value) {
  return value ? @(*value) : nil;
}
NSArray<NaviLatLon *> *Points(std::vector<navi::LatLon> const &points) {
  NSMutableArray<NaviLatLon *> *result = [NSMutableArray arrayWithCapacity:points.size()];
  for (auto const &point : points)
    [result addObject:[[NaviLatLon alloc] initWithLatitude:point.latitude longitude:point.longitude]];
  return result.copy;
}
}  // namespace

@interface NaviRouteSnapshot ()
- (instancetype)initWithCore:(navi::RouteSnapshot const &)snapshot knownGeometryRevision:(std::optional<uint64_t>)revision;
@end
@implementation NaviRouteSnapshot
- (instancetype)initWithCore:(navi::RouteSnapshot const &)snapshot knownGeometryRevision:(std::optional<uint64_t>)revision {
  if ((self = [super init])) {
    _revision = snapshot.revision;
    _state = static_cast<NaviRouteState>(snapshot.state);
    bool const ready = snapshot.state == navi::RouteState::Preview || snapshot.state == navi::RouteState::Navigating;
    _geometryIncluded = !ready || !revision || *revision != snapshot.revision;
    _geometry = _geometryIncluded ? Points(snapshot.geometry) : @[];
    _totalDistanceMeters = Metric(snapshot.totalDistanceMeters);
    _remainingDistanceMeters = Metric(snapshot.remainingDistanceMeters);
    _totalTimeSeconds = Metric(snapshot.totalTimeSeconds);
    _remainingTimeSeconds = Metric(snapshot.remainingTimeSeconds);
    _distanceToTurnMeters = Metric(snapshot.distanceToTurnMeters);
    _speedLimitKmh = Metric(snapshot.speedLimitKmh);
    _nextTurn = snapshot.nextTurn;
    _street = Text(snapshot.street);
    _nextStreet = Text(snapshot.nextStreet);
    NSMutableArray<NSString *> *notifications = [NSMutableArray arrayWithCapacity:snapshot.turnNotifications.size()];
    for (auto const &text : snapshot.turnNotifications) [notifications addObject:Text(text)];
    _turnNotifications = notifications.copy;
    NSMutableArray<NaviRoadWarning *> *warnings = [NSMutableArray arrayWithCapacity:snapshot.roadWarnings.size()];
    for (auto const &warning : snapshot.roadWarnings)
      [warnings addObject:[[NaviRoadWarning alloc] initWithCore:warning]];
    _roadWarnings = warnings.copy;
    _trafficLights = Points(snapshot.trafficLights);
    _errorCode = snapshot.errorCode;
  }
  return self;
}
@end

NaviRouteSnapshot *NaviSnapshotFromCore(navi::RouteSnapshot const &snapshot,
                                        std::optional<uint64_t> knownGeometryRevision) {
  static_assert(static_cast<int>(navi::RouteState::Failed) == NaviRouteStateFailed);
  static_assert(static_cast<int>(navi::RoadWarningType::Unpaved) == NaviRoadWarningTypeUnpaved);
  return [[NaviRouteSnapshot alloc] initWithCore:snapshot knownGeometryRevision:knownGeometryRevision];
}

@implementation NaviRouteBridge
+ (void)setSearchViewportLatitude:(double)latitude longitude:(double)longitude zoom:(NSInteger)zoom {
  NSAssert(NSThread.isMainThread, @"Search viewport requires the Framework GUI thread");
  if (!mercator::ValidLat(latitude) || !mercator::ValidLon(longitude)) return;
  auto const center = mercator::FromLatLon(latitude, longitude);
  // MapLibre's logical tile size; do not read uninitialized Drape visual parameters.
  auto const rect = df::GetRectForDrawScale(static_cast<int>(std::clamp<NSInteger>(zoom, 0, 20)), center, 512, 1.0);
  GetFramework().GetSearchAPI().OnViewportChanged(rect);
}
+ (NSArray<MWMLaneInfo *> *)lanes {
  NSAssert(NSThread.isMainThread, @"Lane values require the Framework GUI thread");
  routing::FollowingInfo info;
  GetFramework().GetRoutingManager().GetRouteFollowingInfo(info);
  if (!info.IsValid()) return @[];
  NSMutableArray<MWMLaneInfo *> *result = [NSMutableArray arrayWithCapacity:info.m_lanes.size()];
  for (auto const &lane : info.m_lanes) {
    NSMutableArray<NSNumber *> *ways = [NSMutableArray array];
    for (auto const way : lane.laneWays.GetActiveLaneWays()) [ways addObject:@(static_cast<uint8_t>(way))];
    [result addObject:[[MWMLaneInfo alloc] initWithLaneWays:ways recommendedWay:static_cast<uint8_t>(lane.recommendedWay)]];
  }
  return result.copy;
}
+ (BOOL)buildRouteToLatitude:(double)latitude longitude:(double)longitude title:(NSString *)title {
  NSAssert(NSThread.isMainThread, @"Route changes require the Framework GUI thread");
  if (!CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude, longitude)) || ![MWMLocationManager lastLocation])
    return NO;
  auto const point = mercator::FromLatLon(latitude, longitude);
  auto finish = [[MWMRoutePoint alloc] initWithCGPoint:CGPointMake(point.x, point.y) title:title subtitle:@""
                                                type:MWMRoutePointTypeFinish intermediateIndex:0];
  [MWMRouter stopRouting];
  [MWMRouter setType:MWMRouterTypeVehicle];
  [MWMRouter enableAutoAddLastLocation:YES];
  [MWMRouter buildToPoint:finish bestRouter:NO];
  return YES;
}
+ (NaviRouteSnapshot *)snapshot {
  return [self snapshotWithKnownGeometryRevision:nil];
}
+ (NaviRouteSnapshot *)snapshotWithKnownGeometryRevision:(NSNumber *)revision {
  NSAssert(NSThread.isMainThread, @"Route snapshots must be read on the Framework GUI thread");
  std::optional<uint64_t> known;
  if (revision) known = revision.unsignedLongLongValue;
  return NaviSnapshotFromCore(GetFramework().GetRoutingManager().GetRouteSnapshot(), known);
}
@end
