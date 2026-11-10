#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

#import "MWMTypes.h"

@class MWMMapSearchResult;
@class TrackInfo;
@class ElevationProfileData;

typedef NS_ENUM(NSUInteger, MWMZoomMode) { MWMZoomModeIn = 0, MWMZoomModeOut };
typedef NS_ENUM(NSInteger, NaviTripArchiveStatus) {
  NaviTripArchiveStatusFailed = 0, NaviTripArchiveStatusEmpty = 1, NaviTripArchiveStatusSaved = 2
};

NS_ASSUME_NONNULL_BEGIN

typedef void (^SearchInDownloaderCompletions)(NSArray<MWMMapSearchResult *> *results, BOOL finished);
typedef void (^TrackRecordingUpdatedHandler)(TrackInfo * _Nonnull trackInfo);

@protocol TrackRecorder

+ (void)startTrackRecording;
+ (void)setTrackRecordingUpdateHandler:(TrackRecordingUpdatedHandler _Nullable)trackRecordingDidUpdate;
+ (void)stopTrackRecording;
+ (void)saveTrackRecordingWithName:(nonnull NSString *)name;
+ (BOOL)isTrackRecordingEnabled;
+ (BOOL)isTrackRecordingEmpty;
/// Returns current track recording elevation info.
/// If the track recording is not in progress, returns empty ElevationProfileData.
+ (ElevationProfileData * _Nonnull)trackRecordingElevationInfo;

@end

NS_SWIFT_NAME(FrameworkHelper)
@interface MWMFrameworkHelper : NSObject<TrackRecorder>

+ (void)processFirstLaunch:(BOOL)hasLocation;
+ (void)setVisibleViewport:(CGRect)rect scaleFactor:(CGFloat)scale;
+ (void)setTheme:(MWMTheme)theme;
+ (MWMDayTime)daytimeAtLocation:(nullable CLLocation *)location;
+ (void)createFramework;
+ (MWMMarkID)invalidBookmarkId;
+ (MWMMarkGroupID)invalidCategoryId;
+ (void)zoomMap:(MWMZoomMode)mode;
+ (void)moveMap:(UIOffset)offset;
+ (void)scrollMapToDistanceX:(double)x andY:(double)y;
+ (void)deactivateMapSelection;
+ (void)switchMyPositionMode;
+ (void)stopLocationFollow;
+ (NSArray<NSString *> *)obtainLastSearchQueries;
+ (void)rotateMap:(double)azimuth animated:(BOOL)isAnimated;
+ (void)updatePositionArrowOffset:(BOOL)useDefault offset:(int)offsetY;
+ (int64_t)dataVersion;
+ (void)searchInDownloader:(NSString *)query
               inputLocale:(NSString *)locale
                completion:(SearchInDownloaderCompletions)completion;
+ (BOOL)canEditMapAtViewportCenter;
+ (void)showOnMap:(MWMMarkGroupID)categoryId;
+ (void)showBookmark:(MWMMarkID)bookmarkId;
+ (void)showTrack:(MWMTrackID)trackId;
+ (void)saveRouteAsTrack;
+ (void)updatePlacePageData;
+ (void)updateAfterDeleteBookmark;
+ (int)currentZoomLevel;
+ (void)setCarScreenMode:(BOOL)enabled;
+ (BOOL)startNaviTripWithIdentifier:(NSString *)identifier passenger:(BOOL)passenger startedAtMs:(int64_t)startedAtMs
    NS_SWIFT_NAME(startNaviTrip(id:passenger:startedAtMs:));
+ (void)stopNaviTripAtMs:(int64_t)endedAtMs completion:(void (^)(NaviTripArchiveStatus status))completion
    NS_SWIFT_NAME(stopNaviTrip(endedAtMs:completion:));
+ (nullable NSDictionary<NSString *, id> *)naviTripState;
+ (nullable NSDictionary<NSString *, id> *)naviTripStatisticsForIdentifier:(NSString *)identifier
    NS_SWIFT_NAME(naviTripStatistics(id:));
+ (BOOL)setNaviTripPassenger:(BOOL)passenger identifier:(NSString *)identifier
    NS_SWIFT_NAME(setNaviTripPassenger(_:id:));
+ (BOOL)deleteNaviTripWithIdentifier:(NSString *)identifier NS_SWIFT_NAME(deleteNaviTrip(id:));

@end

NS_ASSUME_NONNULL_END
