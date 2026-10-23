package app.navi.probe;

import android.app.Activity;
import android.content.res.Configuration;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import app.organicmaps.R;
import app.organicmaps.fuel.*;
import java.io.File;
import java.nio.file.Files;
import java.util.Locale;
import org.json.JSONObject;

/** Isolated Android component host. It does not represent an installed navigation app. */
public final class VehicleFormProbe extends Activity
{
  private VehicleFormView form;
  private int dismissals;
  private android.content.Context formContext;
  @Override public void onCreate(Bundle saved)
  {
    super.onCreate(saved);
    getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR |
                                                    View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
    Configuration config = new Configuration(getResources().getConfiguration());
    config.setLocale(Locale.GERMAN);
    formContext = createConfigurationContext(config);
    show(saved);
    String mode = getIntent().getStringExtra("mode");
    if (mode == null) return;
    form.post(() -> {
      JSONObject result = new JSONObject();
      try
      {
        VehicleStore store = new VehicleStore(new File(getFilesDir(), VehicleStore.FILE_NAME));
        if (mode.equals("exercise"))
        {
          store.delete(); // Disposable synthetic profile in this probe package only.
          show(null);
          click(R.string.navi_vehicle_save);
          check(store.load().status == VehicleStore.Status.EMPTY, "invalid draft saved");
          check(field(R.string.navi_vehicle_make).getError() != null, "required error missing");
          field(R.string.navi_vehicle_make).setText("Testwagen");
          field(R.string.navi_vehicle_model).setText("Kompakt");
          field(R.string.navi_vehicle_engine).setText("1.5 Benzin");
          field(R.string.navi_vehicle_year).setText("2021");
          field(R.string.navi_vehicle_wltp).setText("6,0");
          field(R.string.navi_vehicle_price).setText("1,80");
          field(R.string.navi_vehicle_personal).setText("7,1");
          Bundle draft = new Bundle();
          form.saveDraft(draft);
          show(draft);
          check(field(R.string.navi_vehicle_price).getText().toString().equals("1,80"), "draft recreation lost input");
          check(store.load().status == VehicleStore.Status.EMPTY, "recreation saved draft");
          click(R.string.navi_vehicle_save);
          check(dismissals == 1, "save did not dismiss");
          VehicleProfile savedProfile = store.load().profile;
          check(savedProfile != null && savedProfile.personalLitersPer100Km == 7.1, "Android store/parse failed");
          byte[] before = Files.readAllBytes(new File(getFilesDir(), VehicleStore.FILE_NAME).toPath());
          field(R.string.navi_vehicle_wltp).setText("99");
          click(R.string.navi_vehicle_cancel);
          check(dismissals == 2, "cancel did not dismiss");
          check(java.util.Arrays.equals(before, Files.readAllBytes(new File(getFilesDir(), VehicleStore.FILE_NAME).toPath())),
                "cancel changed stored bytes");
          show(null);
          field(R.string.navi_vehicle_personal).setText("");
          click(R.string.navi_vehicle_save);
          check(store.load().profile.personalLitersPer100Km == null, "blank personal did not restore WLTP");
        }
        else if (mode.equals("restart"))
        {
          VehicleProfile profile = store.load().profile;
          check(profile != null && profile.wltpLitersPer100Km == 6 && profile.pricePerLiter == 1.8
                && profile.personalLitersPer100Km == null, "profile lost after process restart");
          check(field(R.string.navi_vehicle_make).getText().toString().equals("Testwagen"), "form did not load saved profile");
          FuelEstimate estimate = FuelCalculator.estimate(120000, profile);
          check(estimate.status == FuelEstimate.Status.READY && Math.abs(estimate.euros - 12.96) < 1e-9,
                "stored profile produced incorrect cost");
        }
        else throw new AssertionError("unknown mode");
        result.put("passed", true);
      }
      catch (Throwable error)
      {
        try { result.put("passed", false).put("error", error.toString()); }
        catch (Exception ignored) {}
        android.util.Log.e("NaviVehicleProbe", "Probe failed", error);
      }
      try
      {
        result.put("stage", mode).put("api", android.os.Build.VERSION.SDK_INT)
            .put("component_only", true).put("navigation_app_installed", false);
        Files.write(new File(getFilesDir(), "probe-" + getIntent().getStringExtra("run_id") + ".json").toPath(),
                    result.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
      }
      catch (Exception error) { android.util.Log.e("NaviVehicleProbe", "Cannot write probe report", error); }
    });
  }
  private void show(Bundle draft)
  {
    form = new VehicleFormView(formContext, () -> dismissals++, draft);
    form.setFitsSystemWindows(true);
    setContentView(form);
  }
  private View find(View root, int text)
  {
    if (root instanceof TextView && ((TextView) root).getText().toString().equals(formContext.getString(text))) return root;
    if (root instanceof ViewGroup)
      for (int i = 0; i < ((ViewGroup) root).getChildCount(); ++i)
      {
        View found = find(((ViewGroup) root).getChildAt(i), text);
        if (found != null) return found;
      }
    return null;
  }
  private EditText field(int label) { return form.findViewById(find(form, label).getLabelFor()); }
  private void click(int label) { ((Button) find(form, label)).performClick(); }
  private void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
