package app.organicmaps.navi;

import android.Manifest;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.Location;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Editable;
import android.text.TextWatcher;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.core.content.ContextCompat;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragmentActivity;
import app.organicmaps.downloader.DownloaderActivity;
import app.organicmaps.fuel.*;
import app.organicmaps.navi.map.*;
import app.organicmaps.navi.friends.FriendsRuntime;
import app.organicmaps.navi.friends.FriendsSheet;
import app.organicmaps.routing.NavigationService;
import app.organicmaps.sdk.Framework;
import app.organicmaps.sdk.Router;
import app.organicmaps.sdk.location.TrackRecorder;
import app.organicmaps.sdk.bookmarks.data.FeatureId;
import app.organicmaps.sdk.bookmarks.data.MapObject;
import app.organicmaps.sdk.location.LocationHelper;
import app.organicmaps.sdk.location.LocationListener;
import app.organicmaps.sdk.routing.*;
import app.organicmaps.sdk.search.SearchEngine;
import app.organicmaps.sdk.search.SearchListener;
import app.organicmaps.sdk.search.SearchResult;
import app.organicmaps.sdk.settings.RoadType;
import app.organicmaps.sdk.util.LocationUtils;
import app.organicmaps.sdk.util.Config;
import app.organicmaps.util.Utils;
import com.google.android.material.bottomsheet.BottomSheetBehavior;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import org.maplibre.android.MapLibre;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapView;
import java.io.File;
import java.io.IOException;
import java.text.NumberFormat;
import java.util.Date;
import java.util.Locale;

/** New main map. Core, search, provider and foreground navigation service remain shared. */
public final class NaviActivity extends BaseMwmFragmentActivity
    implements RoutingController.Container, LocationListener, SearchListener
{
  private final Handler main = new Handler(Looper.getMainLooper());
  private final RoutingController routing = RoutingController.get();
  private MapView mapView;
  private NaviMapController map;
  private LocationHelper locations;
  private SharedPreferences preferences;
  private VehicleProfile vehicle;
  private VehicleFormView vehicleEditor;
  private NaviRouteSnapshot snapshot;
  private LinearLayout searchRow, results, routePanel, maneuverPanel, lanes;
  private EditText search;
  private TextView mapMessage, routeTime, routeDetails, cost, maneuver, nextStreet, speed;
  private ImageView turnIcon;
  private Button go, cancel, options, mode, limit;
  private View searchOverlay, speedPanel;
  private boolean changingSearch, foreground, mapListenersAttached;
  private long searchGeneration;
  private BasemapMode basemap = BasemapMode.STREET;
  private ActivityResultLauncher<String[]> permission;
  private BottomSheetDialog sheet;
  private Runnable pendingSearch;
  private FriendsRuntime friends;
  private AutoCloseable friendsSubscription;
  private Button friendsButton;
  private boolean pendingFriendSharing;
  private final Runnable tick = new Runnable() {
    @Override public void run() {
      if (!foreground || map == null) return;
      refresh();
      refreshFriends();
      main.postDelayed(this, 500);
    }
  };

  @Override protected void onSafeCreate(@Nullable Bundle saved)
  {
    super.onSafeCreate(saved);
    if (MwmApplication.from(this).getDisplayManager().isCarDisplayUsed())
    {
      startActivity(new Intent(this, app.organicmaps.MapPlaceholderActivity.class));
      finish();
      return;
    }
    preferences = getSharedPreferences("navi-map", MODE_PRIVATE);
    friends = FriendsRuntime.get(this);
    androidx.core.view.WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
    locations = MwmApplication.from(this).getLocationHelper();
    permission = registerForActivityResult(new ActivityResultContracts.RequestMultiplePermissions(), granted -> {
      if (LocationUtils.checkLocationPermission(this)) locations.resumeLocationInForeground();
      if (pendingFriendSharing) {
        pendingFriendSharing = false;
        if (LocationUtils.checkLocationPermission(this)) FriendsShareService.start(this);
      }
      refresh();
    });
    MapLibre.getInstance(this);
    if (saved != null && saved.getBoolean("satellite")) basemap = BasemapMode.SATELLITE;
    FrameLayout root = new FrameLayout(this);
    root.setBackgroundColor(color(R.color.navi_surface));
    mapView = new MapView(this);
    mapView.onCreate(saved);
    root.addView(mapView, new FrameLayout.LayoutParams(-1, -1));

    LinearLayout top = column();
    top.setPadding(dp(16), dp(16), dp(16), 0);
    FrameLayout.LayoutParams topLayout = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
    root.addView(top, topLayout);
    searchRow = row();
    searchRow.setGravity(Gravity.CENTER_VERTICAL);
    LinearLayout searchPill = row();
    searchPill.setGravity(Gravity.CENTER_VERTICAL);
    searchPill.setPadding(dp(18), 0, dp(8), 0);
    searchPill.setBackground(shape(R.color.navi_surface, 30));
    ImageView magnifier = icon(android.R.drawable.ic_menu_search, R.color.navi_ink);
    searchPill.addView(magnifier, new LinearLayout.LayoutParams(dp(24), dp(24)));
    search = new EditText(this);
    search.setSingleLine(true);
    search.setTextSize(17);
    search.setHint(R.string.navi_search);
    search.setTextColor(color(R.color.navi_ink));
    search.setHintTextColor(color(R.color.navi_muted));
    search.setBackground(null);
    search.setPadding(dp(12), 0, dp(8), 0);
    search.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
    searchPill.addView(search, new LinearLayout.LayoutParams(0, dp(56), 1));
    searchRow.addView(searchPill, new LinearLayout.LayoutParams(0, -2, 1));
    ImageButton profile = new ImageButton(this);
    profile.setImageResource(R.drawable.navi_profile);
    profile.setImageTintList(ColorStateList.valueOf(color(R.color.navi_ink)));
    profile.setPadding(dp(16), dp(16), dp(16), dp(16));
    profile.setBackground(shape(R.color.navi_surface, 28));
    profile.setContentDescription(getString(R.string.navi_profile_description));
    profile.setOnClickListener(v -> showProfile());
    LinearLayout.LayoutParams profileLayout = new LinearLayout.LayoutParams(dp(56), dp(56));
    profileLayout.leftMargin = dp(8);
    searchRow.addView(profile, profileLayout);
    top.addView(searchRow);
    maneuverPanel = column();
    maneuverPanel.setPadding(dp(16), dp(16), dp(16), dp(16));
    maneuverPanel.setBackground(shape(R.color.navi_surface, 30));
    LinearLayout instruction = row();
    instruction.setGravity(Gravity.CENTER_VERTICAL);
    turnIcon = icon(app.organicmaps.sdk.R.drawable.ic_turn_straight, R.color.navi_surface);
    turnIcon.setPadding(dp(12), dp(12), dp(12), dp(12));
    turnIcon.setBackground(shape(R.color.navi_ink, 28));
    instruction.addView(turnIcon, new LinearLayout.LayoutParams(dp(56), dp(56)));
    LinearLayout turnTexts = column();
    turnTexts.setPadding(dp(14), 0, 0, 0);
    maneuver = text(21, true);
    nextStreet = text(14, false);
    turnTexts.addView(maneuver);
    turnTexts.addView(nextStreet);
    instruction.addView(turnTexts, new LinearLayout.LayoutParams(0, -2, 1));
    maneuverPanel.addView(instruction);
    lanes = row();
    lanes.setGravity(Gravity.CENTER);
    maneuverPanel.addView(lanes);
    top.addView(maneuverPanel);
    maneuverPanel.setVisibility(View.GONE);

    mapMessage = text(14, false);
    mapMessage.setPadding(dp(18), dp(12), dp(18), dp(12));
    mapMessage.setBackground(shape(R.color.navi_surface, 24));
    mapMessage.setOnClickListener(v -> {
      var status = map.getState().status;
      if (status == MapLoadState.Status.CONFIGURATION_REQUIRED || status == MapLoadState.Status.AUTH_ERROR) showMapAccess();
      else map.retry();
    });
    LinearLayout.LayoutParams messageLayout = new LinearLayout.LayoutParams(-1, -2);
    messageLayout.topMargin = dp(10);
    top.addView(mapMessage, messageLayout);
    ScrollView searchScroll = new ScrollView(this);
    results = column();
    results.setPadding(dp(8), dp(8), dp(8), dp(8));
    results.setBackground(shape(R.color.navi_surface, 28));
    searchScroll.addView(results);
    LinearLayout.LayoutParams resultLayout = new LinearLayout.LayoutParams(-1, dp(280));
    resultLayout.topMargin = dp(10);
    top.addView(searchScroll, resultLayout);
    searchOverlay = searchScroll;
    searchOverlay.setVisibility(View.GONE);

    LinearLayout bottom = column();
    bottom.setPadding(dp(16), 0, dp(16), dp(12));
    root.addView(bottom, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
    LinearLayout dock = row();
    dock.setGravity(Gravity.CENTER_VERTICAL);
    mode = button(R.string.navi_satellite, false);
    mode.setText(basemap == BasemapMode.STREET ? R.string.navi_satellite : R.string.navi_street);
    mode.setOnClickListener(v -> {
      if (basemap == BasemapMode.STREET && !configuration().isConfigured()) { showMapAccess(); return; }
      basemap = basemap == BasemapMode.STREET ? BasemapMode.SATELLITE : BasemapMode.STREET;
      mode.setText(basemap == BasemapMode.STREET ? R.string.navi_satellite : R.string.navi_street);
      map.setBasemap(basemap);
    });
    dock.addView(mode, new LinearLayout.LayoutParams(-2, dp(52)));
    friendsButton = button(0, false);
    friendsButton.setText(friendsText("Freunde", "Friends"));
    friendsButton.setOnClickListener(v -> new FriendsSheet(this, friends, this::startFriendsSharing).show());
    LinearLayout.LayoutParams friendsLayout = new LinearLayout.LayoutParams(-2, dp(52)); friendsLayout.leftMargin = dp(8);
    dock.addView(friendsButton, friendsLayout);
    Space spacer = new Space(this);
    dock.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
    Button position = button(R.string.navi_position, false);
    position.setContentDescription(getString(R.string.navi_position_description));
    position.setOnClickListener(v -> {
      if (!LocationUtils.checkLocationPermission(this)) requestLocation();
      else { locations.resumeLocationInForeground(); map.setFollowing(true); }
    });
    dock.addView(position, new LinearLayout.LayoutParams(dp(56), dp(56)));
    bottom.addView(dock);
    LinearLayout speedRow = row();
    speedRow.setGravity(Gravity.CENTER_VERTICAL);
    speedRow.setPadding(dp(16), dp(8), dp(10), dp(8));
    speedRow.setBackground(shape(R.color.navi_surface, 22));
    speed = text(24, true);
    speedRow.addView(speed);
    limit = button(0, false);
    GradientDrawable sign = shape(R.color.navi_surface, 50);
    sign.setStroke(dp(3), 0xFFC46555);
    limit.setBackground(sign);
    LinearLayout.LayoutParams limitLayout = new LinearLayout.LayoutParams(dp(52), dp(52));
    limitLayout.leftMargin = dp(14);
    speedRow.addView(limit, limitLayout);
    LinearLayout.LayoutParams speedLayout = new LinearLayout.LayoutParams(-2, -2);
    speedLayout.topMargin = dp(12);
    bottom.addView(speedRow, speedLayout);
    speedPanel = speedRow;
    speedPanel.setVisibility(View.GONE);
    routePanel = column();
    routePanel.setPadding(dp(20), dp(20), dp(20), dp(16));
    routePanel.setBackground(shape(R.color.navi_surface, 36));
    routeTime = text(30, true);
    routeDetails = text(14, false);
    cost = text(16, true);
    cost.setOnClickListener(v -> showVehicle());
    routePanel.addView(routeTime);
    routePanel.addView(routeDetails);
    routePanel.addView(cost);
    options = button(R.string.navi_route_options, false);
    options.setOnClickListener(v -> showOptions());
    routePanel.addView(options);
    LinearLayout actions = row();
    go = button(R.string.navi_go, true);
    go.setOnClickListener(v -> startNavigation());
    actions.addView(go, new LinearLayout.LayoutParams(0, -2, 1));
    cancel = button(R.string.navi_close, false);
    cancel.setContentDescription(getString(R.string.navi_stop));
    cancel.setOnClickListener(v -> { routing.cancel(); refresh(); });
    LinearLayout.LayoutParams cancelLayout = new LinearLayout.LayoutParams(dp(56), -2);
    cancelLayout.leftMargin = dp(8);
    actions.addView(cancel, cancelLayout);
    routePanel.addView(actions);
    LinearLayout.LayoutParams panelLayout = new LinearLayout.LayoutParams(-1, -2);
    panelLayout.topMargin = dp(12);
    bottom.addView(routePanel, panelLayout);
    bottom.addOnLayoutChangeListener((view, left, upper, right, lower, oldLeft, oldUpper, oldRight, oldLower) -> {
      if (map != null) map.setBottomInset(lower - upper);
    });
    routePanel.setVisibility(View.GONE);
    setContentView(root);
    boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
        == android.content.res.Configuration.UI_MODE_NIGHT_YES;
    androidx.core.view.WindowCompat.getInsetsController(getWindow(), root).setAppearanceLightStatusBars(!dark);
    androidx.core.view.WindowCompat.getInsetsController(getWindow(), root).setAppearanceLightNavigationBars(!dark);
    ViewCompat.setOnApplyWindowInsetsListener(root, (view, insets) -> {
      var safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout());
      top.setPadding(dp(16) + safe.left, dp(16) + safe.top, dp(16) + safe.right, 0);
      bottom.setPadding(dp(16) + safe.left, 0, dp(16) + safe.right, dp(12) + safe.bottom);
      return insets;
    });
    map = new NaviMapController(mapView, configuration(), this::onMapState);
    map.setFollowing(saved == null || saved.getBoolean("following", routing.isNavigating()));
    map.setBasemap(basemap);
    MapObject end = routing.getEndPoint();
    if (end != null)
    {
      search.setText(end.getTitle());
      map.setTarget(new LatLng(end.getLat(), end.getLon()));
    }
    bottom.addOnLayoutChangeListener((view, left, topEdge, right, bottomEdge, oldLeft, oldTop, oldRight, oldBottom) -> {
      map.setBottomInset(bottom.getHeight());
    });
    locations.setExternalMapReady(true);
    loadVehicle();
    search.addTextChangedListener(new TextWatcher() {
      @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
      @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
        if (!changingSearch) scheduleSearch(s.toString());
      }
      @Override public void afterTextChanged(Editable value) {}
    });
    if (saved != null && saved.containsKey("vehicleDraft")) main.post(() -> showVehicle(saved.getBundle("vehicleDraft")));
  }

  private void onMapState(MapLoadState.Snapshot state)
  {
    if (!mapListenersAttached && map != null && map.getMap() != null)
    {
      mapListenersAttached = true;
      map.getMap().addOnMapLongClickListener(point -> {
        new AlertDialog.Builder(this).setTitle(R.string.navi_map_destination)
            .setPositiveButton(R.string.navi_plan, (dialog, which) -> chooseDestination(
                getString(R.string.navi_map_destination), point.getLatitude(), point.getLongitude()))
            .setNegativeButton(R.string.navi_vehicle_cancel, null).show();
        return true;
      });
      map.getMap().addOnCameraIdleListener(() -> {
        var camera = map.getMap().getCameraPosition();
        if (camera.target != null)
          Framework.nativeSetSearchViewport(camera.target.getLatitude(), camera.target.getLongitude(), (int) camera.zoom);
      });
    }
    int message = switch (state.status) {
      case CONFIGURATION_REQUIRED -> R.string.navi_map_setup;
      case LOADING -> R.string.navi_map_loading;
      case AUTH_ERROR -> R.string.navi_map_auth_error;
      case QUOTA_REACHED -> R.string.navi_map_quota_error;
      case NETWORK_ERROR -> R.string.navi_map_network_error;
      case STYLE_ERROR -> R.string.navi_map_style_error;
      default -> 0;
    };
    mapMessage.setVisibility(message == 0 ? View.GONE : View.VISIBLE);
    if (message != 0) mapMessage.setText(message);
  }

  private EsriMapConfiguration configuration()
  {
    return new EsriMapConfiguration(preferences.getString("key", ""), Locale.getDefault().getLanguage());
  }

  private void scheduleSearch(String query)
  {
    if (pendingSearch != null) main.removeCallbacks(pendingSearch);
    ++searchGeneration;
    SearchEngine.INSTANCE.cancel();
    results.removeAllViews();
    if (query.trim().isEmpty()) { searchOverlay.setVisibility(View.GONE); return; }
    searchOverlay.setVisibility(View.VISIBLE);
    TextView waiting = text(16, false);
    waiting.setText(R.string.navi_searching);
    results.addView(waiting);
    long generation = searchGeneration;
    pendingSearch = () -> {
      Location location = freshLocation();
      boolean started = SearchEngine.INSTANCE.search(this, query.trim(), false, generation, location != null,
          location == null ? 0 : location.getLatitude(), location == null ? 0 : location.getLongitude());
      if (!started && generation == searchGeneration) showSearchEmpty();
    };
    main.postDelayed(pendingSearch, 300);
  }

  @Override public void onResultsUpdate(@NonNull SearchResult[] found, long generation)
  {
    if (generation != searchGeneration || !foreground) return;
    results.removeAllViews();
    for (SearchResult result : found)
    {
      Button item = button(0, false);
      item.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
      item.setText(result.name + (result.description == null ? "" : "\n" + result.description.region));
      item.setOnClickListener(v -> {
        if (result.type == SearchResult.TYPE_PURE_SUGGEST) search.setText(result.suggestion);
        else chooseDestination(result.name, result.lat, result.lon);
      });
      results.addView(item, new LinearLayout.LayoutParams(-1, -2));
    }
  }
  @Override public void onResultsEnd(long generation)
  {
    if (generation == searchGeneration && results.getChildCount() == 0) showSearchEmpty();
  }
  private void showSearchEmpty()
  {
    results.removeAllViews();
    TextView empty = text(16, false);
    empty.setText(R.string.navi_search_empty);
    results.addView(empty);
    Button download = button(R.string.navi_offline_maps, false);
    download.setOnClickListener(v -> startActivity(new Intent(this, DownloaderActivity.class)));
    results.addView(download);
  }

  private void chooseDestination(String title, double latitude, double longitude)
  {
    Location location = freshLocation();
    if (location == null) { toast(R.string.navi_location_needed); requestLocation(); return; }
    SearchEngine.INSTANCE.cancel();
    ++searchGeneration;
    searchOverlay.setVisibility(View.GONE);
    changingSearch = true;
    search.setText(title);
    changingSearch = false;
    search.clearFocus();
    ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(search.getWindowToken(), 0);
    MapObject destination = MapObject.createMapObject(FeatureId.EMPTY, MapObject.POI, title, "", latitude, longitude);
    routing.prepare(locations.getMyPosition(), destination, Router.Vehicle);
    map.setTarget(new LatLng(latitude, longitude));
    refresh();
  }

  private void startNavigation()
  {
    if (snapshot == null || snapshot.state != NaviRouteSnapshot.State.PREVIEW || !routing.isBuilt()) return;
    if (!LocationUtils.checkFineLocationPermission(this) || freshLocation() == null) { requestLocation(); return; }
    routing.start();
    NavigationService.startForegroundService(this);
    map.setFollowing(true);
    refresh();
  }

  private void refresh()
  {
    if (map == null) return;
    Utils.keepScreenOn(foreground && (routing.isNavigating() || Config.isKeepScreenOnEnabled()), getWindow());
    snapshot = Framework.nativeGetNaviRouteSnapshot(map.getGeometryRevision());
    map.render(snapshot);
    Location location = freshLocation();
    map.setLocation(location);
    boolean navigating = snapshot.state == NaviRouteSnapshot.State.NAVIGATING;
    boolean routeExists = snapshot.state != NaviRouteSnapshot.State.NONE;
    routePanel.setVisibility(routeExists ? View.VISIBLE : View.GONE);
    searchRow.setVisibility(navigating ? View.GONE : View.VISIBLE);
    maneuverPanel.setVisibility(navigating ? View.VISIBLE : View.GONE);
    speedPanel.setVisibility(navigating ? View.VISIBLE : View.GONE);
    options.setVisibility(navigating ? View.GONE : View.VISIBLE);
    go.setVisibility(navigating ? View.GONE : View.VISIBLE);
    go.setEnabled(snapshot.state == NaviRouteSnapshot.State.PREVIEW && routing.isBuilt());
    if (!snapshot.isReady())
    {
      routeTime.setText(snapshot.state == NaviRouteSnapshot.State.BUILDING ? R.string.navi_route_building : R.string.navi_route_failed);
      routeDetails.setText(R.string.navi_route_offline_hint);
      cost.setText("");
      return;
    }
    Double seconds = navigating ? snapshot.remainingTimeSeconds : snapshot.totalTimeSeconds;
    Double meters = navigating ? snapshot.remainingDistanceMeters : snapshot.totalDistanceMeters;
    routeTime.setText(getString(R.string.navi_minutes, (int) Math.ceil(seconds / 60)));
    routeDetails.setText(getString(R.string.navi_route_details, number(meters / 1000, 1),
        android.text.format.DateFormat.getTimeFormat(this).format(new Date(System.currentTimeMillis() + (long) (seconds * 1000)))));
    FuelEstimate estimate = FuelCalculator.estimate(meters, vehicle);
    if (estimate.status == FuelEstimate.Status.READY)
      cost.setText(getString(navigating ? R.string.navi_fuel_remaining : R.string.navi_fuel_total, number(estimate.euros, 2)) +
                   "\n" + getString(estimate.source == FuelEstimate.Source.PERSONAL ? R.string.navi_source_personal : R.string.navi_source_wltp,
                       number(estimate.source == FuelEstimate.Source.PERSONAL ? vehicle.personalLitersPer100Km : vehicle.wltpLitersPer100Km, 1),
                       number(vehicle.pricePerLiter, 2)));
    else cost.setText(R.string.navi_vehicle_add);
    if (!navigating) return;
    RoutingInfo info = Framework.nativeGetRouteFollowingInfo();
    if (info != null)
    {
      routing.updateCachedRoutingInfo(info);
      if (info.carDirection.getTurnRes() != 0) info.carDirection.setTurnDrawable(turnIcon);
      maneuver.setText(snapshot.distanceToTurnMeters == null ? getString(R.string.navi_follow_route) :
          getString(R.string.navi_next_turn, number(snapshot.distanceToTurnMeters, 0)));
      nextStreet.setText(snapshot.nextStreet);
      lanes.removeAllViews();
      if (info.lanes != null && info.lanes.length > 0)
      {
        ImageView laneHints = new ImageView(this);
        laneHints.setImageDrawable(new app.organicmaps.widget.LanesDrawable(this, info.lanes,
            color(R.color.navi_ink), color(R.color.navi_muted)));
        lanes.addView(laneHints, new LinearLayout.LayoutParams(-1, dp(40)));
      }
    }
    speed.setText(location != null && location.hasSpeed() && Float.isFinite(location.getSpeed()) && location.getSpeed() >= 0
        ? number(location.getSpeed() * 3.6, 0) + "\nkm/h" : getString(R.string.navi_speed_unknown));
    limit.setVisibility(location != null && snapshot.speedLimitKmh != null && snapshot.speedLimitKmh > 0 ? View.VISIBLE : View.GONE);
    if (snapshot.speedLimitKmh != null) limit.setText(number(snapshot.speedLimitKmh, 0));
  }

  private Location freshLocation()
  {
    if (locations == null || !LocationUtils.checkLocationPermission(this)) return null;
    Location location = locations.getSavedLocation();
    if (location == null) return null;
    long age = SystemClock.elapsedRealtimeNanos() - location.getElapsedRealtimeNanos();
    return age >= 0 && age <= 15_000_000_000L ? location : null;
  }

  private void showProfile()
  {
    LinearLayout content = sheetContent(R.string.navi_profile_description);
    addAction(content, R.string.navi_vehicle_title, this::showVehicle);
    addAction(content, R.string.navi_map_access, this::showMapAccess);
    addAction(content, R.string.navi_offline_maps, () -> { sheet.dismiss(); startActivity(new Intent(this, DownloaderActivity.class)); });
    showSheet(content);
  }
  private void showVehicle()
  {
    showVehicle(null);
  }
  private void showVehicle(Bundle draft)
  {
    if (sheet != null) sheet.dismiss();
    VehicleFormView form = new VehicleFormView(this, () -> { sheet.dismiss(); loadVehicle(); refresh(); }, draft);
    showSheet(form);
    vehicleEditor = form;
  }
  private void loadVehicle()
  {
    try { vehicle = new VehicleStore(new File(getFilesDir(), VehicleStore.FILE_NAME)).load().profile; }
    catch (IOException error) { vehicle = null; }
  }
  private void showMapAccess()
  {
    if (sheet != null) sheet.dismiss();
    LinearLayout content = sheetContent(R.string.navi_map_access);
    TextView help = text(15, false);
    help.setText(R.string.navi_map_access_help);
    content.addView(help);
    EditText key = new EditText(this);
    key.setHint(R.string.navi_map_key);
    key.setText(preferences.getString("key", ""));
    key.setTextColor(color(R.color.navi_ink));
    key.setHintTextColor(color(R.color.navi_muted));
    key.setBackground(shape(R.color.navi_field, 18));
    key.setBackgroundTintList(null);
    key.setPadding(dp(16), 0, dp(16), 0);
    key.setSingleLine(true);
    key.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    content.addView(key, new LinearLayout.LayoutParams(-1, dp(64)));
    addAction(content, R.string.navi_vehicle_save, () -> {
      try
      {
        EsriMapConfiguration configured = new EsriMapConfiguration(key.getText().toString(), Locale.getDefault().getLanguage());
        preferences.edit().putString("key", key.getText().toString().trim()).apply();
        map.setConfiguration(configured);
        sheet.dismiss();
      }
      catch (IllegalArgumentException error) { key.setError(getString(R.string.navi_map_invalid_key)); }
    });
    showSheet(content);
  }
  private void showOptions()
  {
    RoadType[] types = {RoadType.Toll, RoadType.Motorway, RoadType.Ferry, RoadType.Dirty};
    String[] labels = {getString(R.string.navi_avoid_toll), getString(R.string.navi_avoid_motorway),
                       getString(R.string.navi_avoid_ferry), getString(R.string.navi_avoid_unpaved)};
    boolean[] values = new boolean[types.length];
    for (int i = 0; i < values.length; ++i) values[i] = RoutingOptions.hasOption(types[i], Router.Vehicle);
    new AlertDialog.Builder(this).setTitle(R.string.navi_route_options)
        .setMultiChoiceItems(labels, values, (dialog, which, checked) -> values[which] = checked)
        .setNegativeButton(R.string.navi_vehicle_cancel, null)
        .setPositiveButton(R.string.navi_apply, (dialog, which) -> {
          for (int i = 0; i < values.length; ++i)
            if (values[i]) RoutingOptions.addOption(types[i], Router.Vehicle);
            else RoutingOptions.removeOption(types[i], Router.Vehicle);
          routing.checkAndBuildRoute();
        }).show();
  }

  private void showSheet(View content)
  {
    if (sheet != null) sheet.dismiss();
    sheet = new BottomSheetDialog(this);
    BottomSheetDialog owner = sheet;
    sheet.setOnDismissListener(dialog -> { if (sheet == owner) vehicleEditor = null; });
    sheet.setContentView(content);
    sheet.setOnShowListener(dialog -> {
      FrameLayout frame = sheet.findViewById(com.google.android.material.R.id.design_bottom_sheet);
      if (frame != null)
      {
        frame.setBackground(shape(R.color.navi_surface, 36));
        frame.setClipToOutline(true);
        frame.getLayoutParams().height = (int) (getResources().getDisplayMetrics().heightPixels * 0.9);
        BottomSheetBehavior.from(frame).setState(BottomSheetBehavior.STATE_EXPANDED);
      }
    });
    sheet.show();
  }
  private LinearLayout sheetContent(int title)
  {
    LinearLayout content = column();
    content.setPadding(dp(24), dp(24), dp(24), dp(32));
    TextView heading = text(24, true);
    heading.setText(title);
    heading.setPadding(0, 0, 0, dp(20));
    content.addView(heading);
    return content;
  }
  private void addAction(LinearLayout parent, int title, Runnable action)
  {
    Button button = button(title, false);
    button.setOnClickListener(v -> action.run());
    parent.addView(button, new LinearLayout.LayoutParams(-1, -2));
  }

  private void requestLocation() { permission.launch(new String[]{Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION}); }
  private String friendsText(String de, String en) { return Locale.getDefault().getLanguage().equals("de") ? de : en; }
  private void startFriendsSharing() {
    boolean notifications = Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED;
    if (!LocationUtils.checkLocationPermission(this) || !notifications) {
      pendingFriendSharing = true;
      permission.launch(Build.VERSION.SDK_INT >= 33 ? new String[]{Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.POST_NOTIFICATIONS}
          : new String[]{Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION});
    } else FriendsShareService.start(this);
  }
  private void refreshFriends() {
    if (map == null || friends == null) return;
    java.util.ArrayList<NaviMapController.FriendMarker> markers = new java.util.ArrayList<>();
    long now = friends.serverNowMs();
    for (FriendsRuntime.Friend friend : friends.peers()) if (friend.position != null) {
      markers.add(new NaviMapController.FriendMarker(friend.position.latitude, friend.position.longitude,
          friend.name + "\n" + friend.description(now, Locale.getDefault()), friend.fresh(now)));
    }
    map.setFriends(markers);
    if (friendsButton != null) friendsButton.setText(friendsText("Freunde", "Friends") + (markers.isEmpty() ? "" : " · " + markers.size()));
  }
  @Override protected void onStart()
  {
    super.onStart();
    if (mapView == null) return;
    mapView.onStart();
    friendsSubscription = friends.observe(this::refreshFriends);
    refreshFriends();
    locations.addListener(this);
    SearchEngine.INSTANCE.addListener(this);
    routing.attach(this);
    routing.restore();
    if (!routing.isPlanning() && !routing.isNavigating() && routing.hasSavedRoute()) routing.restoreRoute();
  }
  @Override protected void onResume()
  {
    super.onResume();
    if (mapView == null) return;
    foreground = true;
    friends.setMapVisible(true);
    if (friends.sharingDesired() && LocationUtils.checkLocationPermission(this) && !FriendsShareService.isActive()) FriendsShareService.start(this);
    mapView.onResume();
    if (LocationUtils.checkLocationPermission(this)) locations.resumeLocationInForeground();
    else locations.stop();
    loadVehicle();
    main.post(tick);
  }
  @Override protected void onPause()
  {
    foreground = false;
    if (friends != null) friends.setMapVisible(false);
    Utils.keepScreenOn(false, getWindow());
    main.removeCallbacks(tick);
    if (mapView != null) mapView.onPause();
    super.onPause();
  }
  @Override protected void onStop()
  {
    if (mapView != null)
    {
      mapView.onStop();
      locations.removeListener(this);
      SearchEngine.INSTANCE.removeListener(this);
      routing.detach();
      if (friendsSubscription != null) try { friendsSubscription.close(); } catch (Exception ignored) {}
      friendsSubscription = null;
      if (!routing.isNavigating() && !TrackRecorder.nativeIsTrackRecordingEnabled() && !FriendsShareService.isActive()) locations.stop();
    }
    super.onStop();
  }
  @Override protected void onSafeDestroy()
  {
    main.removeCallbacksAndMessages(null);
    if (sheet != null) sheet.dismiss();
    if (map != null) map.destroy();
    if (mapView != null) mapView.onDestroy();
    if (locations != null) locations.setExternalMapReady(false);
    super.onSafeDestroy();
  }
  @Override protected void onSaveInstanceState(@NonNull Bundle state)
  {
    if (mapView != null) mapView.onSaveInstanceState(state);
    state.putBoolean("following", map != null && map.isFollowing());
    state.putBoolean("satellite", basemap == BasemapMode.SATELLITE);
    if (vehicleEditor != null && sheet != null && sheet.isShowing())
    {
      Bundle draft = new Bundle(); vehicleEditor.saveDraft(draft); state.putBundle("vehicleDraft", draft);
    }
    routing.onSaveState();
    super.onSaveInstanceState(state);
  }
  @Override public void onLowMemory() { super.onLowMemory(); if (mapView != null) mapView.onLowMemory(); }
  @Override public void onLocationUpdated(@NonNull Location location) { main.post(() -> { if (foreground) refresh(); }); }
  @Override public void showRoutePlan(boolean show, @Nullable Runnable completion) { if (completion != null) completion.run(); }
  @Override public void onBuiltRoute()
  {
    refresh();
    if (snapshot != null && snapshot.state == NaviRouteSnapshot.State.PREVIEW && !routing.isNavigating())
      map.fitRoute();
  }
  @Override public void onNavigationCancelled() { NavigationService.stopService(this); refresh(); }
  @Override public void onPlanningCancelled() { if (map != null) map.setTarget(null); }
  @Override public void onCommonBuildError(int resultCode, @NonNull String[] missingMaps)
  {
    refresh();
    new AlertDialog.Builder(this).setMessage(R.string.navi_route_offline_hint)
        .setPositiveButton(R.string.navi_offline_maps, (dialog, which) -> startActivity(new Intent(this, DownloaderActivity.class)))
        .setNegativeButton(R.string.navi_vehicle_cancel, null).show();
  }
  @Override public void onBackPressed()
  {
    if (searchOverlay != null && searchOverlay.getVisibility() == View.VISIBLE)
    {
      SearchEngine.INSTANCE.cancel(); ++searchGeneration; searchOverlay.setVisibility(View.GONE); search.clearFocus();
    }
    else super.onBackPressed();
  }

  private LinearLayout row() { LinearLayout value = new LinearLayout(this); value.setOrientation(LinearLayout.HORIZONTAL); return value; }
  private LinearLayout column() { LinearLayout value = new LinearLayout(this); value.setOrientation(LinearLayout.VERTICAL); return value; }
  private TextView text(int size, boolean bold)
  {
    TextView value = new TextView(this);
    value.setTextSize(size);
    value.setTextColor(color(bold ? R.color.navi_ink : R.color.navi_muted));
    if (bold) value.setTypeface(null, Typeface.BOLD);
    return value;
  }
  private Button button(int title, boolean primary)
  {
    Button button = new Button(this);
    if (title != 0) button.setText(title);
    button.setAllCaps(false);
    button.setTextSize(16);
    button.setTextColor(color(primary ? R.color.navi_surface : R.color.navi_ink));
    button.setBackgroundTintList(null);
    button.setBackground(shape(primary ? R.color.navi_ink : R.color.navi_surface, 30));
    button.setMinHeight(dp(52));
    button.setMinimumWidth(0);
    button.setPadding(dp(16), dp(10), dp(16), dp(10));
    return button;
  }
  private ImageView icon(int resource, int tint)
  {
    ImageView icon = new ImageView(this);
    icon.setImageResource(resource);
    icon.setImageTintList(ColorStateList.valueOf(color(tint)));
    return icon;
  }
  private GradientDrawable shape(int color, int radius)
  {
    GradientDrawable drawable = new GradientDrawable(); drawable.setColor(color(color)); drawable.setCornerRadius(dp(radius)); return drawable;
  }
  private int color(int resource) { return ContextCompat.getColor(this, resource); }
  private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
  private String number(double value, int decimals)
  {
    NumberFormat format = NumberFormat.getNumberInstance();
    format.setMinimumFractionDigits(decimals); format.setMaximumFractionDigits(decimals); return format.format(value);
  }
  private void toast(int message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
