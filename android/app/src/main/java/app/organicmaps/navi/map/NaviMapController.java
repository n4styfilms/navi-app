package app.organicmaps.navi.map;

import static org.maplibre.android.style.layers.PropertyFactory.*;

import android.location.Location;
import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import app.organicmaps.sdk.routing.NaviRouteSnapshot;
import org.maplibre.android.camera.CameraUpdateFactory;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.geometry.LatLngBounds;
import org.maplibre.android.maps.MapLibreMap;
import org.maplibre.android.maps.MapView;
import org.maplibre.android.maps.Style;
import org.maplibre.android.module.http.HttpRequestUtil;
import org.maplibre.android.style.layers.CircleLayer;
import org.maplibre.android.style.layers.LineLayer;
import org.maplibre.android.style.layers.SymbolLayer;
import org.maplibre.android.style.expressions.Expression;
import org.maplibre.android.style.sources.GeoJsonSource;
import org.maplibre.geojson.Feature;
import org.maplibre.geojson.FeatureCollection;
import org.maplibre.geojson.LineString;
import org.maplibre.geojson.Point;

/** Sole visible renderer; location and routing values are supplied by the existing app services. */
public final class NaviMapController
{
  public interface Listener { void onMapStateChanged(MapLoadState.Snapshot state); }
  private static final String ROUTE = "navi-route";
  private static final String POSITION = "navi-position";
  private static final String TARGET = "navi-target";
  private static final String FRIENDS = "navi-friends";
  private FeatureCollection friends = FeatureCollection.fromFeatures(Collections.emptyList());

  public static final class FriendMarker {
    public final double latitude, longitude;
    public final String label;
    public final boolean fresh;
    public FriendMarker(double latitude, double longitude, String label, boolean fresh) {
      this.latitude = latitude; this.longitude = longitude; this.label = label; this.fresh = fresh;
    }
  }

  public void setFriends(List<FriendMarker> markers) {
    requireMainThread();
    List<Feature> copied = new ArrayList<>();
    for (FriendMarker marker : markers) {
      if (!Double.isFinite(marker.latitude) || !Double.isFinite(marker.longitude)
          || Math.abs(marker.latitude) > 90 || Math.abs(marker.longitude) > 180) continue;
      Feature feature = Feature.fromGeometry(Point.fromLngLat(marker.longitude, marker.latitude));
      feature.addStringProperty("label", marker.label);
      feature.addStringProperty("color", marker.fresh ? "#526F4C" : "#858780");
      copied.add(feature);
    }
    friends = FeatureCollection.fromFeatures(copied);
    if (style != null && style.isFullyLoaded()) {
      GeoJsonSource source = style.getSourceAs(FRIENDS);
      if (source != null) source.setGeoJson(friends);
    }
  }
  private final Handler main = new Handler(Looper.getMainLooper());
  private final MapLoadState state = new MapLoadState();
  private final EsriHttpClient http;
  private final Listener listener;
  private final float density;
  private EsriMapConfiguration configuration;
  private MapLibreMap map;
  private Style style;
  private BasemapMode requestedMode = BasemapMode.STREET;
  private final List<Point> route = new ArrayList<>();
  private long geometryRevision = -1;
  private Location location;
  private LatLng target;
  private boolean following;
  private boolean destroyed;
  private boolean routeDirty = true;
  private Runnable loadingDeadline;
  private int bottomInset;
  private long followedSample = -1;

  public NaviMapController(MapView view, EsriMapConfiguration configuration, Listener listener)
  {
    this.configuration = configuration;
    this.listener = listener;
    density = view.getResources().getDisplayMetrics().density;
    http = new EsriHttpClient(configuration, state, (generation, status) -> main.post(() -> {
      if (!destroyed && state.snapshot().generation == generation) notifyState();
    }));
    // The SDK's HTTP logger must never print request details containing credentials.
    HttpRequestUtil.setLogEnabled(false);
    HttpRequestUtil.setPrintRequestUrlOnFailure(false);
    HttpRequestUtil.setOkHttpClient(http.client);
    // MapView's global failure callback has no request/style ID. A late failure there
    // cannot safely fail the newest style; transport errors and the scoped deadline do.
    view.getMapAsync(ready -> {
      if (destroyed) return;
      map = ready;
      map.getUiSettings().setAttributionEnabled(true);
      map.getUiSettings().setLogoEnabled(true);
      applyOrnamentInsets();
      map.setPrefetchesTiles(false);
      map.setPrefetchZoomDelta(0);
      map.addOnCameraMoveStartedListener(reason -> {
        if (reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) following = false;
      });
      load(requestedMode);
    });
  }

  public void setBasemap(BasemapMode mode)
  {
    requireMainThread();
    requestedMode = mode;
    if (map != null && !destroyed) load(mode);
  }

  public void setConfiguration(EsriMapConfiguration configuration)
  {
    requireMainThread();
    this.configuration = configuration;
    http.setConfiguration(configuration);
    if (map != null && !destroyed) load(requestedMode);
  }

  public void retry()
  {
    requireMainThread();
    if (map != null && !destroyed) load(requestedMode);
  }

  private void load(BasemapMode mode)
  {
    if (loadingDeadline != null) main.removeCallbacks(loadingDeadline);
    http.client.dispatcher().cancelAll();
    long generation = state.begin(mode, configuration.canLoad(mode));
    notifyState();
    if (!configuration.canLoad(mode)) return;
    style = null;
    loadingDeadline = () -> {
      if (!destroyed && state.snapshot().generation == generation &&
          state.snapshot().status == MapLoadState.Status.LOADING &&
          state.fail(generation, MapLoadState.Status.STYLE_ERROR)) notifyState();
    };
    main.postDelayed(loadingDeadline, 35000);
    // MapLibre keeps the existing camera during setStyle; never fit/rebuild a route on a style change.
    map.setStyle(new Style.Builder().fromUri(configuration.styleUri(mode).toString()), loaded -> {
      if (destroyed || !state.complete(generation)) return;
      if (loadingDeadline != null) main.removeCallbacks(loadingDeadline);
      style = loaded;
      addOverlays();
      renderOverlays();
      notifyState();
    });
  }

  public long getGeometryRevision() { return geometryRevision; }
  public long getRequestCount() { return http.getRequestCount(); }
  public MapLoadState.Snapshot getState() { return state.snapshot(); }

  public void render(NaviRouteSnapshot snapshot)
  {
    requireMainThread();
    if (!snapshot.isReady())
    {
      routeDirty = routeDirty || !route.isEmpty();
      route.clear();
      geometryRevision = -1;
    }
    else if (snapshot.geometryIncluded)
    {
      routeDirty = true;
      route.clear();
      for (NaviRouteSnapshot.LatLon point : snapshot.geometry)
        route.add(Point.fromLngLat(point.longitude, point.latitude));
      geometryRevision = snapshot.revision;
    }
    renderOverlays();
  }

  public void setTarget(LatLng target)
  {
    requireMainThread();
    this.target = target == null ? null : new LatLng(target.getLatitude(), target.getLongitude());
    renderOverlays();
  }

  public void setLocation(Location location)
  {
    requireMainThread();
    this.location = location == null ? null : new Location(location);
    renderOverlays();
    if (following && this.location != null && map != null && followedSample != this.location.getElapsedRealtimeNanos())
    {
      followedSample = this.location.getElapsedRealtimeNanos();
      LatLng point = new LatLng(this.location.getLatitude(), this.location.getLongitude());
      if (map.getCameraPosition().zoom < 2) map.easeCamera(CameraUpdateFactory.newLatLngZoom(point, 16));
      else map.easeCamera(CameraUpdateFactory.newLatLng(point));
    }
  }

  public boolean isFollowing()
  {
    requireMainThread();
    return following;
  }

  public void setFollowing(boolean following)
  {
    requireMainThread();
    this.following = following;
    followedSample = -1;
    if (following && location != null && map != null)
      map.animateCamera(CameraUpdateFactory.newLatLngZoom(new LatLng(location.getLatitude(), location.getLongitude()), 16));
  }

  public void fitRoute()
  {
    requireMainThread();
    following = false;
    if (map == null || route.size() < 2) return;
    List<LatLng> bounds = new ArrayList<>();
    for (Point point : route) bounds.add(new LatLng(point.latitude(), point.longitude()));
    map.animateCamera(CameraUpdateFactory.newLatLngBounds(new LatLngBounds.Builder().includes(bounds).build(), 64));
  }

  public MapLibreMap getMap() { return map; }

  public void setBottomInset(int pixels)
  {
    requireMainThread();
    bottomInset = Math.max(0, pixels);
    applyOrnamentInsets();
  }
  private void applyOrnamentInsets()
  {
    if (map == null) return;
    // Keep source attribution reachable above the app's route sheet and controls.
    int margin = Math.round(8 * density);
    map.getUiSettings().setAttributionMargins(Math.round(96 * density), 0, margin, bottomInset + margin);
    map.getUiSettings().setLogoMargins(Math.round(16 * density), 0, margin, bottomInset + margin);
  }

  private void addOverlays()
  {
    routeDirty = true;
    FeatureCollection empty = FeatureCollection.fromFeatures(Collections.emptyList());
    style.addSource(new GeoJsonSource(ROUTE, empty));
    style.addSource(new GeoJsonSource(POSITION, empty));
    style.addSource(new GeoJsonSource(TARGET, empty));
    style.addSource(new GeoJsonSource(FRIENDS, friends));
    style.addLayer(new LineLayer("navi-route-outline", ROUTE).withProperties(
        lineColor("#FAF9F5"), lineWidth(9f), lineJoin("round"), lineCap("round")));
    style.addLayer(new LineLayer("navi-route-line", ROUTE).withProperties(
        lineColor("#292C28"), lineWidth(5f), lineJoin("round"), lineCap("round")));
    style.addLayer(new CircleLayer("navi-target-dot", TARGET).withProperties(
        circleColor("#292C28"), circleRadius(7f), circleStrokeColor("#FAF9F5"), circleStrokeWidth(3f)));
    style.addLayer(new CircleLayer("navi-position-dot", POSITION).withProperties(
        circleColor("#526F4C"), circleRadius(8f), circleStrokeColor("#FAF9F5"), circleStrokeWidth(3f)));
    style.addLayer(new CircleLayer("navi-friends-dot", FRIENDS).withProperties(
        circleColor(Expression.get("color")), circleRadius(9f), circleStrokeColor("#FAF9F5"), circleStrokeWidth(3f)));
    style.addLayer(new SymbolLayer("navi-friends-label", FRIENDS).withProperties(
        textField(Expression.get("label")), textFont(new String[]{"Noto Sans Regular"}),
        textSize(12f), textColor("#292C28"),
        textHaloColor("#FAF9F5"), textHaloWidth(2f), textOffset(new Float[]{0f, 1.8f})));
  }

  private void renderOverlays()
  {
    if (style == null || !style.isFullyLoaded()) return;
    GeoJsonSource routeSource = style.getSourceAs(ROUTE);
    if (routeDirty)
    {
      routeSource.setGeoJson(route.size() < 2 ? FeatureCollection.fromFeatures(Collections.emptyList()) :
          FeatureCollection.fromFeatures(Collections.singletonList(Feature.fromGeometry(LineString.fromLngLats(route)))));
      routeDirty = false;
    }
    GeoJsonSource positionSource = style.getSourceAs(POSITION);
    positionSource.setGeoJson(point(location == null ? null : new LatLng(location.getLatitude(), location.getLongitude())));
    GeoJsonSource targetSource = style.getSourceAs(TARGET);
    targetSource.setGeoJson(point(target));
  }

  private FeatureCollection point(LatLng position)
  {
    return position == null ? FeatureCollection.fromFeatures(Collections.emptyList()) :
        FeatureCollection.fromFeatures(Collections.singletonList(Feature.fromGeometry(
            Point.fromLngLat(position.getLongitude(), position.getLatitude()))));
  }

  public void destroy()
  {
    requireMainThread();
    destroyed = true;
    state.detach();
    main.removeCallbacksAndMessages(null);
    http.client.dispatcher().cancelAll();
    style = null;
    map = null;
    // MapView's onDestroy remains the Activity's lifecycle responsibility.
  }

  private void notifyState() { listener.onMapStateChanged(state.snapshot()); }
  private void requireMainThread()
  {
    if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Map GUI thread required");
  }
}
