#import "MWMFrameworkHelper.h"
#import "MWMMapSearchResult+Core.h"
#import "TrackInfo+Core.h"
#import "ElevationProfileData+Core.h"

#include "Framework.h"

#include "base/sunrise_sunset.hpp"

#include "platform/local_country_file_utils.hpp"
#include "platform/network_policy_ios.h"

#include <cmath>
#include <exception>

namespace {
NSDictionary<NSString *, id> * NaviTripMetadata(navi::TripMetadata const & trip) {
  return @{@"id": @(trip.id.c_str()), @"passenger": @(trip.role == navi::TripRole::Passenger),
           @"startedAtMs": @(trip.startedAtMs), @"endedAtMs": @(trip.endedAtMs)};
}
}

@implementation MWMFrameworkHelper

+ (void)processFirstLaunch:(BOOL)hasLocation {
  auto &f = GetFramework();
  if (!hasLocation)
    f.StartPendingPositionMode();
  else
    f.RunFirstLaunchAnimation();
}

+ (void)setVisibleViewport:(CGRect)rect scaleFactor:(CGFloat)scale {
  if (!std::isfinite(scale) || scale <= 0)
    return;
  CGFloat const x0 = rect.origin.x * scale;
  CGFloat const y0 = rect.origin.y * scale;
  CGFloat const x1 = x0 + rect.size.width * scale;
  CGFloat const y1 = y0 + rect.size.height * scale;
  // Drop degenerate viewports that often happen on CarPlay scene handovers
  if (!std::isfinite(x0) || !std::isfinite(y0) || !std::isfinite(x1) || !std::isfinite(y1) ||
      x1 <= x0 || y1 <= y0)
    return;
  GetFramework().SetVisibleViewport(m2::RectD(x0, y0, x1, y1));
}

+ (void)setTheme:(MWMTheme)theme {
  auto &f = GetFramework();

  auto const mapAppearance = f.CurrentMapAppearance();
  auto const newMapAppearance = ^MapAppearance(MWMTheme theme) {
    switch (theme) {
      case MWMThemeDay:
        return MapAppearance::Light;
      case MWMThemeVehicleDay:
        return MapAppearance::Light;
      case MWMThemeNight:
        return MapAppearance::Dark;
      case MWMThemeVehicleNight:
        return MapAppearance::Dark;
      case MWMThemeAuto:
        NSAssert(NO, @"Invalid theme");
        return MapAppearance::Light;
    }
  }(theme);
  if (mapAppearance != newMapAppearance)
    f.SwitchToMapAppearance(newMapAppearance);

  auto const isUsingVehicleStyle = f.IsUsingVehicleStyle();
  auto const newIsUsingVehicleStyle = ^bool(MWMTheme theme) {
    switch (theme) {
      case MWMThemeDay:
        return false;
      case MWMThemeVehicleDay:
        return true;
      case MWMThemeNight:
        return false;
      case MWMThemeVehicleNight:
        return true;
      case MWMThemeAuto:
        NSAssert(NO, @"Invalid theme");
        return false;
    }
  }(theme);
  if (isUsingVehicleStyle != newIsUsingVehicleStyle)
    f.SwitchToUsingVehicleStyle(newIsUsingVehicleStyle);
}

+ (MWMDayTime)daytimeAtLocation:(CLLocation *)location {
  if (!location)
    return MWMDayTimeDay;
  DayTimeType dayTime =
    GetDayTime(NSDate.date.timeIntervalSince1970, location.coordinate.latitude, location.coordinate.longitude);
  switch (dayTime) {
    case DayTimeType::Day:
    case DayTimeType::PolarDay:
      return MWMDayTimeDay;
    case DayTimeType::Night:
    case DayTimeType::PolarNight:
      return MWMDayTimeNight;
  }
}

+ (void)createFramework {
  UNUSED_VALUE(GetFramework());
}

+ (MWMMarkID)invalidBookmarkId {
  return kml::kInvalidMarkId;
}

+ (MWMMarkGroupID)invalidCategoryId {
  return kml::kInvalidMarkGroupId;
}

+ (NSArray<NSString *> *)obtainLastSearchQueries {
  NSMutableArray *result = [NSMutableArray array];
  auto const &queries = GetFramework().GetSearchAPI().GetLastSearchQueries();
  for (auto const &item : queries) {
    [result addObject:@(item.second.c_str())];
  }
  return [result copy];
}

#pragma mark - Map Interaction

+ (void)zoomMap:(MWMZoomMode)mode {
  switch (mode) {
    case MWMZoomModeIn:
      GetFramework().Scale(Framework::SCALE_MAG, true);
      break;
    case MWMZoomModeOut:
      GetFramework().Scale(Framework::SCALE_MIN, true);
      break;
  }
}

+ (void)moveMap:(UIOffset)offset {
  GetFramework().Move(offset.horizontal, offset.vertical, true);
}

+ (void)scrollMapToDistanceX:(double)x andY:(double)y
{
  GetFramework().Scroll(x, y);
}

+ (void)deactivateMapSelection {
  GetFramework().DeactivateMapSelection();
}

+ (void)switchMyPositionMode {
  GetFramework().SwitchMyPositionNextMode();
}

+ (void)stopLocationFollow {
  GetFramework().StopLocationFollow();
}

+ (void)rotateMap:(double)azimuth animated:(BOOL)isAnimated {
  GetFramework().Rotate(azimuth, isAnimated);
}

+ (void)updatePositionArrowOffset:(BOOL)useDefault offset:(int)offsetY {
  GetFramework().UpdateMyPositionRoutingOffset(useDefault, offsetY);
}

+ (int64_t)dataVersion {
  return GetFramework().GetCurrentDataVersion();
}

+ (void)searchInDownloader:(NSString *)query
               inputLocale:(NSString *)locale
                completion:(SearchInDownloaderCompletions)completion {
  storage::DownloaderSearchParams params{
    query.UTF8String,
    locale.precomposedStringWithCompatibilityMapping.UTF8String,
    // m_onResults
    [completion](storage::DownloaderSearchResults const & results)
    {
      NSMutableArray *resultsArray = [NSMutableArray arrayWithCapacity:results.m_results.size()];
      for (auto const & res : results.m_results)
      {
        MWMMapSearchResult *result = [[MWMMapSearchResult alloc] initWithSearchResult:res];
        [resultsArray addObject:result];
      }
      completion(resultsArray, results.m_endMarker);
    }
  };

  GetFramework().GetSearchAPI().SearchInDownloader(std::move(params));
}

+ (BOOL)canEditMapAtViewportCenter {
  auto const &f = GetFramework();
  return f.CanEditMapForPosition(f.GetViewportCenter());
}

+ (void)showOnMap:(MWMMarkGroupID)categoryId {
  GetFramework().ShowBookmarkCategory(categoryId);
}

+ (void)showBookmark:(MWMMarkID)bookmarkId {
  GetFramework().ShowBookmark(bookmarkId);
}

+ (void)showTrack:(MWMTrackID)trackId {
  GetFramework().ShowTrack(trackId);
}

+ (void)saveRouteAsTrack {
  GetFramework().SaveRoute();
}

+ (void)updatePlacePageData {
  GetFramework().UpdatePlacePageInfoForCurrentSelection();
}

+ (void)updateAfterDeleteBookmark {
  auto & frm = GetFramework();
  auto buildInfo = frm.GetCurrentPlacePageInfo().GetBuildInfo();
  buildInfo.m_match = place_page::BuildInfo::Match::FeatureOnly;
  buildInfo.m_userMarkId = kml::kInvalidMarkId;
  buildInfo.m_source = place_page::BuildInfo::Source::Other;
  frm.UpdatePlacePageInfoForCurrentSelection(buildInfo);
}

+ (int)currentZoomLevel {
  return GetFramework().GetDrawScale();
}

// MARK: - TrackRecorder

+ (void)startTrackRecording {
  GetFramework().StartTrackRecording();
}

+ (void)setTrackRecordingUpdateHandler:(TrackRecordingUpdatedHandler _Nullable)trackRecordingDidUpdate {
  if (!trackRecordingDidUpdate)
  {
    GetFramework().SetTrackRecordingUpdateHandler(nullptr);
    return;
  }
  GetFramework().SetTrackRecordingUpdateHandler([trackRecordingDidUpdate](TrackStatistics const & statistics) {
    TrackInfo * info = [[TrackInfo alloc] initWithTrackStatistics:statistics];
    trackRecordingDidUpdate(info);
  });
}

+ (void)stopTrackRecording {
  GetFramework().StopTrackRecording();
}

+ (BOOL)startNaviTripWithIdentifier:(NSString *)identifier passenger:(BOOL)passenger startedAtMs:(int64_t)startedAtMs {
  try {
    auto & framework = GetFramework();
    auto store = framework.GetNaviTripStore();
    auto const role = passenger ? navi::TripRole::Passenger : navi::TripRole::Driver;
    framework.StartNaviTrip(store, identifier.UTF8String, role, startedAtMs);
    return YES;
  } catch (std::exception const &) {
    return NO;
  }
}

+ (void)stopNaviTripAtMs:(int64_t)endedAtMs completion:(void (^)(NaviTripArchiveStatus status))completion {
  try {
    auto & framework = GetFramework();
    auto store = framework.GetNaviTripStore();
    framework.StopNaviTrip(store, endedAtMs, [completion](navi::TripArchiveResult result) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(static_cast<NaviTripArchiveStatus>(result));
      });
    });
  } catch (std::exception const &) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NaviTripArchiveStatusFailed); });
  }
}

+ (NSDictionary<NSString *, id> *)naviTripState {
  try {
    auto & framework = GetFramework();
    auto store = framework.GetNaviTripStore();
    auto const pending = store.Pending();
    NSMutableArray<NSDictionary<NSString *, id> *> * trips = [NSMutableArray array];
    for (auto const & trip : store.List())
      [trips addObject:NaviTripMetadata(trip)];
    NSMutableDictionary<NSString *, id> * result = [@{@"trips": trips} mutableCopy];
    if (pending)
      result[@"pending"] = NaviTripMetadata(*pending);
    return result;
  } catch (std::exception const &) {
    return nil;
  }
}

+ (NSDictionary<NSString *, id> *)naviTripStatisticsForIdentifier:(NSString *)identifier {
  try {
    auto const analysis = GetFramework().GetNaviTripStore().Load(identifier.UTF8String);
    NSMutableDictionary<NSString *, id> * result = [@{@"distanceMeters": @(analysis.distanceMeters),
      @"coveredSeconds": @(analysis.coveredSeconds), @"gapCount": @(analysis.gapCount),
      @"rejectedCount": @(analysis.rejected.size()), @"rawCount": @(analysis.rawCount)} mutableCopy];
    if (analysis.maximumSpeedMetersPerSecond)
      result[@"maximumSpeedMetersPerSecond"] = @(*analysis.maximumSpeedMetersPerSecond);
    return result;
  } catch (std::exception const &) {
    return nil;
  }
}

+ (BOOL)setNaviTripPassenger:(BOOL)passenger identifier:(NSString *)identifier {
  try {
    auto const role = passenger ? navi::TripRole::Passenger : navi::TripRole::Driver;
    GetFramework().GetNaviTripStore().SetRole(identifier.UTF8String, role);
    return YES;
  } catch (std::exception const &) {
    return NO;
  }
}

+ (BOOL)deleteNaviTripWithIdentifier:(NSString *)identifier {
  try {
    GetFramework().GetNaviTripStore().Delete(identifier.UTF8String);
    return YES;
  } catch (std::exception const &) {
    return NO;
  }
}

+ (void)saveTrackRecordingWithName:(nonnull NSString *)name {
  GetFramework().SaveTrackRecordingWithName(name.UTF8String);
}

+ (BOOL)isTrackRecordingEnabled {
  return GetFramework().IsTrackRecordingEnabled();
}

+ (BOOL)isTrackRecordingEmpty {
  return GetFramework().IsTrackRecordingEmpty();
}

+ (ElevationProfileData * _Nonnull)trackRecordingElevationInfo {
  return [[ElevationProfileData alloc] initWithElevationInfo:GetFramework().GetTrackRecordingElevationInfo()];
}

+ (void)setCarScreenMode:(BOOL)enabled {
  GetFramework().SetCarScreenMode(enabled);
}

@end
