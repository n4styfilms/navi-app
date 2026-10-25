package app.organicmaps.navi.friends;

/** Fixture-only host for the real production sheet and actual Navi colors. */
public final class FriendsUiActivity extends android.app.Activity {
  static FriendsRuntime runtime;
  @Override public void onCreate(android.os.Bundle saved) {
    setTheme(com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar);
    super.onCreate(saved);
    setContentView(new android.widget.FrameLayout(this));
    new FriendsSheet(this, runtime, () -> {}).show();
  }
}
