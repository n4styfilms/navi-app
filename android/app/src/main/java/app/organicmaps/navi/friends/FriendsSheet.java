package app.organicmaps.navi.friends;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AlertDialog;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import com.google.android.gms.tasks.Task;
import com.google.android.material.bottomsheet.BottomSheetDialog;
import java.util.Locale;

/** Small extension of the approved rounded Navi palette; no placeholder people. */
public final class FriendsSheet implements AutoCloseable {
  private final Context context;
  private final FriendsRuntime runtime;
  private final Runnable enableSharing;
  private final BottomSheetDialog dialog;
  private LinearLayout body;
  private AutoCloseable subscription;
  private boolean accountForm;
  private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
  private final java.util.ArrayList<Runnable> ageLabels = new java.util.ArrayList<>();
  private final Runnable tick = new Runnable() {
    @Override public void run() {
      for (Runnable update : new java.util.ArrayList<>(ageLabels)) update.run();
      main.postDelayed(this, 1000);
    }
  };

  public FriendsSheet(Context context, FriendsRuntime runtime, Runnable enableSharing) {
    this.context = context; this.runtime = runtime; this.enableSharing = enableSharing;
    dialog = new BottomSheetDialog(context);
  }
  public void show() {
    ScrollView scroll = new ScrollView(context);
    body = new LinearLayout(context); body.setOrientation(LinearLayout.VERTICAL);
    body.setPadding(dp(24), dp(24), dp(24), dp(32));
    body.setBackground(shape(R.color.navi_surface, 30)); scroll.addView(body);
    dialog.setContentView(scroll);
    subscription = runtime.observe(() -> { if (!accountForm) render(); });
    dialog.setOnDismissListener(ignored -> dispose());
    dialog.setOnShowListener(ignored -> {
      FrameLayout frame = dialog.findViewById(com.google.android.material.R.id.design_bottom_sheet);
      if (frame != null) {
        frame.setBackground(shape(R.color.navi_surface, 32)); frame.setClipToOutline(true);
        frame.getLayoutParams().height = (int) (context.getResources().getDisplayMetrics().heightPixels * 0.9);
        frame.requestLayout();
        com.google.android.material.bottomsheet.BottomSheetBehavior.from(frame).setState(
            com.google.android.material.bottomsheet.BottomSheetBehavior.STATE_EXPANDED);
      }
    });
    render(); dialog.show(); main.post(tick);
  }
  private void dispose() {
    main.removeCallbacks(tick); ageLabels.clear();
    if (subscription != null) try { subscription.close(); } catch (Exception ignored) {}
    subscription = null;
  }
  @Override public void close() { dialog.dismiss(); dispose(); }
  private String t(String de, String en) { return Locale.getDefault().getLanguage().equals("de") ? de : en; }
  private void render() {
    ageLabels.clear(); body.removeAllViews(); label(t("Deine Freunde", "Your friends"), 25, true);
    if (!runtime.configured()) {
      label(t("Für eure private Gruppe muss einmal der kostenlose Gruppen-Zugang eingerichtet werden. Danach meldet ihr euch einfach an.",
              "Set up your group's free private connection once. Then each friend can sign in."), 16, false);
      action(t("Gruppe einrichten", "Set up group"), this::configure); return;
    }
    if (!runtime.ready()) {
      if (runtime.accountState().equals("SIGNING_OUT")) {
        label(t("Freigabe wird beendet und du wirst abgemeldet …", "Stopping sharing and signing out…"), 16, false); return;
      }
      if (runtime.hasPendingRevocations()) label(t("Lokal abgemeldet. Eine Serverbestätigung der Pausierung steht noch aus. Melde dich mit dem bisherigen Konto bei bestehender Verbindung an, um sie abzuschließen.",
          "Signed out locally. A server pause is still pending. Sign in to the previous account while connected to finish it."), 15, false);
      label(runtime.accountState().equals("LOADING") ? t("Verbinde …", "Connecting…") : t("Melde dich für deine private Freundeskarte an.", "Sign in to your private friends map."), 16, false);
      action(t("Anmelden / Konto erstellen", "Sign in / create account"), this::account);
      if (runtime.error() != null) label(t("Verbindung oder Anmeldung fehlgeschlagen. Prüfe deinen Zugang.", "Connection or sign-in failed. Check your account."), 15, false);
      return;
    }
    label(t("Standortfreigabe: ", "Location sharing: ") + sharingLabel(), 16, true);
    action(runtime.sharingDesired() ? t("Freigabe pausieren", "Pause sharing") : t("Standort teilen", "Share location"), () -> {
      if (runtime.sharingDesired()) task(runtime.setSharing(false)); else enableSharing.run();
    });
    action(t("Meinen Freundecode kopieren", "Copy my friend code"), () -> {
      ((ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Navi", runtime.uid()));
      Toast.makeText(context, t("Freundecode kopiert", "Friend code copied"), Toast.LENGTH_SHORT).show();
    });
    action(t("Freund hinzufügen", "Add friend"), () -> input(t("Freundecode", "Friend code"), "", value -> task(runtime.request(value.trim()))));
    action(t("Anzeigename ändern", "Change display name"), () -> input(t("Dein Name", "Your name"), "", value -> task(runtime.setName(value.trim()))));
    for (String request : runtime.requests()) {
      label(t("Anfrage von ", "Request from ") + request, 14, false);
      action(t("Anfrage annehmen", "Accept request"), () -> task(runtime.confirm(request)));
    }
    if (runtime.peers().isEmpty()) label(t("Noch keine bestätigten Freunde. Tauscht eure Freundecodes aus und bestätigt die Anfrage.",
                                                         "No confirmed friends yet. Exchange friend codes and accept the request."), 16, false);
    long now = runtime.serverNowMs();
    for (FriendsRuntime.Friend friend : runtime.peers()) {
      Button row = action(friend.name + "\n" + friend.description(now, Locale.getDefault()), () -> rights(friend));
      ageLabels.add(() -> row.setText(friend.name + "\n" + friend.description(runtime.serverNowMs(), Locale.getDefault())));
    }
    action(t("Abmelden", "Sign out"), runtime::signOut);
  }
  private String sharingLabel() {
    return switch (runtime.sharingState()) {
      case "SHARING" -> t("aktiv", "active");
      case "ENABLING" -> t("wird gestartet …", "starting…");
      case "RECONNECTING" -> t("Verbindung unterbrochen", "connection lost");
      case "REVOCATION_PENDING" -> t("lokal pausiert · Serverbestätigung ausstehend", "paused locally · awaiting server confirmation");
      case "ERROR" -> t("angehalten · Zugang prüfen", "stopped · check connection");
      default -> t("pausiert", "paused");
    };
  }
  private void rights(FriendsRuntime.Friend friend) {
    boolean[] values = runtime.grants(friend.uid);
    new AlertDialog.Builder(context).setTitle(friend.name)
        .setMultiChoiceItems(new String[]{t("Meinen Standort teilen", "Share my location"), t("Meine Geschwindigkeit teilen", "Share my speed"), t("Meine Fahrten teilen", "Share my trips")}, values,
            (d, which, enabled) -> values[which] = enabled)
        .setPositiveButton(t("Speichern", "Save"), (d, which) -> task(runtime.grant(friend.uid, values)))
        .setNeutralButton(t("Freund entfernen", "Remove friend"), (d, which) -> task(runtime.remove(friend.uid)))
        .setNegativeButton(t("Abbrechen", "Cancel"), null).show();
  }
  private void account() {
    accountForm = true; body.removeAllViews(); label(t("Dein Konto", "Your account"), 25, true);
    EditText email = field(t("E-Mail", "Email"), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
    EditText password = field(t("Passwort", "Password"), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    action(t("Anmelden", "Sign in"), () -> auth(runtime.signIn(email.getText().toString().trim(), password.getText().toString()), password));
    action(t("Konto erstellen", "Create account"), () -> auth(runtime.register(email.getText().toString().trim(), password.getText().toString()), password));
    action(t("Zurück", "Back"), () -> { accountForm = false; render(); });
  }
  private void auth(Task<?> task, EditText password) {
    task.addOnCompleteListener(result -> {
      password.setText("");
      if (result.isSuccessful()) { accountForm = false; render(); }
      else Toast.makeText(context, t("Anmeldung fehlgeschlagen. Prüfe E-Mail, Passwort und Verbindung.", "Sign-in failed. Check email, password and connection."), Toast.LENGTH_LONG).show();
    });
  }
  private void configure() {
    input(t("Gruppen-Zugang einfügen", "Paste group connection"), "", json -> {
      try { runtime.configure(json); render(); }
      catch (Exception error) { Toast.makeText(context, t("Ungültiger Gruppen-Zugang", "Invalid group connection"), Toast.LENGTH_LONG).show(); }
    });
  }
  private void task(Task<?> task) {
    task.addOnFailureListener(error -> Toast.makeText(context, t("Aktion fehlgeschlagen. Prüfe Verbindung und Zugang.", "Action failed. Check connection and account."), Toast.LENGTH_LONG).show());
  }
  private void input(String title, String value, java.util.function.Consumer<String> save) {
    EditText field = new EditText(context); field.setText(value); field.setTextColor(color(R.color.navi_ink));
    new AlertDialog.Builder(context).setTitle(title).setView(field)
        .setPositiveButton(t("Übernehmen", "Apply"), (d, which) -> save.accept(field.getText().toString()))
        .setNegativeButton(t("Abbrechen", "Cancel"), null).show();
  }
  private EditText field(String hint, int type) {
    EditText value = new EditText(context); value.setHint(hint); value.setInputType(type); value.setSingleLine();
    value.setTextColor(color(R.color.navi_ink)); value.setHintTextColor(color(R.color.navi_muted));
    value.setPadding(dp(16), dp(12), dp(16), dp(12)); value.setBackground(shape(R.color.navi_field, 18));
    body.addView(value, new LinearLayout.LayoutParams(-1, dp(60))); return value;
  }
  private Button action(String title, Runnable click) {
    Button value = new Button(context); value.setText(title); value.setAllCaps(false); value.setTextSize(16);
    value.setTextColor(color(R.color.navi_ink)); value.setBackgroundTintList(null); value.setBackground(shape(R.color.navi_field, 26));
    value.setPadding(dp(16), dp(12), dp(16), dp(12)); value.setMinHeight(dp(52)); value.setOnClickListener(v -> click.run());
    LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2); layout.topMargin = dp(10); body.addView(value, layout);
    return value;
  }
  private void label(String title, int size, boolean bold) {
    TextView value = new TextView(context); value.setText(title); value.setTextSize(size); value.setTextColor(color(bold ? R.color.navi_ink : R.color.navi_muted));
    if (bold) value.setTypeface(null, Typeface.BOLD); value.setPadding(0, dp(8), 0, dp(10)); body.addView(value);
  }
  private int color(int resource) { return ContextCompat.getColor(context, resource); }
  private int dp(int value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
  private GradientDrawable shape(int color, int radius) { GradientDrawable result = new GradientDrawable(); result.setColor(color(color)); result.setCornerRadius(dp(radius)); return result; }
}
