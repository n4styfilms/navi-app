package app.navi.mapprobe;

import android.graphics.RectF;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.appcompat.app.AppCompatActivity;
import app.organicmaps.navi.map.EsriMapConfiguration;
import app.organicmaps.navi.map.NaviMapController;
import java.util.Collections;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.maplibre.android.MapLibre;
import org.maplibre.android.camera.CameraUpdateFactory;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapView;
import org.maplibre.android.module.http.HttpRequestUtil;

/** Actual GL regression: shipping controller, public font bytes, no network or Firebase data. */
public final class FriendLabelsActivity extends AppCompatActivity {
  private MapView view;
  private NaviMapController controller;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private int attempts;
  private int phase;
  private volatile boolean unavailableFontRequested;

  @Override public void onCreate(Bundle saved) {
    super.onCreate(saved);
    MapLibre.getInstance(this);
    view = new MapView(this);
    view.onCreate(saved);
    setContentView(view);
    controller = new NaviMapController(view, new EsriMapConfiguration("", "de"), state -> {});
    // Return only deterministic public fixture data. No certificate/trust override and no live requests.
    HttpRequestUtil.setOkHttpClient(new OkHttpClient.Builder().addInterceptor(chain -> {
      String path = chain.request().url().encodedPath();
      byte[] bytes;
      int code = 200;
      if (path.equals("/styles/liberty")) {
        bytes = ("{\"version\":8,\"glyphs\":\"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf\","
            + "\"sources\":{},\"layers\":[{\"id\":\"background\",\"type\":\"background\","
            + "\"paint\":{\"background-color\":\"#f5f3eb\"}}]}")
            .getBytes(java.nio.charset.StandardCharsets.UTF_8);
      } else if (path.equals("/fonts/Noto%20Sans%20Regular/0-255.pbf")) {
        try (var stream = getAssets().open("noto-0-255.pbf")) { bytes = stream.readAllBytes(); }
      } else {
        unavailableFontRequested = true;
        code = 404;
        bytes = new byte[0];
        Log.e("NaviFriendLabels", "UNAVAILABLE_FONT " + path);
      }
      return new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
          .code(code).message(code == 200 ? "OK" : "Not Found")
          .body(ResponseBody.create(bytes, null)).build();
    }).build());
    controller.setFriends(Collections.singletonList(
        new NaviMapController.FriendMarker(43.7295, 7.4208, "Alice test · 29 km/h", true)));
    view.getMapAsync(map -> {
      map.moveCamera(CameraUpdateFactory.newLatLngZoom(new LatLng(43.7295, 7.4208), 16));
      handler.postDelayed(this::checkRendered, 1000);
    });
  }

  private void checkRendered() {
    var map = controller.getMap();
    var bounds = new RectF(0, 0, view.getWidth(), view.getHeight());
    int dots = map.queryRenderedFeatures(bounds, "navi-friends-dot").size();
    var labels = map.queryRenderedFeatures(bounds, "navi-friends-label");
    boolean labelRendered = dots > 0 && labels.size() > 0 && !unavailableFontRequested
        && "Alice test · 29 km/h".equals(labels.get(0).getStringProperty("label"));
    if (phase < 2 && labelRendered) {
      Log.i("NaviFriendLabels", phase == 0 ? "PASS actual friend dot and label rendered"
          : "PASS friend label survives style reload without route or camera change");
      if (phase == 0) {
        phase = 1;
        controller.retry();
      } else {
        var camera = map.getCameraPosition();
        if (Math.abs(camera.target.getLatitude() - 43.7295) > 0.00001
            || Math.abs(camera.target.getLongitude() - 7.4208) > 0.00001
            || Math.abs(camera.zoom - 16) > 0.001)
          throw new AssertionError("Friends changed the map camera");
        phase = 2;
        controller.setFriends(Collections.emptyList());
      }
      attempts = 0;
      handler.postDelayed(this::checkRendered, 1000);
    } else if (phase == 2 && dots == 0 && labels.isEmpty()) {
      Log.i("NaviFriendLabels", "PASS cleared peers remove actual friend dot and label");
    } else if (++attempts < 15) {
      handler.postDelayed(this::checkRendered, 1000);
    } else {
      Log.e("NaviFriendLabels", "FAIL dots=" + dots + " labels=" + labels.size()
          + " unavailableFont=" + unavailableFontRequested);
    }
  }

  @Override public void onStart() { super.onStart(); view.onStart(); }
  @Override public void onResume() { super.onResume(); view.onResume(); }
  @Override public void onPause() { view.onPause(); super.onPause(); }
  @Override public void onStop() { view.onStop(); super.onStop(); }
  @Override public void onDestroy() {
    handler.removeCallbacksAndMessages(null);
    controller.destroy();
    view.onDestroy();
    super.onDestroy();
  }
}
