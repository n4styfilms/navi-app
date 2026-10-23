package app.organicmaps.fuel;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import android.app.AlertDialog;
import app.organicmaps.R;
import java.io.File;
import java.io.IOException;
import java.util.EnumMap;
import java.util.Map;

/** Local draft editor. Leaving the screen never writes or changes the stored profile. */
public final class VehicleFormView extends ScrollView
{
  private final Runnable mDismiss;
  private final EnumMap<VehicleInput.Field, EditText> mFields = new EnumMap<>(VehicleInput.Field.class);
  private VehicleStore mStore;
  private RadioGroup mFuel;
  private RadioButton mDiesel;
  private TextView mStatus;
  private Button mSave;
  private AlertDialog mDeleteDialog;
  private boolean mCanSave;

  public VehicleFormView(Context context, Runnable onDismiss, Bundle savedInstanceState)
  {
    super(context);
    mDismiss = onDismiss;
    initialize(savedInstanceState);
  }

  private void initialize(Bundle savedInstanceState)
  {
    Context context = getContext();
    mStore = new VehicleStore(new File(context.getFilesDir(), VehicleStore.FILE_NAME));
    ScrollView scroll = this;
    scroll.setFillViewport(true);
    scroll.setClipToPadding(false);
    scroll.setBackgroundColor(color(R.color.navi_surface));
    LinearLayout content = new LinearLayout(context);
    content.setOrientation(LinearLayout.VERTICAL);
    content.setPadding(dp(24), dp(24), dp(24), dp(32));
    scroll.addView(content, new ScrollView.LayoutParams(-1, -2));

    TextView introduction = text(R.string.navi_vehicle_intro, 16, R.color.navi_muted);
    introduction.setPadding(0, 0, 0, dp(20));
    content.addView(introduction);
    input(content, VehicleInput.Field.MAKE, R.string.navi_vehicle_make, InputType.TYPE_CLASS_TEXT);
    input(content, VehicleInput.Field.MODEL, R.string.navi_vehicle_model, InputType.TYPE_CLASS_TEXT);
    input(content, VehicleInput.Field.ENGINE, R.string.navi_vehicle_engine, InputType.TYPE_CLASS_TEXT);
    input(content, VehicleInput.Field.YEAR, R.string.navi_vehicle_year, InputType.TYPE_CLASS_NUMBER);

    content.addView(text(R.string.navi_vehicle_fuel, 14, R.color.navi_muted));
    mFuel = new RadioGroup(context);
    mFuel.setOrientation(LinearLayout.HORIZONTAL);
    RadioButton petrol = fuelButton(R.string.navi_vehicle_petrol);
    mDiesel = fuelButton(R.string.navi_vehicle_diesel);
    mFuel.addView(petrol, new RadioGroup.LayoutParams(0, dp(56), 1));
    mFuel.addView(mDiesel, new RadioGroup.LayoutParams(0, dp(56), 1));
    mFuel.check(petrol.getId());
    content.addView(mFuel);
    input(content, VehicleInput.Field.WLTP, R.string.navi_vehicle_wltp,
          InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
    input(content, VehicleInput.Field.PRICE, R.string.navi_vehicle_price,
          InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
    input(content, VehicleInput.Field.PERSONAL, R.string.navi_vehicle_personal,
          InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
    content.addView(text(R.string.navi_vehicle_consumption_hint, 14, R.color.navi_muted));
    mStatus = text(R.string.navi_vehicle_local, 14, R.color.navi_muted);
    mStatus.setPadding(0, dp(20), 0, dp(16));
    mStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
    content.addView(mStatus);

    mSave = action(R.string.navi_vehicle_save, true);
    mSave.setOnClickListener(v -> save());
    content.addView(mSave, actionLayout());
    Button cancel = action(R.string.navi_vehicle_cancel, false);
    cancel.setOnClickListener(v -> mDismiss.run());
    content.addView(cancel, actionLayout());
    Button delete = action(R.string.navi_vehicle_delete, false);
    delete.setOnClickListener(v -> confirmDelete());
    content.addView(delete, actionLayout());
    load();
    if (savedInstanceState != null)
    {
      for (Map.Entry<VehicleInput.Field, EditText> entry : mFields.entrySet())
        entry.getValue().setText(savedInstanceState.getString(entry.getKey().name(), ""));
      mFuel.check(savedInstanceState.getBoolean("diesel") ? mDiesel.getId() : petrol.getId());
    }
  }

  private void load()
  {
    mCanSave = false;
    try
    {
      VehicleStore.LoadResult loaded = mStore.load();
      mCanSave = loaded.status == VehicleStore.Status.EMPTY || loaded.status == VehicleStore.Status.READY;
      if (loaded.status == VehicleStore.Status.READY)
      {
        VehicleProfile p = loaded.profile;
        set(VehicleInput.Field.MAKE, p.make);
        set(VehicleInput.Field.MODEL, p.model);
        set(VehicleInput.Field.ENGINE, p.engine);
        set(VehicleInput.Field.YEAR, p.year);
        set(VehicleInput.Field.WLTP, p.wltpLitersPer100Km);
        set(VehicleInput.Field.PRICE, p.pricePerLiter);
        set(VehicleInput.Field.PERSONAL, p.personalLitersPer100Km);
        if (p.fuelType == VehicleProfile.FuelType.DIESEL) mFuel.check(mDiesel.getId());
      }
      else if (!mCanSave)
        mStatus.setText(R.string.navi_vehicle_unreadable);
    }
    catch (IOException e) { mStatus.setText(R.string.navi_vehicle_read_failed); }
    mSave.setEnabled(mCanSave);
    mSave.setAlpha(mCanSave ? 1.0f : 0.45f);
  }

  private void save()
  {
    if (!mCanSave) return;
    for (EditText field : mFields.values()) field.setError(null);
    VehicleInput.Result parsed = VehicleInput.parse(value(VehicleInput.Field.MAKE), value(VehicleInput.Field.MODEL),
        value(VehicleInput.Field.ENGINE), value(VehicleInput.Field.YEAR),
        mFuel.getCheckedRadioButtonId() == mDiesel.getId() ? "DIESEL" : "PETROL",
        value(VehicleInput.Field.WLTP), value(VehicleInput.Field.PRICE), value(VehicleInput.Field.PERSONAL));
    if (!parsed.errors.isEmpty())
    {
      EditText first = null;
      for (Map.Entry<VehicleInput.Field, VehicleInput.Error> error : parsed.errors.entrySet())
      {
        EditText input = mFields.get(error.getKey());
        if (input == null) continue;
        input.setError(getContext().getString(error.getValue() == VehicleInput.Error.REQUIRED
            ? R.string.navi_vehicle_required : R.string.navi_vehicle_invalid));
        if (first == null) first = input;
      }
      if (first != null) first.requestFocus();
      return;
    }
    try
    {
      mStore.save(parsed.profile);
      Toast.makeText(getContext(), R.string.navi_vehicle_saved, Toast.LENGTH_SHORT).show();
      mDismiss.run();
    }
    catch (IOException e) { mStatus.setText(R.string.navi_vehicle_write_failed); }
  }

  private void delete()
  {
    try
    {
      mStore.delete();
      Toast.makeText(getContext(), R.string.navi_vehicle_deleted, Toast.LENGTH_SHORT).show();
      mDismiss.run();
    }
    catch (IOException e) { mStatus.setText(R.string.navi_vehicle_write_failed); }
  }

  private void confirmDelete()
  {
    mDeleteDialog = new AlertDialog.Builder(getContext())
        .setTitle(R.string.navi_vehicle_delete)
        .setMessage(R.string.navi_vehicle_delete_confirm)
        .setNegativeButton(R.string.navi_vehicle_cancel, null)
        .setPositiveButton(R.string.navi_vehicle_delete, (dialog, which) -> delete())
        .create();
    mDeleteDialog.show();
    mDeleteDialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(color(R.color.navi_ink));
    mDeleteDialog.getButton(AlertDialog.BUTTON_NEGATIVE).setTextColor(color(R.color.navi_ink));
  }

  @Override
  protected void onDetachedFromWindow()
  {
    if (mDeleteDialog != null) mDeleteDialog.dismiss();
    mDeleteDialog = null;
    super.onDetachedFromWindow();
  }

  public void saveDraft(Bundle outState)
  {
    for (Map.Entry<VehicleInput.Field, EditText> entry : mFields.entrySet())
      outState.putString(entry.getKey().name(), entry.getValue().getText().toString());
    if (mFuel != null) outState.putBoolean("diesel", mFuel.getCheckedRadioButtonId() == mDiesel.getId());
  }

  private String value(VehicleInput.Field field) { return mFields.get(field).getText().toString(); }
  private void set(VehicleInput.Field field, Object value)
  {
    mFields.get(field).setText(value == null ? "" : value.toString());
  }
  private void input(LinearLayout content, VehicleInput.Field field, int title, int inputType)
  {
    TextView label = text(title, 14, R.color.navi_muted);
    EditText input = new EditText(getContext());
    input.setId(View.generateViewId());
    input.setTextSize(17);
    input.setTextColor(color(R.color.navi_ink));
    input.setSingleLine(true);
    input.setInputType(inputType);
    input.setPadding(dp(18), dp(12), dp(18), dp(12));
    input.setBackground(shape(R.color.navi_field, 18));
    input.setBackgroundTintList(null);
    label.setLabelFor(input.getId());
    content.addView(label);
    LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2);
    layout.topMargin = dp(7);
    layout.bottomMargin = dp(18);
    input.setMinHeight(dp(56));
    content.addView(input, layout);
    mFields.put(field, input);
  }
  private RadioButton fuelButton(int title)
  {
    RadioButton button = new RadioButton(getContext());
    button.setId(View.generateViewId());
    button.setText(title);
    button.setTextSize(16);
    button.setTextColor(color(R.color.navi_ink));
    button.setButtonTintList(ColorStateList.valueOf(color(R.color.navi_ink)));
    return button;
  }
  private TextView text(int title, int size, int color)
  {
    TextView view = new TextView(getContext());
    view.setText(title);
    view.setTextSize(size);
    view.setTextColor(color(color));
    return view;
  }
  private Button action(int title, boolean primary)
  {
    Button button = new Button(getContext());
    button.setText(title);
    button.setAllCaps(false);
    button.setTextSize(16);
    button.setTypeface(null, Typeface.BOLD);
    button.setTextColor(color(primary ? R.color.navi_surface : R.color.navi_ink));
    button.setBackgroundTintList(null);
    button.setBackground(shape(primary ? R.color.navi_ink : R.color.navi_field, 30));
    button.setMinHeight(dp(56));
    button.setPadding(dp(20), dp(12), dp(20), dp(12));
    return button;
  }
  private LinearLayout.LayoutParams actionLayout()
  {
    LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2);
    layout.topMargin = dp(10);
    return layout;
  }
  private GradientDrawable shape(int color, int radius)
  {
    GradientDrawable shape = new GradientDrawable();
    shape.setColor(color(color));
    shape.setCornerRadius(dp(radius));
    return shape;
  }
  private int dp(int size) { return Math.round(size * getResources().getDisplayMetrics().density); }
  private int color(int color) { return getResources().getColor(color); }
}
