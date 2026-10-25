package app.organicmaps.navi.friends;

import android.content.Context;
import android.location.Location;
import android.os.SystemClock;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.Tasks;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.ValueEventListener;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONObject;

/** Application-owned account and sharing state, independent of activity recreation. */
public final class FriendsRuntime implements AutoCloseable {
  private static FriendsRuntime instance;
  private final Context context;
  private final ArrayList<Runnable> observers = new ArrayList<>();
  private final ArrayList<AutoCloseable> subscriptions = new ArrayList<>();
  private final Map<String, boolean[]> grants = new HashMap<>();
  private List<Friend> peers = Collections.emptyList();
  private List<String> requests = Collections.emptyList();
  private FirebaseApp identity;
  private FirebaseAuth auth;
  private FriendsAccountController accounts;
  private FriendsDataSession session;
  private FriendsRepository repository;
  private FriendsSharingController sharing;
  private FriendsDataSession.Transport transport = (a, d) -> {};
  private String accountState = "SIGNED_OUT", sharingState = "OFF";
  private Throwable error;
  private long serverAnchorMs, anchorElapsedNanos, sequence, lastFixElapsed;
  private boolean desired, closed;

  public static FriendsRuntime get(Context context) {
    FriendsDataSession.requireMainThread();
    if (instance == null) instance = new FriendsRuntime(context);
    return instance;
  }
  private FriendsRuntime(Context context) {
    this.context = context.getApplicationContext();
    String saved = this.context.getSharedPreferences("navi-friends-group", Context.MODE_PRIVATE).getString("configuration", "");
    if (!saved.isEmpty()) try { configure(saved); } catch (Exception invalid) { error = invalid; }
  }
  FriendsRuntime(Context context, FirebaseApp identity, FriendsDataSession.Transport transport) {
    this.context = context.getApplicationContext(); this.transport = transport;
    attach(identity);
  }
  public void configure(String json) throws Exception {
    FriendsDataSession.requireMainThread();
    if (identity != null || closed) throw new IllegalStateException("Group is already configured");
    JSONObject config = new JSONObject(json);
    String project = config.getString("projectId");
    String appId = config.getString("applicationId");
    String apiKey = config.getString("apiKey");
    URI url = new URI(config.getString("databaseUrl"));
    String host = url.getHost();
    if (!project.matches("[a-z][a-z0-9-]{4,61}[a-z0-9]") || appId.isBlank() || apiKey.isBlank()
        || !"https".equals(url.getScheme()) || url.getRawUserInfo() != null || url.getPort() != -1
        || url.getRawQuery() != null || url.getFragment() != null || host == null
        || !(host.endsWith(".firebaseio.com") || host.endsWith(".firebasedatabase.app"))
        || !(url.getPath().isEmpty() || url.getPath().equals("/")))
      throw new IllegalArgumentException("Invalid Firebase group configuration");
    FirebaseOptions options = new FirebaseOptions.Builder().setApplicationId(appId).setApiKey(apiKey)
        .setProjectId(project).setDatabaseUrl(url.toString()).build();
    FirebaseApp created;
    try { created = FirebaseApp.getInstance("navi-friends-identity"); }
    catch (IllegalStateException absent) { created = FirebaseApp.initializeApp(context, options, "navi-friends-identity"); }
    if (!created.getOptions().equals(options)) throw new IllegalStateException("Another group is already active");
    if (!context.getSharedPreferences("navi-friends-group", Context.MODE_PRIVATE).edit().putString("configuration", json).commit()) {
      created.delete(); throw new IllegalStateException("Cannot save group configuration");
    }
    attach(created);
  }
  private void attach(FirebaseApp app) {
    identity = app; auth = FirebaseAuth.getInstance(app);
    accounts = new FriendsAccountController(auth,
        user -> FriendsDataSession.open(context, identity, user, transport), (state, opened, failure) -> {
      clearData(); accountState = state.name(); error = failure;
      if (state == FriendsAccountController.State.READY) openData(opened);
      emit();
    });
  }
  private void openData(FriendsDataSession opened) {
    session = opened; repository = new FriendsRepository(opened);
    subscriptions.add(opened.listen(".info/serverTimeOffset", new ValueEventListener() {
      public void onDataChange(DataSnapshot data) {
        if (session != opened || !(data.getValue() instanceof Number)) return;
        long offset = ((Number) data.getValue()).longValue();
        try { serverAnchorMs = Math.addExact(System.currentTimeMillis(), offset); }
        catch (ArithmeticException invalid) { serverAnchorMs = 0; }
        anchorElapsedNanos = SystemClock.elapsedRealtimeNanos(); emit();
      }
      public void onCancelled(DatabaseError failure) { fail(failure.toException()); }
    }));
    sharing = new FriendsSharingController(opened, repository,
        context.getSharedPreferences("navi-friends-sharing", Context.MODE_PRIVATE), this::serverNowMs, state -> {
      sharingState = state.name();
      desired = state == FriendsSharingController.State.SHARING || state == FriendsSharingController.State.ENABLING
          || state == FriendsSharingController.State.RECONNECTING;
      emit();
    });
    subscriptions.add(repository.observe(values -> {
      if (session != opened) return;
      ArrayList<Friend> copied = new ArrayList<>();
      for (FriendsRepository.Peer peer : values) copied.add(new Friend(peer));
      peers = Collections.unmodifiableList(copied); emit();
    }));
    subscriptions.add(opened.listen("requests/" + opened.owner(), new ValueEventListener() {
      public void onDataChange(DataSnapshot data) {
        if (session != opened) return;
        ArrayList<String> copied = new ArrayList<>();
        for (DataSnapshot child : data.getChildren()) if (child.getKey() != null) copied.add(child.getKey());
        requests = Collections.unmodifiableList(copied); emit();
      }
      public void onCancelled(DatabaseError failure) { fail(failure.toException()); }
    }));
    subscriptions.add(opened.listen("grants/" + opened.owner(), new ValueEventListener() {
      public void onDataChange(DataSnapshot data) {
        if (session != opened) return;
        grants.clear();
        for (DataSnapshot child : data.getChildren()) grants.put(child.getKey(), new boolean[]{
            Boolean.TRUE.equals(child.child("position").getValue()), Boolean.TRUE.equals(child.child("speed").getValue()),
            Boolean.TRUE.equals(child.child("trips").getValue())});
        emit();
      }
      public void onCancelled(DatabaseError failure) { fail(failure.toException()); }
    }));
  }
  private void fail(Throwable failure) { error = failure; emit(); }
  private void clearData() {
    if (sharing != null) sharing.close(); sharing = null;
    for (AutoCloseable subscription : subscriptions) FriendsObservation.dispose(subscription);
    subscriptions.clear(); repository = null; session = null; peers = Collections.emptyList();
    requests = Collections.emptyList(); grants.clear(); serverAnchorMs = 0; sequence = 0; lastFixElapsed = 0;
    sharingState = "OFF"; desired = false;
  }
  private void emit() { for (Runnable observer : new ArrayList<>(observers)) observer.run(); }
  public AutoCloseable observe(Runnable observer) {
    FriendsDataSession.requireMainThread(); observers.add(observer);
    return () -> { FriendsDataSession.requireMainThread(); observers.remove(observer); };
  }
  public boolean configured() { return identity != null && !closed; }
  public boolean ready() { return session != null && !session.isClosed() && !closed; }
  public String uid() { return ready() ? session.owner() : ""; }
  public String accountState() { return accountState; }
  public String sharingState() { return sharingState; }
  public boolean sharingDesired() { return desired; }
  public Throwable error() { return error; }
  public List<Friend> peers() { return peers; }
  public List<String> requests() { return requests; }
  public boolean[] grants(String uid) { boolean[] value = grants.get(uid); return value == null ? new boolean[3] : value.clone(); }
  public long serverNowMs() {
    if (serverAnchorMs <= 0) return 0;
    long elapsed = SystemClock.elapsedRealtimeNanos() - anchorElapsedNanos;
    if (elapsed < 0) return 0;
    return serverAnchorMs + elapsed / 1000000L;
  }
  public Task<?> signIn(String email, String password) {
    if (!configured()) return Tasks.forException(new IllegalStateException("No group configured"));
    return auth.signInWithEmailAndPassword(email, password);
  }
  public Task<?> register(String email, String password) {
    if (!configured()) return Tasks.forException(new IllegalStateException("No group configured"));
    return auth.createUserWithEmailAndPassword(email, password);
  }
  public Task<Void> setSharing(boolean enabled) {
    FriendsDataSession.requireMainThread();
    if (!ready() || sharing == null || (enabled && serverNowMs() <= 0)) return unavailable();
    return sharing.setEnabled(enabled);
  }
  public Task<Boolean> onLocation(Location location, boolean foregroundMap) {
    FriendsDataSession.requireMainThread();
    if (!ready() || sharing == null || !desired || location == null || !location.hasAccuracy()) return Tasks.forResult(false);
    long now = serverNowMs(), elapsed = SystemClock.elapsedRealtimeNanos(), fix = location.getElapsedRealtimeNanos();
    long age = elapsed - fix;
    if (now <= 0 || fix <= lastFixElapsed || fix <= 0 || age < 0 || age > 15000000000L) return Tasks.forResult(false);
    lastFixElapsed = fix;
    PresenceSample sample = new PresenceSample(++sequence, now - age / 1000000L,
        location.getLatitude(), location.getLongitude(), (double) location.getAccuracy(),
        location.hasSpeed() ? (double) location.getSpeed() : null,
        location.hasBearing() ? (double) location.getBearing() : null);
    return sharing.accept(sample, foregroundMap, !location.hasSpeed() || location.getSpeed() >= 0.5f);
  }
  private <T> Task<T> unavailable() { return Tasks.forException(new IllegalStateException("Friends connection is not ready")); }
  public Task<Void> request(String uid) { return ready() ? repository.requestFriend(uid) : unavailable(); }
  public Task<Void> confirm(String uid) { return ready() ? repository.confirmFriend(uid) : unavailable(); }
  public Task<Void> grant(String uid, boolean[] values) {
    return ready() && values != null && values.length == 3 ? repository.setGrant(uid, new FriendsRepository.Grant(values[0], values[1], values[2])) : unavailable();
  }
  public Task<Void> remove(String uid) { return ready() ? repository.removeFriend(uid) : unavailable(); }
  public Task<Void> setName(String name) {
    if (!ready() || name == null || name.isEmpty() || name.length() > 40) return unavailable();
    Map<String, Object> value = new HashMap<>(); value.put("displayName", name);
    return session.database().getReference("profiles/" + uid()).setValue(value);
  }
  public void signOut() {
    FriendsDataSession.requireMainThread();
    if (sharing != null) sharing.setEnabled(false);
    if (accounts != null) accounts.signOut();
  }
  public void close() {
    if (closed) return; closed = true;
    if (accounts != null) accounts.close(); clearData(); observers.clear();
  }
  public static final class Friend {
    public final String uid, name;
    public final PresenceSample position;
    private final FriendsRepository.Peer snapshot;
    Friend(FriendsRepository.Peer value) {
      uid = value.uid; name = value.displayName == null || value.displayName.isBlank() ? value.uid : value.displayName;
      position = value.positionAllowed && value.sharingEnabled ? value.position : null; snapshot = value;
    }
    public boolean fresh(long now) { return position != null && position.isFreshAt(now); }
    public Double speed(long now) { return snapshot.speedMetersPerSecondAt(now); }
    public String description(long now, Locale locale) {
      boolean de = locale.getLanguage().equals("de");
      if (position == null) return de ? "Kein geteilter Standort" : "No shared location";
      long age = now >= position.measuredAtMs ? (now - position.measuredAtMs) / 1000 : -1;
      Double speed = speed(now);
      String label = speed == null ? (de ? "Geschwindigkeit unbekannt" : "Speed unavailable") : String.format(locale, "%.0f km/h", speed * 3.6);
      return label + " · " + (age < 0 ? "—" : age + (de ? " s alt" : " s ago"))
          + String.format(locale, " · ±%.0f m", position.accuracyMeters);
    }
  }
}
