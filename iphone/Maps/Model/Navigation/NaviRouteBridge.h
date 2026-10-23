#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MWMLaneInfo;

typedef NS_ENUM(NSInteger, NaviRouteState) {
  NaviRouteStateNone, NaviRouteStateBuilding, NaviRouteStatePreview, NaviRouteStateNavigating, NaviRouteStateFailed
};
typedef NS_ENUM(NSInteger, NaviRoadWarningType) {
  NaviRoadWarningTypeToll, NaviRoadWarningTypeFerry, NaviRoadWarningTypeUnpaved
};

@interface NaviLatLon : NSObject
@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface NaviRoadWarning : NSObject
@property(nonatomic, readonly) NaviRoadWarningType type;
@property(nonatomic, strong, readonly) NaviLatLon *position;
@property(nonatomic, readonly) double distanceMeters;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Immutable copied route values; missing NSNumber metrics are unknown, not zero.
@interface NaviRouteSnapshot : NSObject
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly) NaviRouteState state;
@property(nonatomic, readonly) BOOL geometryIncluded;
@property(nonatomic, copy, readonly) NSArray<NaviLatLon *> *geometry;
@property(nonatomic, strong, readonly, nullable) NSNumber *totalDistanceMeters;
@property(nonatomic, strong, readonly, nullable) NSNumber *remainingDistanceMeters;
@property(nonatomic, strong, readonly, nullable) NSNumber *totalTimeSeconds;
@property(nonatomic, strong, readonly, nullable) NSNumber *remainingTimeSeconds;
@property(nonatomic, strong, readonly, nullable) NSNumber *distanceToTurnMeters;
@property(nonatomic, strong, readonly, nullable) NSNumber *speedLimitKmh;
@property(nonatomic, readonly) NSInteger nextTurn;
@property(nonatomic, copy, readonly) NSString *street;
@property(nonatomic, copy, readonly) NSString *nextStreet;
@property(nonatomic, copy, readonly) NSArray<NSString *> *turnNotifications;
@property(nonatomic, copy, readonly) NSArray<NaviRoadWarning *> *roadWarnings;
@property(nonatomic, copy, readonly) NSArray<NaviLatLon *> *trafficLights;
@property(nonatomic, readonly) NSInteger errorCode;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface NaviRouteBridge : NSObject
+ (void)setSearchViewportLatitude:(double)latitude longitude:(double)longitude zoom:(NSInteger)zoom
    NS_SWIFT_NAME(setSearchViewport(latitude:longitude:zoom:));
@property(class, nonatomic, copy, readonly) NSArray<MWMLaneInfo *> *lanes;
+ (BOOL)buildRouteToLatitude:(double)latitude longitude:(double)longitude title:(NSString *)title
    NS_SWIFT_NAME(buildRoute(toLatitude:longitude:title:));
/// Main/Framework GUI thread only. This bridge never starts a location provider or renderer.
@property(class, nonatomic, readonly) NaviRouteSnapshot *snapshot;
/// Pass nil for a fresh view, otherwise the geometry revision actually drawn.
+ (NaviRouteSnapshot *)snapshotWithKnownGeometryRevision:(nullable NSNumber *)revision
    NS_SWIFT_NAME(snapshot(withKnownGeometryRevision:));
@end

NS_ASSUME_NONNULL_END
