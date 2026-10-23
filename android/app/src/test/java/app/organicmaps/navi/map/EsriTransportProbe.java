package app.organicmaps.navi.map;

import java.io.IOException;
import java.util.concurrent.TimeUnit;
import okhttp3.*;
import okio.*;

/** Runs the production interceptor with real OkHttp bodies and injected transport failures. */
public final class EsriTransportProbe
{
  private static final String SECRET = "fixture_private_key";
  private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
  private static final class Body extends ResponseBody
  {
    boolean closed;
    final BufferedSource source;
    Body(String json, boolean broken)
    {
      source = broken ? Okio.buffer(new Source() {
        public long read(Buffer sink, long count) throws IOException { throw new IOException("URL/header " + SECRET); }
        public Timeout timeout() { return Timeout.NONE; }
        public void close() { closed = true; }
      }) : new Buffer().writeUtf8(json);
    }
    public MediaType contentType() { return MediaType.get("application/json"); }
    public long contentLength() { return -1; }
    public BufferedSource source() { return source; }
    public void close() { closed = true; super.close(); }
  }
  private static final class Chain implements Interceptor.Chain
  {
    final Request request;
    final Call activeCall;
    Request received;
    final Body body;
    final int status;
    boolean brokenConnection;
    Runnable duringProceed;
    Chain(Body body, int status) { this(body, status, "https://basemapstyles-api.arcgis.com/style"); }
    Chain(Body body, int status, String url)
    {
      this.body = body; this.status = status;
      request = new Request.Builder().url(url).header("X-Esri-Authorization", "Bearer " + SECRET).build();
      activeCall = new OkHttpClient().newCall(request);
    }
    public Request request() { return request; }
    public Response proceed(Request request) throws IOException
    {
      received = request;
      if (duringProceed != null) duringProceed.run();
      if (brokenConnection) throw new IOException("URL/header " + SECRET);
      return new Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("fixture")
          .header("Content-Type", "application/json").body(body).build();
    }
    public Connection connection() { return null; }
    public Call call() { return activeCall; }
    public int connectTimeoutMillis() { return 1000; }
    public Chain withConnectTimeout(int timeout, TimeUnit unit) { return this; }
    public int readTimeoutMillis() { return 1000; }
    public Chain withReadTimeout(int timeout, TimeUnit unit) { return this; }
    public int writeTimeoutMillis() { return 1000; }
    public Chain withWriteTimeout(int timeout, TimeUnit unit) { return this; }
  }
  private static IOException rejected(EsriHttpClient transport, Chain chain) throws Exception
  {
    try { transport.intercept(chain).close(); throw new AssertionError("expected rejected response"); }
    catch (IOException error)
    {
      check(!error.toString().contains(SECRET) && error.getCause() == null, "transport exception leaked credential");
      return error;
    }
  }
  public static void main(String[] args) throws Exception
  {
    var state = new MapLoadState();
    long generation = state.begin(BasemapMode.STREET, true);
    int[] failures = {0};
    var transport = new EsriHttpClient(new EsriMapConfiguration(SECRET, "de"), state, (g, s) -> failures[0]++);
    var valid = new Chain(new Body("{\"version\":8}", false), 200);
    try (Response response = transport.intercept(valid))
    {
      check(response.body().string().contains("version"), "peek consumed style body");
      check(("Bearer " + SECRET).equals(valid.received.header("X-Esri-Authorization")), "header not applied");
      check(!valid.received.url().toString().contains(SECRET), "query credential");
    }
    check(!transport.client.retryOnConnectionFailure() && !transport.client.followRedirects(), "implicit retry/redirect");
    var notModified = new Chain(new Body("", false), 304, "https://tiles.openfreemap.org/styles/liberty");
    try (Response response = transport.intercept(notModified))
    {
      check(response.code() == 304 && response.body().string().isEmpty(), "cache validation response changed");
    }
    check(state.snapshot().status == MapLoadState.Status.LOADING && failures[0] == 0,
          "valid cache validation paused the map");
    var cancelled = new Chain(new Body("{}", false), 200);
    cancelled.brokenConnection = true;
    cancelled.duringProceed = cancelled.activeCall::cancel;
    rejected(transport, cancelled);
    check(state.snapshot().status == MapLoadState.Status.LOADING && failures[0] == 0,
          "normal tile cancellation paused the map");
    var cancelledBody = new Chain(new Body("", true), 200);
    cancelledBody.duringProceed = cancelledBody.activeCall::cancel;
    rejected(transport, cancelledBody);
    check(state.snapshot().status == MapLoadState.Status.LOADING && failures[0] == 0,
          "cancelled body read paused the map");
    var publicMap = new Chain(new Body("{\"version\":8}", false), 200, "https://tiles.openfreemap.org/styles/liberty");
    try (Response response = transport.intercept(publicMap))
    {
      check(publicMap.received.header("X-Esri-Authorization") == null, "Esri credential sent to public map");
      check(publicMap.received.header("User-Agent").contains("NaviPrivate"), "missing app user agent");
    }
    var broken = new Chain(new Body("", true), 200);
    rejected(transport, broken);
    check(broken.body.closed, "failed peek left body open");
    check(state.snapshot().status == MapLoadState.Status.NETWORK_ERROR && failures[0] == 1, "body read failure not scoped");
    for (int code : new int[]{301, 302, 307, 308, 401, 403, 429, 498, 499, 503})
    {
      generation = state.retry(true);
      var chain = new Chain(new Body("{}", false), code);
      rejected(transport, chain);
      check(chain.body.closed && state.snapshot().status == MapLoadState.failureForHttpStatus(code), "HTTP classification");
      long count = transport.getRequestCount();
      rejected(transport, new Chain(new Body("{}", false), 200));
      check(count == transport.getRequestCount() && !state.canRequest(generation), "failed generation made another request");
    }
    state.retry(true);
    rejected(transport, new Chain(new Body("{\"error\":{\"code\":498}}", false), 200));
    check(state.snapshot().status == MapLoadState.Status.AUTH_ERROR, "HTTP200 error envelope");
    state.retry(true);
    var connection = new Chain(new Body("{}", false), 200);
    connection.brokenConnection = true;
    rejected(transport, connection);
    check(state.snapshot().status == MapLoadState.Status.NETWORK_ERROR, "connection failure");
    state.retry(true);
    var stale = new Chain(new Body("{}", false), 429);
    stale.duringProceed = () -> state.begin(BasemapMode.SATELLITE, true);
    rejected(transport, stale);
    check(state.snapshot().status == MapLoadState.Status.LOADING && state.snapshot().mode == BasemapMode.SATELLITE,
          "old failure changed new mode");
    state.detach();
    long count = transport.getRequestCount();
    rejected(transport, new Chain(new Body("{}", false), 200));
    check(count == transport.getRequestCount(), "detached view made request");
    System.out.println("PASS real OkHttp map transport, body failure, HTTP envelopes and generation gate");
  }
}
