package app.organicmaps.navi.map;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicLong;
import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import org.json.JSONObject;

/** Public street requests have no credential. Only trusted Esri resources receive the local key. */
public final class EsriHttpClient implements Interceptor
{
  public interface FailureListener { void onFailure(long generation, MapLoadState.Status status); }
  private volatile EsriMapConfiguration configuration;
  private final MapLoadState state;
  private final FailureListener listener;
  private final AtomicLong requestCount = new AtomicLong();
  public final OkHttpClient client;

  public EsriHttpClient(EsriMapConfiguration configuration, MapLoadState state, FailureListener listener)
  {
    this.configuration = configuration;
    this.state = state;
    this.listener = listener;
    client = new OkHttpClient.Builder().addInterceptor(this).retryOnConnectionFailure(false)
        .followRedirects(false).followSslRedirects(false)
        .callTimeout(30, java.util.concurrent.TimeUnit.SECONDS).build();
    client.dispatcher().setMaxRequestsPerHost(4);
  }

  public void setConfiguration(EsriMapConfiguration configuration)
  {
    client.dispatcher().cancelAll();
    this.configuration = configuration;
  }

  public long getRequestCount() { return requestCount.get(); }

  @Override public Response intercept(Chain chain) throws IOException
  {
    long generation = state.snapshot().generation;
    if (!state.canRequest(generation)) throw new IOException("Map requests are paused");
    Request original = chain.request();
    String authorization = configuration.authorizationHeaderValue(original.url().uri());
    boolean publicResource = EsriMapConfiguration.isPublicResource(original.url().uri());
    if (authorization == null && !publicResource) throw new IOException("Map resource is not authorized");
    Request.Builder builder = original.newBuilder().removeHeader("X-Esri-Authorization").removeHeader("Authorization")
        .header("User-Agent", "NaviPrivate/0.2 (MapLibre Native)");
    if (!publicResource) builder.header("X-Esri-Authorization", authorization);
    Request request = builder.build();
    Response response;
    try
    {
      requestCount.incrementAndGet();
      response = chain.proceed(request);
    }
    catch (IOException error)
    {
      // MapLibre cancels obsolete tiles during ordinary camera movement. That
      // must not pause every other request in the still-current map style.
      if (!chain.call().isCanceled()) fail(generation, MapLoadState.Status.NETWORK_ERROR);
      // Never propagate a third-party exception that may contain a URL, header or token.
      throw new IOException("Map connection failed");
    }
    int status = response.code();
    if (status == 200 && response.header("Content-Type", "").contains("json"))
    {
      try
      {
        // ArcGIS may return a small JSON error envelope with HTTP200.
        JSONObject error = new JSONObject(response.peekBody(65536).string()).optJSONObject("error");
        if (error != null) status = error.optInt("code", 400);
      }
      catch (org.json.JSONException ignored) { /* A large/partial valid style is parsed by MapLibre. */ }
      catch (IOException error)
      {
        response.close();
        if (!chain.call().isCanceled()) fail(generation, MapLoadState.Status.NETWORK_ERROR);
        throw new IOException("Map connection failed");
      }
    }
    // MapLibre owns the resource cache and needs unchanged responses for revalidation.
    if (status >= 300 && status != 304)
    {
      fail(generation, MapLoadState.failureForHttpStatus(status));
      response.close();
      throw new IOException("Map service rejected the request");
    }
    return response;
  }

  private void fail(long generation, MapLoadState.Status status)
  {
    if (state.fail(generation, status)) listener.onFailure(generation, status);
  }
}
