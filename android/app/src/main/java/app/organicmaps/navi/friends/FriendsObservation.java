package app.organicmaps.navi.friends;

import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.ValueEventListener;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.Consumer;

/** One main-thread subscription tree. Never retains mutable SDK snapshots in UI state. */
final class FriendsObservation implements AutoCloseable {
  private final FriendsDataSession session;
  private final FriendsRepository.Observer observer;
  private final String owner;
  private final TreeMap<String, WatchedPeer> peers = new TreeMap<>();
  private AutoCloseable ownConsent;
  private AutoCloseable closeObserver;
  private boolean closed;

  FriendsObservation(FriendsDataSession session, FriendsRepository.Observer observer) {
    this.session = session;
    this.observer = observer;
    owner = session.owner();
    closeObserver = session.onClose(this::close);
    ownConsent = listen("friendConsent/" + owner, snapshot -> {
      HashSet<String> retained = new HashSet<>();
      for (DataSnapshot child : snapshot.getChildren()) {
        String uid = child.getKey();
        if (!Boolean.TRUE.equals(child.getValue()) || uid == null || owner.equals(uid)) continue;
        retained.add(uid);
        if (!peers.containsKey(uid)) {
          WatchedPeer peer = new WatchedPeer(uid);
          peers.put(uid, peer);
          peer.start();
        }
      }
      for (String uid : new ArrayList<>(peers.keySet())) {
        if (!retained.contains(uid)) peers.remove(uid).close();
      }
      emit();
    }, this::close);
    emit();
  }

  private AutoCloseable listen(String path, Consumer<DataSnapshot> receive, Runnable canceled) {
    return session.listen(path, new ValueEventListener() {
      public void onDataChange(DataSnapshot snapshot) { if (!closed) receive.accept(snapshot); }
      public void onCancelled(DatabaseError error) { if (!closed) canceled.run(); }
    });
  }

  private void emit() {
    if (closed) return;
    ArrayList<FriendsRepository.Peer> copy = new ArrayList<>();
    for (WatchedPeer peer : peers.values()) if (peer.confirmed) copy.add(peer.snapshot());
    observer.changed(Collections.unmodifiableList(copy));
  }

  static void dispose(AutoCloseable registration) {
    if (registration == null) return;
    try { registration.close(); }
    catch (Exception failure) { throw new IllegalStateException("Cannot close friends subscription", failure); }
  }

  public void close() {
    FriendsDataSession.requireMainThread();
    if (closed) return;
    closed = true;
    dispose(ownConsent);
    dispose(closeObserver);
    for (WatchedPeer peer : peers.values()) peer.close();
    peers.clear();
    observer.changed(Collections.emptyList());
  }

  private final class WatchedPeer {
    final String uid;
    boolean active = true;
    boolean confirmed;
    String name = "";
    FriendsRepository.Grant grant = new FriendsRepository.Grant(false, false, false);
    AutoCloseable consent, profile, rights, control, point, speed;
    long detailEpoch, controlEpoch, liveEpoch, speedEpoch;
    boolean enabled;
    boolean watching;
    long generation;
    long publishedSequence;
    PresenceSample position;
    SpeedValue velocity;

    WatchedPeer(String uid) { this.uid = uid; }
    boolean valid() { return !closed && active && !session.isClosed(); }
    void start() {
      consent = listen("friendConsent/" + uid + "/" + owner, snapshot -> {
        if (!valid()) return;
        boolean accepted = Boolean.TRUE.equals(snapshot.getValue());
        if (accepted == confirmed) return;
        stopDetails();
        confirmed = accepted;
        if (confirmed) startDetails();
        emit();
      }, () -> { if (valid()) { stopDetails(); confirmed = false; emit(); } });
    }
    void startDetails() {
      long ticket = ++detailEpoch;
      profile = listen("profiles/" + uid, snapshot -> {
        if (!valid() || ticket != detailEpoch) return;
        Object value = snapshot.child("displayName").getValue();
        name = value instanceof String ? (String) value : "";
        emit();
      }, () -> { if (valid() && ticket == detailEpoch) { stopDetails(); confirmed = false; emit(); } });
      rights = listen("grants/" + uid + "/" + owner, snapshot -> {
        if (!valid() || ticket != detailEpoch || !confirmed) return;
        boolean oldPosition = grant.position;
        boolean oldSpeed = grant.speed;
        grant = new FriendsRepository.Grant(Boolean.TRUE.equals(snapshot.child("position").getValue()),
            Boolean.TRUE.equals(snapshot.child("speed").getValue()), Boolean.TRUE.equals(snapshot.child("trips").getValue()));
        if (oldPosition != grant.position) {
          stopControl();
          if (grant.position) startControl();
        } else if (oldSpeed != grant.speed) {
          stopSpeed();
          if (grant.speed && watching) startSpeed();
        }
        emit();
      }, () -> { if (valid() && ticket == detailEpoch) { grant = new FriendsRepository.Grant(false, false, false); stopControl(); emit(); } });
    }
    void stopDetails() {
      ++detailEpoch;
      dispose(profile); profile = null;
      dispose(rights); rights = null;
      stopControl();
      name = "";
      grant = new FriendsRepository.Grant(false, false, false);
    }
    void startControl() {
      long ticket = ++controlEpoch;
      control = listen("liveControl/" + uid, snapshot -> {
        if (!valid() || ticket != controlEpoch || !grant.position || !confirmed) return;
        long next = integer(snapshot.child("generation"));
        if (next < generation) return;
        boolean sharing = Boolean.TRUE.equals(snapshot.child("enabled").getValue());
        long cursor = integer(snapshot.child("publishedSequence"));
        if (next != generation || !sharing) stopLive();
        generation = next;
        enabled = sharing && next > 0;
        publishedSequence = cursor;
        if (enabled && cursor > 0) {
          if (!watching) startLive();
          else if (grant.speed && speed == null) startSpeed();
        }
        emit();
      }, () -> { if (valid() && ticket == controlEpoch) { stopLive(); enabled = false; emit(); } });
    }
    void stopControl() {
      ++controlEpoch;
      dispose(control); control = null;
      stopLive();
      generation = publishedSequence = 0;
      enabled = false;
    }
    void startLive() {
      watching = true;
      long ticket = ++liveEpoch;
      long lease = generation;
      point = listen("live/" + uid + "/position", snapshot -> {
        if (!valid() || !confirmed || ticket != liveEpoch || generation != lease || !enabled) return;
        if (integer(snapshot.child("sharingGeneration")) != lease) return;
        PresenceSample sample = position(snapshot);
        if (sample == null) { position = null; velocity = null; emit(); return; }
        if (position != null && sample.sequence < position.sequence) return;
        position = sample;
        emit();
      }, () -> { if (valid() && ticket == liveEpoch) { stopLive(); emit(); } });
      if (grant.speed) startSpeed();
    }
    void startSpeed() {
      long ticket = ++speedEpoch;
      long lease = generation;
      speed = listen("live/" + uid + "/speed", snapshot -> {
        if (!valid() || !confirmed || !watching || !enabled || !grant.speed
            || ticket != speedEpoch || lease != generation) return;
        velocity = new SpeedValue(integer(snapshot.child("sharingGeneration")), integer(snapshot.child("sequence")),
            integer(snapshot.child("measuredAtMs")), number(snapshot.child("metersPerSecond")));
        emit();
      }, () -> { if (valid() && ticket == speedEpoch) { stopSpeed(); emit(); } });
    }
    void stopSpeed() {
      ++speedEpoch;
      dispose(speed); speed = null;
      velocity = null;
    }
    void stopLive() {
      ++liveEpoch;
      dispose(point); point = null;
      stopSpeed();
      watching = false;
      position = null;
    }
    FriendsRepository.Peer snapshot() {
      Double joined = null;
      if (position != null && velocity != null && grant.speed && velocity.generation == generation
          && velocity.sequence == position.sequence && velocity.measuredAtMs == position.measuredAtMs)
        joined = velocity.value;
      return new FriendsRepository.Peer(uid, name, grant, enabled, generation,
          enabled && (publishedSequence == 0 || position == null), position, joined);
    }
    void close() {
      active = false;
      dispose(consent); consent = null;
      stopDetails();
      confirmed = false;
    }
  }

  private static final class SpeedValue {
    final long generation, sequence, measuredAtMs;
    final Double value;
    SpeedValue(long generation, long sequence, long measuredAtMs, Double value) {
      this.generation = generation;
      this.sequence = sequence;
      this.measuredAtMs = measuredAtMs;
      this.value = value != null && value >= 0 ? value : null;
    }
  }
  private static Double number(DataSnapshot field) {
    Object value = field.getValue();
    if (!(value instanceof Number)) return null;
    double number = ((Number) value).doubleValue();
    return Double.isFinite(number) ? number : null;
  }
  private static long integer(DataSnapshot field) {
    Double number = number(field);
    return number != null && number > 0 && number <= 9007199254740991L && number == Math.floor(number)
        ? number.longValue() : 0;
  }
  private static PresenceSample position(DataSnapshot snapshot) {
    Double latitude = number(snapshot.child("latitude")), longitude = number(snapshot.child("longitude"));
    if (latitude == null || longitude == null) return null;
    PresenceSample sample = new PresenceSample(integer(snapshot.child("sequence")), integer(snapshot.child("measuredAtMs")),
        latitude, longitude, number(snapshot.child("accuracyMeters")), null, number(snapshot.child("bearingDegrees")));
    return sample.isValid() ? sample : null;
  }
}
