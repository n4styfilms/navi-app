package app.organicmaps.navi.friends;

import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.TaskExecutors;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.FirebaseUser;
import java.util.Objects;

/** Invalidates callbacks immediately when the signed-in identity changes. */
final class FriendsAccountController implements AutoCloseable {
  enum State { SIGNED_OUT, LOADING, READY, ERROR, CLOSED }
  interface SessionOpener { Task<FriendsDataSession> open(FirebaseUser user); }
  interface Listener { void changed(State state, FriendsDataSession session, Throwable error); }

  private final FirebaseAuth auth;
  private final SessionOpener opener;
  private final Listener listener;
  private final FirebaseAuth.AuthStateListener authListener;
  private FriendsDataSession session;
  private String account;
  private boolean observed;
  private boolean closed;
  private long generation;

  FriendsAccountController(FirebaseAuth auth, SessionOpener opener, Listener listener) {
    FriendsDataSession.requireMainThread();
    this.auth = auth;
    this.opener = opener;
    this.listener = listener;
    authListener = ignored -> accountChanged();
    auth.addAuthStateListener(authListener);
  }

  FriendsDataSession session() { return session; }

  private void clearSession() {
    if (session != null) {
      session.close();
      session = null;
    }
  }

  private void accountChanged() {
    FriendsDataSession.requireMainThread();
    if (closed) return;
    FirebaseUser user = auth.getCurrentUser();
    String uid = user == null ? null : user.getUid();
    if (observed && Objects.equals(account, uid)) return;
    observed = true;
    account = uid;
    long ticket = ++generation;
    clearSession();
    if (user == null) {
      listener.changed(State.SIGNED_OUT, null, null);
      return;
    }
    listener.changed(State.LOADING, null, null);
    // A listener can synchronously sign out or close this controller.
    if (closed || generation != ticket) return;
    try {
      opener.open(user).addOnCompleteListener(TaskExecutors.MAIN_THREAD, task -> {
        FriendsDataSession opened = task.isSuccessful() ? task.getResult() : null;
        FirebaseUser current = auth.getCurrentUser();
        if (closed || ticket != generation || current == null || !uid.equals(current.getUid())) {
          if (opened != null) opened.close();
          return;
        }
        if (opened == null || opened.isClosed() || !uid.equals(opened.owner())) {
          if (opened != null) opened.close();
          listener.changed(State.ERROR, null, task.getException() != null ? task.getException()
              : new IllegalStateException("No matching account session"));
          return;
        }
        session = opened;
        listener.changed(State.READY, session, null);
      });
    } catch (Exception error) {
      if (!closed && generation == ticket) listener.changed(State.ERROR, null, error);
    }
  }

  void signOut() {
    FriendsDataSession.requireMainThread();
    if (closed) return;
    ++generation;
    account = null;
    observed = true;
    clearSession();
    auth.signOut();
    listener.changed(State.SIGNED_OUT, null, null);
  }

  public void close() {
    FriendsDataSession.requireMainThread();
    if (closed) return;
    closed = true;
    ++generation;
    auth.removeAuthStateListener(authListener);
    clearSession();
    listener.changed(State.CLOSED, null, null);
  }
}
