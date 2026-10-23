import app.organicmaps.navi.map.*;
import java.net.URI;

/** Network-free behavior tests for the actual configuration/load policy, not rendered-map evidence. */
public final class MapStateProbe
{
  static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
  public static void main(String[] args)
  {
    String key = "TEST_SECRET_never_in_errors";
    var config = new EsriMapConfiguration(key, "de-DE");
    check(config.isConfigured(), "configured");
    String street = config.styleUri(BasemapMode.STREET).toString();
    String satellite = config.styleUri(BasemapMode.SATELLITE).toString();
    check(street.equals("https://tiles.openfreemap.org/styles/liberty"), "account-free street endpoint");
    check(satellite.contains("/arcgis/imagery?") && !satellite.contains(key), "imagery endpoint/key");
    check(!config.toString().contains(key), "config leaked key");
    for (String host : new String[]{"basemapstyles-api.arcgis.com", "basemaps-api.arcgis.com", "ibasemaps-api.arcgis.com", "tiles.arcgis.com", "services.arcgisonline.com"})
      check(config.authorizationHeaderValue(URI.create("https://" + host + "/tiles" )).equals("Bearer " + key), "child authentication");
    for (String url : new String[]{"http://tiles.arcgis.com/tile", "https://arcgis.com.attacker.example/tile",
        "https://attacker.example/arcgis.com", "https://tiles.arcgis.com:8443/tile", "https://user@tiles.arcgis.com/tile"})
      check(config.authorizationHeaderValue(URI.create(url)) == null, "credential leaked to untrusted request");
    var missing = new EsriMapConfiguration("  ", "de");
    check(missing.canLoad(BasemapMode.STREET) && !missing.canLoad(BasemapMode.SATELLITE) && config.canLoad(BasemapMode.SATELLITE), "satellite-only account gate");
    check(missing.styleUri(BasemapMode.STREET).toString().equals("https://tiles.openfreemap.org/styles/liberty"), "street requires no key");
    check(!missing.isConfigured() && missing.authorizationHeaderValue(URI.create(street)) == null, "missing credential");
    try { new EsriMapConfiguration("secret\r\nHeader: injected", "de"); throw new AssertionError("header injection accepted"); }
    catch (IllegalArgumentException expected) { check(!expected.getMessage().contains("secret"), "unsafe key error"); }
    try { new EsriMapConfiguration(key, "de&token=other"); throw new AssertionError("query injection accepted"); }
    catch (IllegalArgumentException expected) { check(!expected.getMessage().contains(key), "unsafe language error"); }

    var state = new MapLoadState();
    long noKey = state.begin(BasemapMode.SATELLITE, false);
    check(state.snapshot().status == MapLoadState.Status.CONFIGURATION_REQUIRED && !state.canRequest(noKey), "setup state");
    check(!state.complete(noKey), "missing key became ready");
    long oldStreet = state.begin(BasemapMode.STREET, true);
    var saved = state.snapshot();
    long currentSatellite = state.begin(BasemapMode.SATELLITE, true);
    check(!state.complete(oldStreet) && !state.fail(oldStreet, MapLoadState.Status.NETWORK_ERROR), "old response won");
    check(state.complete(currentSatellite) && !state.complete(currentSatellite), "completion applied more than once");
    check(state.snapshot().mode == BasemapMode.SATELLITE && state.snapshot().status == MapLoadState.Status.READY, "wrong style state");
    check(saved.mode == BasemapMode.STREET && saved.status == MapLoadState.Status.LOADING, "old value mutated");
    check(state.fail(currentSatellite, MapLoadState.Status.QUOTA_REACHED) && !state.canRequest(currentSatellite), "quota did not stop requests");
    check(!state.complete(currentSatellite) && !state.fail(currentSatellite, MapLoadState.Status.NETWORK_ERROR), "error overwritten or silently retried");
    long retry = state.retry(true);
    check(retry != currentSatellite && state.canRequest(retry) && !state.canRequest(currentSatellite), "retry generation");
    state.detach();
    check(!state.complete(retry) && !state.canRequest(retry) && state.snapshot().status == MapLoadState.Status.DETACHED, "detached callback survived");
    for (int status : new int[]{401,403,498,499})
      check(MapLoadState.failureForHttpStatus(status) == MapLoadState.Status.AUTH_ERROR, "auth status");
    check(MapLoadState.failureForHttpStatus(429) == MapLoadState.Status.QUOTA_REACHED, "429 status");
    check(MapLoadState.failureForHttpStatus(503) == MapLoadState.Status.NETWORK_ERROR, "503 status");
    check(MapLoadState.failureForHttpStatus(400) == MapLoadState.Status.STYLE_ERROR, "400 status");
    System.out.println("PASS map setup, authenticated child requests, stale loads, quota stop, explicit retry and detach");
  }
}
