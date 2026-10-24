package app.organicmaps.navi.friends;

import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskExecutors;
import com.google.android.gms.tasks.Tasks;
import com.google.firebase.database.DatabaseReference;
import com.google.firebase.database.ServerValue;
import java.util.HashMap;
import java.util.Map;
import java.util.List;

/** Account-scoped data boundary; the map receives immutable copies rather than SDK snapshots. */
final class FriendsRepository {
  interface Observer { void changed(List<Peer> peers); }
  static final class Peer {
    final String uid;
    final String displayName;
    final boolean positionAllowed;
    final boolean speedAllowed;
    final boolean tripsAllowed;
    final boolean sharingEnabled;
    final boolean awaitingFreshSample;
    final long liveGeneration;
    final PresenceSample position;
    private final Double speed;
    Peer(String uid, String name, Grant grant, boolean enabled, long generation,
         boolean awaiting, PresenceSample position, Double speed) {
      this.uid = uid;
      displayName = name;
      positionAllowed = grant.position;
      speedAllowed = grant.speed;
      tripsAllowed = grant.trips;
      sharingEnabled = enabled;
      liveGeneration = generation;
      awaitingFreshSample = awaiting;
      this.position = position;
      this.speed = speed;
    }
    Double speedMetersPerSecondAt(long serverNowMs) {
      return speedAllowed && position != null && position.isFreshAt(serverNowMs) ? speed : null;
    }
  }
  static final class Grant {
    final boolean position;
    final boolean speed;
    final boolean trips;
    Grant(boolean position, boolean speed, boolean trips) {
      this.position = position;
      this.speed = speed;
      this.trips = trips;
    }
    Map<String, Object> fields() {
      Map<String, Object> fields = new HashMap<>();
      fields.put("position", position);
      fields.put("speed", speed);
      fields.put("trips", trips);
      return fields;
    }
  }

  private final FriendsDataSession session;
  private final String owner;
  FriendsRepository(FriendsDataSession session) {
    FriendsDataSession.requireMainThread();
    if (session.isClosed()) throw new IllegalStateException("Friends session is closed");
    this.session = session;
    owner = session.owner();
  }

  AutoCloseable observe(Observer observer) {
    FriendsDataSession.requireMainThread();
    if (session.isClosed()) throw new IllegalStateException("Friends session is closed");
    return new FriendsObservation(session, observer);
  }

  Task<Void> publish(PresencePolicy policy, PresencePolicy.Upload upload, long lease, long nowMs) {
    FriendsDataSession.requireMainThread();
    if (session.isClosed() || policy == null || upload == null || !owner.equals(upload.owner)
        || lease < 1 || lease > 9007199254740991L)
      return Tasks.forException(new IllegalStateException("No current sharing session"));
    PresenceSample sample = upload.sample;
    Map<String, Object> point = new HashMap<>();
    point.put("sharingGeneration", lease);
    point.put("sequence", sample.sequence);
    point.put("latitude", sample.latitude);
    point.put("longitude", sample.longitude);
    point.put("accuracyMeters", sample.accuracyMeters);
    point.put("measuredAtMs", sample.measuredAtMs);
    point.put("receivedAtMs", ServerValue.TIMESTAMP);
    if (sample.bearingDegrees() != null) point.put("bearingDegrees", sample.bearingDegrees());
    Map<String, Object> speed = new HashMap<>();
    speed.put("sharingGeneration", lease);
    speed.put("sequence", sample.sequence);
    speed.put("measuredAtMs", sample.measuredAtMs);
    if (sample.speedMetersPerSecond() != null) speed.put("metersPerSecond", sample.speedMetersPerSecond());
    Map<String, Object> changes = new HashMap<>();
    changes.put("live/" + owner + "/position", point);
    changes.put("live/" + owner + "/speed", speed);
    changes.put("liveControl/" + owner + "/publishedSequence", sample.sequence);
    // Serialize the final candidate check with policy.pause/fail/signOut. This
    // does not revoke a network operation already sent; server leases do that.
    synchronized (policy) {
      if (!policy.isCurrent(upload, nowMs))
        return Tasks.forException(new IllegalStateException("Sharing candidate was invalidated"));
      return session.database().getReference().updateChildren(changes);
    }
  }

  private Exception invalidPeer(String peer) {
    FriendsDataSession.requireMainThread();
    if (session.isClosed()) return new IllegalStateException("Friends session is closed");
    if (peer == null || !peer.matches("[A-Za-z0-9_-]{1,128}") || owner.equals(peer))
      return new IllegalArgumentException("Invalid friend identifier");
    return null;
  }

  Task<Void> requestFriend(String peer) {
    Exception invalid = invalidPeer(peer);
    if (invalid != null) return Tasks.forException(invalid);
    Map<String, Object> request = new HashMap<>();
    request.put("createdAtMs", ServerValue.TIMESTAMP);
    Map<String, Object> changes = new HashMap<>();
    changes.put("friendConsent/" + owner + "/" + peer, true);
    changes.put("requests/" + peer + "/" + owner, request);
    // Asking records only our consent. It does not grant or publish any data.
    return session.database().getReference().updateChildren(changes);
  }

  Task<Void> confirmFriend(String peer) {
    Exception invalid = invalidPeer(peer);
    if (invalid != null) return Tasks.forException(invalid);
    DatabaseReference request = session.database().getReference("requests/" + owner + "/" + peer);
    return request.get().continueWithTask(TaskExecutors.MAIN_THREAD, task -> {
      if (session.isClosed()) return Tasks.forException(new IllegalStateException("Friends session is closed"));
      if (!task.isSuccessful()) return Tasks.forException(task.getException() != null ? task.getException()
          : new IllegalStateException("Request lookup canceled"));
      if (!task.getResult().exists()) return Tasks.forException(new IllegalStateException("No incoming friend request"));
      Map<String, Object> changes = new HashMap<>();
      changes.put("friendConsent/" + owner + "/" + peer, true);
      changes.put("requests/" + owner + "/" + peer, null);
      return session.database().getReference().updateChildren(changes);
    });
  }

  Task<Void> setGrant(String peer, Grant grant) {
    Exception invalid = invalidPeer(peer);
    if (invalid != null) return Tasks.forException(invalid);
    if (grant == null) return Tasks.forException(new IllegalArgumentException("Missing sharing rights"));
    return session.database().getReference("grants/" + owner + "/" + peer).setValue(grant.fields());
  }

  Task<Void> removeFriend(String peer) {
    Exception invalid = invalidPeer(peer);
    if (invalid != null) return Tasks.forException(invalid);
    Map<String, Object> changes = new HashMap<>();
    changes.put("friendConsent/" + owner + "/" + peer, null);
    changes.put("grants/" + owner + "/" + peer, null);
    changes.put("requests/" + owner + "/" + peer, null);
    changes.put("requests/" + peer + "/" + owner, null);
    return session.database().getReference().updateChildren(changes);
  }
}
