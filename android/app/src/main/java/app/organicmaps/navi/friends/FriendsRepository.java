package app.organicmaps.navi.friends;

import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskExecutors;
import com.google.android.gms.tasks.Tasks;
import com.google.firebase.database.DatabaseReference;
import com.google.firebase.database.ServerValue;
import java.util.HashMap;
import java.util.Map;

/** Account-scoped friendship actions. Live subscriptions and GPS publishing are separate steps. */
final class FriendsRepository {
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
