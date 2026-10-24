package app.organicmaps.navi.friends;

import android.content.SharedPreferences;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskCompletionSource;
import com.google.android.gms.tasks.TaskExecutors;
import com.google.android.gms.tasks.Tasks;
import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.MutableData;
import com.google.firebase.database.Transaction;
import com.google.firebase.database.ValueEventListener;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

/** Durable sharing intent and server lease; consumes the existing location stream only. */
final class FriendsSharingController implements AutoCloseable {
  enum State { OFF, ENABLING, SHARING, RECONNECTING, REVOCATION_PENDING, PAUSED, ERROR, CLOSED }
  private final FriendsDataSession session;
  private final FriendsRepository repository;
  private final SharedPreferences preferences;
  private final String prefix;
  private final LongSupplier now;
  private final Consumer<State> observer;
  private final PresencePolicy policy = new PresencePolicy();
  private final AtomicLong revision = new AtomicLong();
  private volatile boolean closed;
  private boolean connected, hasIntent, desired, pending, inFlight;
  private long lease, policyTicket;
  private State state;
  private Exception lastFailure;
  private TaskCompletionSource<Void> completion;
  private AutoCloseable connection;
  private AutoCloseable closing;

  FriendsSharingController(FriendsDataSession session, FriendsRepository repository,
      SharedPreferences preferences, LongSupplier serverNowMs, Consumer<State> observer) {
    FriendsDataSession.requireMainThread();
    if (session.isClosed()) throw new IllegalStateException("Friends session is closed");
    this.session = session;
    this.repository = repository;
    this.preferences = preferences;
    now = serverNowMs;
    this.observer = observer;
    prefix = session.database().getApp().getOptions().getApplicationId() + "/" + session.owner();
    hasIntent = preferences.contains(prefix + "/desired");
    desired = preferences.getBoolean(prefix + "/desired", false);
    pending = preferences.getBoolean(prefix + "/pending", false);
    if (hasIntent && desired) { pending = true; persist(); }
    completion = new TaskCompletionSource<>();
    update(!hasIntent ? State.OFF : desired ? State.RECONNECTING : pending ? State.REVOCATION_PENDING : State.PAUSED);
    closing = session.onClose(this::accountClosed);
    connection = session.listen(".info/connected", new ValueEventListener() {
      public void onDataChange(DataSnapshot snapshot) { connectionChanged(Boolean.TRUE.equals(snapshot.getValue())); }
      public void onCancelled(DatabaseError error) { fail(error.toException()); }
    });
  }

  State state() { return state; }
  Exception lastFailure() { return lastFailure; }
  private void update(State next) { state = next; observer.accept(next); }
  private void persist() {
    if (!preferences.edit().putBoolean(prefix + "/desired", desired)
        .putBoolean(prefix + "/pending", pending).commit())
      throw new IllegalStateException("Cannot persist sharing intent");
  }
  private void cancelCompletion() {
    if (completion != null) completion.trySetException(new CancellationException("Sharing intent superseded"));
  }
  private void invalidate() {
    revision.incrementAndGet();
    inFlight = false;
    lease = 0;
    policy.pause();
    session.database().purgeOutstandingWrites();
  }

  Task<Void> setEnabled(boolean enabled) {
    FriendsDataSession.requireMainThread();
    if (closed) return Tasks.forException(new IllegalStateException("Sharing controller is closed"));
    invalidate();
    cancelCompletion();
    completion = new TaskCompletionSource<>();
    hasIntent = true;
    desired = enabled;
    pending = true;
    try { persist(); }
    catch (RuntimeException error) { fail(error); return completion.getTask(); }
    update(enabled ? State.ENABLING : State.REVOCATION_PENDING);
    if (connected) reconcile();
    return completion.getTask();
  }

  private void connectionChanged(boolean online) {
    FriendsDataSession.requireMainThread();
    if (closed || connected == online) return;
    connected = online;
    if (online) {
      if (hasIntent && pending) reconcile();
      return;
    }
    if (!hasIntent || (!desired && !pending)) return;
    invalidate();
    pending = true;
    if (completion.getTask().isComplete()) completion = new TaskCompletionSource<>();
    try { persist(); }
    catch (RuntimeException error) { fail(error); return; }
    update(desired ? State.RECONNECTING : State.REVOCATION_PENDING);
  }

  private void reconcile() {
    if (closed || !connected || !pending || inFlight) return;
    inFlight = true;
    long ticket = revision.get();
    boolean target = desired;
    session.database().getReference("liveControl/" + session.owner()).runTransaction(new Transaction.Handler() {
      public Transaction.Result doTransaction(MutableData data) {
        if (closed || ticket != revision.get()) return Transaction.abort();
        Object previous = data.child("generation").getValue();
        long generation = 0;
        if (previous != null) {
          if (!(previous instanceof Number)) return Transaction.abort();
          double value = ((Number) previous).doubleValue();
          if (Double.isNaN(value) || Double.isInfinite(value) || value < 1
              || value >= 9007199254740991L || value != Math.floor(value)) return Transaction.abort();
          generation = (long) value;
        }
        Map<String, Object> control = new HashMap<>();
        control.put("enabled", target);
        control.put("generation", generation + 1);
        // New leases never inherit an earlier publication cursor.
        data.setValue(control);
        return Transaction.success(data);
      }
      public void onComplete(DatabaseError error, boolean committed, DataSnapshot snapshot) {
        TaskExecutors.MAIN_THREAD.execute(() -> finish(ticket, target, error, committed, snapshot));
      }
    }, false);
  }

  private void finish(long ticket, boolean target, DatabaseError error, boolean committed, DataSnapshot snapshot) {
    FriendsDataSession.requireMainThread();
    if (closed || ticket != revision.get()) return;
    inFlight = false;
    if (error != null || !committed || snapshot == null) {
      fail(error != null ? error.toException() : new IllegalStateException("Sharing lease update aborted"));
      return;
    }
    Object generation = snapshot.child("generation").getValue();
    if (!(generation instanceof Number) || !Boolean.valueOf(target).equals(snapshot.child("enabled").getValue())) {
      fail(new IllegalStateException("Server returned an invalid sharing lease"));
      return;
    }
    desired = target;
    pending = false;
    try { persist(); }
    catch (RuntimeException failure) { fail(failure); return; }
    if (target) {
      lease = ((Number) generation).longValue();
      policyTicket = policy.begin(session.owner(), now.getAsLong());
      update(State.SHARING);
    } else {
      lease = 0;
      policy.pause();
      update(State.PAUSED);
    }
    completion.trySetResult(null);
  }

  Task<Boolean> accept(PresenceSample sample, boolean foregroundMap, boolean moving) {
    FriendsDataSession.requireMainThread();
    if (closed || state != State.SHARING || lease < 1) return Tasks.forResult(false);
    long timestamp = now.getAsLong();
    PresencePolicy.Upload upload = policy.prepare(sample, timestamp, policyTicket, foregroundMap, moving);
    if (upload == null) return Tasks.forResult(false);
    long ticket = revision.get();
    return repository.publish(policy, upload, lease, timestamp).continueWithTask(TaskExecutors.MAIN_THREAD, task -> {
      if (task.isSuccessful()) return Tasks.forResult(true);
      Exception failure = task.getException() != null ? task.getException() : new IllegalStateException("Publication canceled");
      if (!closed && ticket == revision.get()) {
        // An actual current-generation rejection must not become a newer enable
        // intent during reconnection. Stop locally and retain pending revocation.
        desired = false;
        pending = true;
        try { persist(); } catch (RuntimeException persistence) { failure.addSuppressed(persistence); }
        fail(failure);
      }
      return Tasks.forException(failure);
    });
  }

  private void fail(Exception error) {
    if (closed) return;
    lastFailure = error;
    lease = 0;
    policy.fail();
    inFlight = false;
    update(State.ERROR);
    if (completion != null) completion.trySetException(error);
  }
  private void accountClosed() {
    // The data app is already closing: immediate local stop and durable intent,
    // without pretending that an offline server revocation has completed.
    if (hasIntent && desired) {
      desired = false;
      pending = true;
      try { persist(); } catch (RuntimeException ignored) { /* No account callback may restart location. */ }
    }
    close();
  }
  public void close() {
    FriendsDataSession.requireMainThread();
    if (closed) return;
    closed = true;
    revision.incrementAndGet();
    policy.signOut();
    lease = 0;
    FriendsObservation.dispose(connection);
    FriendsObservation.dispose(closing);
    cancelCompletion();
    update(State.CLOSED);
  }
}
