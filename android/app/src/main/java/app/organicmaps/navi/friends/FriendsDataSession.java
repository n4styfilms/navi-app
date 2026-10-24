package app.organicmaps.navi.friends;

import android.content.Context;
import android.os.Looper;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskCompletionSource;
import com.google.android.gms.tasks.TaskExecutors;
import com.google.firebase.FirebaseApp;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.FirebaseUser;
import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.DatabaseReference;
import com.google.firebase.database.FirebaseDatabase;
import com.google.firebase.database.ValueEventListener;
import java.util.ArrayList;
import java.util.UUID;

/** A disposable, memory-only data connection belonging to one authenticated account. */
final class FriendsDataSession implements AutoCloseable {
  interface Transport {
    void configure(FirebaseAuth auth, FirebaseDatabase database);
  }

  private final FirebaseApp app;
  private final FirebaseAuth auth;
  private final FirebaseDatabase database;
  private final String owner;
  private final ArrayList<Registration> registrations = new ArrayList<>();
  private boolean closed;

  private FriendsDataSession(FirebaseApp app, FirebaseAuth auth, FirebaseDatabase database, String owner) {
    this.app = app;
    this.auth = auth;
    this.database = database;
    this.owner = owner;
  }

  static void requireMainThread() {
    if (Looper.myLooper() != Looper.getMainLooper())
      throw new IllegalStateException("Friends session lifecycle requires the main thread");
  }

  static Task<FriendsDataSession> open(Context context, FirebaseApp identityApp, FirebaseUser user,
                                       Transport transport) {
    requireMainThread();
    TaskCompletionSource<FriendsDataSession> result = new TaskCompletionSource<>();
    FirebaseApp app = FirebaseApp.initializeApp(context.getApplicationContext(), identityApp.getOptions(),
        "navi-friends-data-" + UUID.randomUUID());
    FirebaseAuth auth = FirebaseAuth.getInstance(app);
    FirebaseDatabase database = FirebaseDatabase.getInstance(app);
    FriendsDataSession session = new FriendsDataSession(app, auth, database, user.getUid());
    try {
      database.setPersistenceEnabled(false);
      transport.configure(auth, database);
      auth.updateCurrentUser(user).addOnCompleteListener(TaskExecutors.MAIN_THREAD, task -> {
        if (task.isSuccessful() && auth.getCurrentUser() != null
            && session.owner.equals(auth.getCurrentUser().getUid())) {
          result.setResult(session);
        } else {
          session.close();
          Exception failure = task.getException();
          result.setException(failure != null ? failure : new IllegalStateException("Account copy failed"));
        }
      });
    } catch (Exception failure) {
      session.close();
      result.setException(failure);
    }
    return result.getTask();
  }

  String owner() { return owner; }
  String appName() { return app.getName(); }
  boolean isClosed() { return closed; }
  FirebaseDatabase database() {
    if (closed) throw new IllegalStateException("Friends session is closed");
    return database;
  }

  AutoCloseable listen(String path, ValueEventListener listener) {
    requireMainThread();
    if (closed) throw new IllegalStateException("Friends session is closed");
    Registration registration = new Registration(database.getReference(path), listener);
    registrations.add(registration);
    registration.reference.addValueEventListener(registration);
    return registration;
  }

  private final class Registration implements ValueEventListener, AutoCloseable {
    final DatabaseReference reference;
    final ValueEventListener listener;
    boolean removed;
    Registration(DatabaseReference reference, ValueEventListener listener) {
      this.reference = reference;
      this.listener = listener;
    }
    public void onDataChange(DataSnapshot snapshot) {
      if (!closed && !removed) listener.onDataChange(snapshot);
    }
    public void onCancelled(DatabaseError error) {
      if (!closed && !removed) listener.onCancelled(error);
    }
    public void close() {
      requireMainThread();
      if (removed) return;
      removed = true;
      reference.removeEventListener(this);
      registrations.remove(this);
    }
  }

  /** Local cleanup only; a sharing pause must also revoke the server liveControl generation. */
  public void close() {
    requireMainThread();
    if (closed) return;
    closed = true;
    for (Registration registration : new ArrayList<>(registrations)) registration.close();
    database.purgeOutstandingWrites();
    database.goOffline();
    auth.signOut();
    app.delete();
  }
}
