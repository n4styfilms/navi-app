package app.organicmaps.fuel;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import androidx.fragment.app.Fragment;
import app.organicmaps.util.WindowInsetUtils.ScrollableContentInsetsListener;

/** Settings host for the local vehicle draft. */
public final class VehicleSettingsFragment extends Fragment
{
  private VehicleFormView mForm;

  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    mForm = new VehicleFormView(requireContext(), () -> getParentFragmentManager().popBackStack(), savedInstanceState);
    ViewCompat.setOnApplyWindowInsetsListener(mForm, new ScrollableContentInsetsListener(mForm));
    return mForm;
  }

  @Override
  public void onSaveInstanceState(@NonNull Bundle outState)
  {
    super.onSaveInstanceState(outState);
    if (mForm != null) mForm.saveDraft(outState);
  }

  @Override
  public void onDestroyView()
  {
    mForm = null;
    super.onDestroyView();
  }
}
