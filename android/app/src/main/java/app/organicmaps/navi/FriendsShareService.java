package app.organicmaps.navi;

import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.os.IBinder;
import androidx.core.app.NotificationChannelCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.ProcessLifecycleOwner;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.navi.friends.FriendsRuntime;
import app.organicmaps.sdk.location.LocationHelper;
import app.organicmaps.sdk.location.LocationListener;
import app.organicmaps.sdk.location.TrackRecorder;
import app.organicmaps.sdk.routing.RoutingController;
import app.organicmaps.sdk.util.LocationUtils;
import java.util.Locale;

/** Visible voluntary sharing, subscribing to the same provider as navigation. */
public final class FriendsShareService extends Service implements LocationListener {
  private static final String CHANNEL = "NAVI_FRIENDS", PAUSE = "navi.friends.PAUSE";
  private static boolean active;
  private FriendsRuntime runtime;
  private LocationHelper locations;
  private AutoCloseable subscription;
  public static boolean isActive() { return active; }
  public static void start(Context context) {
    ContextCompat.startForegroundService(context, new Intent(context, FriendsShareService.class));
  }
  private String t(String de, String en) { return Locale.getDefault().getLanguage().equals("de") ? de : en; }
  @Override public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null && PAUSE.equals(intent.getAction())) {
      if (runtime != null) runtime.setSharing(false);
      stopSelf(); return START_NOT_STICKY;
    }
    runtime = FriendsRuntime.get(this);
    if (!runtime.ready() || !LocationUtils.checkLocationPermission(this)) { stopSelf(); return START_NOT_STICKY; }
    NotificationManagerCompat.from(this).createNotificationChannel(new NotificationChannelCompat.Builder(CHANNEL,
        NotificationManagerCompat.IMPORTANCE_LOW).setName(t("Standortfreigabe", "Location sharing")).build());
    PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, NaviActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    PendingIntent pause = PendingIntent.getService(this, 0, new Intent(this, FriendsShareService.class).setAction(PAUSE), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    ServiceCompat.startForeground(this, 230501, new NotificationCompat.Builder(this, CHANNEL)
        .setSmallIcon(R.drawable.ic_logo_small).setContentTitle(t("Navi · Standortfreigabe", "Navi · location sharing"))
        .setContentText(t("Dein Standort wird mit freigegebenen Freunden geteilt.", "Sharing with friends you have allowed."))
        .setContentIntent(open).setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setOngoing(true)
        .addAction(0, t("Pausieren", "Pause"), pause).build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
    if (!active) {
      active = true;
      subscription = runtime.observe(() -> { if (!runtime.sharingDesired()) stopSelf(); });
      locations = MwmApplication.from(this).getLocationHelper();
      locations.addListener(this); locations.start();
    }
    if (!runtime.sharingDesired()) runtime.setSharing(true).addOnFailureListener(error -> stopSelf());
    return START_NOT_STICKY;
  }
  @Override public void onLocationUpdated(Location location) {
    if (active && runtime != null) runtime.onLocation(location, runtime.isMapVisible());
  }
  @Override public void onLocationDisabled() {
    if (runtime != null) runtime.setSharing(false);
    stopSelf();
  }
  @Override public void onDestroy() {
    active = false;
    if (subscription != null) try { subscription.close(); } catch (Exception ignored) {}
    if (locations != null) {
      locations.removeListener(this);
      if (!ProcessLifecycleOwner.get().getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.STARTED)
          && !RoutingController.get().isNavigating() && !TrackRecorder.nativeIsTrackRecordingEnabled()
          && MwmApplication.from(this).getDisplayManager().isDeviceDisplayUsed()) locations.stop();
    }
    super.onDestroy();
  }
  @Override public IBinder onBind(Intent intent) { return null; }
}
