package app.organicmaps.navi.map;

import java.net.URI;
import java.util.Locale;

/** Documented v8 style endpoints. Credentials travel in headers, never style URLs or UI messages. */
public final class EsriMapConfiguration
{
  private final String key;
  private final String language;

  public EsriMapConfiguration(String key, String language)
  {
    this.key = key == null ? "" : key.trim();
    for (int i = 0; i < this.key.length(); ++i)
      if (this.key.charAt(i) <= 32 || this.key.charAt(i) >= 127)
        throw new IllegalArgumentException("Invalid map key");
    this.language = language == null || language.isEmpty() ? "global" : language;
    if (!this.language.matches("[a-zA-Z]{2,8}(-[a-zA-Z0-9]{2,8})*"))
      throw new IllegalArgumentException("Invalid map language");
  }

  public boolean isConfigured() { return !key.isEmpty(); }
  public boolean canLoad(BasemapMode mode) { return mode == BasemapMode.STREET || isConfigured(); }

  public URI styleUri(BasemapMode mode)
  {
    if (mode == BasemapMode.STREET) return URI.create("https://tiles.openfreemap.org/styles/liberty");
    return URI.create("https://basemapstyles-api.arcgis.com/arcgis/rest/services/styles/v2/styles/arcgis/" +
                      "imagery?language=" + language + "&echoToken=false");
  }

  public static boolean isPublicResource(URI uri)
  {
    return "https".equalsIgnoreCase(uri.getScheme()) && uri.getRawUserInfo() == null &&
        (uri.getPort() == -1 || uri.getPort() == 443) && "tiles.openfreemap.org".equalsIgnoreCase(uri.getHost());
  }

  public static boolean isTrustedResource(URI uri)
  {
    if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null ||
        (uri.getPort() != -1 && uri.getPort() != 443) || uri.getHost() == null)
      return false;
    String host = uri.getHost().toLowerCase(Locale.ROOT);
    return host.equals("arcgis.com") || host.endsWith(".arcgis.com") ||
           host.equals("arcgisonline.com") || host.endsWith(".arcgisonline.com");
  }

  /** Also used for tile, glyph and sprite requests; redirects must be checked independently. */
  public String authorizationHeaderValue(URI uri)
  {
    return isConfigured() && isTrustedResource(uri) ? "Bearer " + key : null;
  }

  @Override public String toString() { return "EsriMapConfiguration(configured=" + isConfigured() + ")"; }
}
