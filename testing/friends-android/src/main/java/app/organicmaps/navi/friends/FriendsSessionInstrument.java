package app.organicmaps.navi.friends;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskCompletionSource;
import com.google.android.gms.tasks.Tasks;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.FirebaseUser;
import com.google.firebase.database.DatabaseError;
import com.google.firebase.database.DataSnapshot;
import com.google.firebase.database.FirebaseDatabase;
import com.google.firebase.database.ServerValue;
import com.google.firebase.database.ValueEventListener;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Three real native Firebase clients talking only to demo Auth/Database emulators. */
public final class FriendsSessionInstrument extends Instrumentation {
  private final ArrayList<FirebaseApp> primaryApps = new ArrayList<>();
  private final ArrayList<FriendsDataSession> sessions = new ArrayList<>();
  private FriendsAccountController controller;
  private final FriendsDataSession.Transport local = (auth, database) -> {
    auth.useEmulator("10.0.2.2", 9099);
    database.useEmulator("10.0.2.2", 9000);
  };

  public void onCreate(Bundle args) { super.onCreate(args); start(); }
  private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
  private <T> T ui(Callable<T> action) throws Exception {
    AtomicReference<T> value = new AtomicReference<>();
    AtomicReference<Throwable> error = new AtomicReference<>();
    runOnMainSync(() -> { try { value.set(action.call()); } catch (Throwable e) { error.set(e); } });
    if (error.get() != null) throw new Exception(error.get());
    return value.get();
  }
  private <T> T await(Task<T> task) throws Exception { return Tasks.await(task, 30, TimeUnit.SECONDS); }
  private static Map<String, Object> values(Object... pairs) {
    Map<String, Object> map = new HashMap<>();
    for (int i = 0; i < pairs.length; i += 2) map.put((String) pairs[i], pairs[i + 1]);
    return map;
  }
  private FirebaseAuth identity(String name) throws Exception {
    return ui(() -> {
      FirebaseOptions options = new FirebaseOptions.Builder()
          .setApplicationId("1:1234567890:android:0123456789abcdef")
          .setApiKey("fake-emulator-api-key")
          .setProjectId("demo-navi-friends")
          .setDatabaseUrl("https://demo-navi-friends.firebaseio.com")
          .build();
      FirebaseApp app = FirebaseApp.initializeApp(getTargetContext(), options, name + "-" + UUID.randomUUID());
      primaryApps.add(app);
      FirebaseAuth auth = FirebaseAuth.getInstance(app);
      auth.useEmulator("10.0.2.2", 9099);
      return auth;
    });
  }
  private FirebaseUser signup(FirebaseAuth auth) throws Exception {
    // Disposable local-only test identities; never real accounts or user passwords.
    FirebaseUser user = await(auth.createUserWithEmailAndPassword(UUID.randomUUID() + "@navi.invalid", "local-test-password-123")).getUser();
    check(user != null, "Native Auth signup returned no user");
    return user;
  }
  private FriendsDataSession open(FirebaseAuth auth, FirebaseUser user) throws Exception {
    FriendsDataSession session = await(ui(() -> FriendsDataSession.open(getTargetContext(), auth.getApp(), user, local)));
    sessions.add(session);
    check(session.owner().equals(user.getUid()), "Cloned session has the wrong owner");
    return session;
  }
  private void denied(FriendsDataSession session, String path) throws Exception {
    AtomicInteger values = new AtomicInteger();
    CountDownLatch canceled = new CountDownLatch(1);
    AtomicReference<DatabaseError> error = new AtomicReference<>();
    AutoCloseable registration = ui(() -> session.listen(path, new ValueEventListener() {
      public void onDataChange(DataSnapshot snapshot) { values.incrementAndGet(); }
      public void onCancelled(DatabaseError failure) { error.set(failure); canceled.countDown(); }
    }));
    try {
      check(canceled.await(15, TimeUnit.SECONDS), "Native denied listener never reported cancellation");
      check(error.get().getCode() == DatabaseError.PERMISSION_DENIED, "Denied listener failed for another reason");
      check(values.get() == 0, "New account received another account's cached peer data");
    } finally { ui(() -> { registration.close(); return null; }); }
  }

  public void onStart() {
    Bundle report = new Bundle();
    int result = Activity.RESULT_CANCELED;
    try {
      FirebaseAuth aliceAuth = identity("alice"); FirebaseUser alice = signup(aliceAuth);
      FirebaseAuth bobAuth = identity("bob"); FirebaseUser bob = signup(bobAuth);
      FirebaseAuth eveAuth = identity("eve"); FirebaseUser eve = signup(eveAuth);
      FriendsDataSession a = open(aliceAuth, alice), b = open(bobAuth, bob);
      String aliceId = alice.getUid(), bobId = bob.getUid();
      await(a.database().getReference("profiles/" + aliceId).setValue(values("displayName", "Alice test")));
      await(a.database().getReference("friendConsent/" + aliceId + "/" + bobId).setValue(true));
      await(b.database().getReference("friendConsent/" + bobId + "/" + aliceId).setValue(true));
      await(a.database().getReference("grants/" + aliceId + "/" + bobId).setValue(values("position", true, "speed", false, "trips", false)));
      await(a.database().getReference("liveControl/" + aliceId).setValue(values("generation", 1L, "enabled", true)));
      await(a.database().getReference("live/" + aliceId + "/position").setValue(values(
          "sharingGeneration", 1L, "sequence", 1L, "latitude", 43.7295, "longitude", 7.4208,
          "accuracyMeters", 5, "measuredAtMs", System.currentTimeMillis(), "receivedAtMs", ServerValue.TIMESTAMP)));
      check(await(b.database().getReference("profiles/" + aliceId).get()).exists(), "Confirmed native peer cannot read profile");
      report.putBoolean("native_auth_cloned", true);

      CountDownLatch initial = new CountDownLatch(1), revoked = new CountDownLatch(1);
      AtomicReference<DatabaseError> cancellation = new AtomicReference<>();
      ui(() -> b.listen("live/" + aliceId + "/position", new ValueEventListener() {
        public void onDataChange(DataSnapshot snapshot) { if (snapshot.exists()) initial.countDown(); }
        public void onCancelled(DatabaseError error) { cancellation.set(error); revoked.countDown(); }
      }));
      check(initial.await(15, TimeUnit.SECONDS), "Native live listener never received permitted position");
      await(a.database().getReference("liveControl/" + aliceId).setValue(values("generation", 2L, "enabled", false)));
      check(revoked.await(15, TimeUnit.SECONDS), "Native live listener remained permitted after pause");
      check(cancellation.get().getCode() == DatabaseError.PERMISSION_DENIED, "Native pause cancellation was not permission denied");
      report.putBoolean("native_listener_revoked", true);

      String oldDataApp = b.appName();
      ui(() -> { b.close(); return null; });
      check(bobAuth.getCurrentUser() != null, "Closing copied data Auth signed out primary account");
      check(FirebaseApp.getApps(getTargetContext()).stream().noneMatch(app -> app.getName().equals(oldDataApp)), "Old data FirebaseApp was retained");
      FriendsDataSession e = open(eveAuth, eve);
      denied(e, "profiles/" + aliceId);
      report.putBoolean("native_fresh_session_denied_old_peer", true);

      CountDownLatch opened = new CountDownLatch(1);
      TaskCompletionSource<FriendsDataSession> delivery = new TaskCompletionSource<>();
      AtomicReference<FriendsDataSession> delayed = new AtomicReference<>();
      AtomicInteger ready = new AtomicInteger();
      controller = ui(() -> new FriendsAccountController(aliceAuth, user -> {
        FriendsDataSession.open(getTargetContext(), aliceAuth.getApp(), user, local)
            .addOnSuccessListener(session -> { delayed.set(session); sessions.add(session); opened.countDown(); });
        return delivery.getTask();
      }, (state, session, error) -> { if (state == FriendsAccountController.State.READY) ready.incrementAndGet(); }));
      check(opened.await(20, TimeUnit.SECONDS), "Delayed real native session did not open");
      ui(() -> { controller.signOut(); return null; });
      ui(() -> { delivery.setResult(delayed.get()); return null; });
      waitForIdleSync();
      check(delayed.get().isClosed(), "Late account completion kept a data session alive");
      check(ready.get() == 0 && controller.session() == null, "Signed-out account was reactivated by late completion");
      report.putBoolean("native_late_session_completion_closed", true);
      result = Activity.RESULT_OK;
    } catch (Throwable error) {
      android.util.Log.e("NaviFriendsNativeTest", "Synthetic integration failure", error);
      report.putString("native_error", error.getClass().getSimpleName() + ": " + error.getMessage());
      report.putString("native_error_stack", android.util.Log.getStackTraceString(error));
    } finally {
      try {
        ui(() -> {
          if (controller != null) controller.close();
          for (FriendsDataSession session : sessions) session.close();
          for (FirebaseApp app : primaryApps) { FirebaseAuth.getInstance(app).signOut(); app.delete(); }
          return null;
        });
      } catch (Exception error) { report.putString("cleanup_error", error.toString()); result = Activity.RESULT_CANCELED; }
      finish(result, report);
    }
  }
}
