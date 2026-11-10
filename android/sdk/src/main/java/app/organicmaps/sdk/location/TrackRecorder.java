package app.organicmaps.sdk.location;

import androidx.annotation.Keep;

public class TrackRecorder
{
  public static final int TRIP_ARCHIVE_FAILED = 0;
  public static final int TRIP_ARCHIVE_EMPTY = 1;
  public static final int TRIP_ARCHIVE_SAVED = 2;

  @Keep
  public interface TripArchiveListener
  {
    /** Archive results can arrive on the GPS worker thread. */
    void onTripArchived(int result);
  }

  public static native boolean nativeStartNaviTrip(String identifier, boolean passenger, long startedAtMs);

  public static native void nativeStopNaviTrip(long endedAtMs, TripArchiveListener listener);

  public static native void nativeStartTrackRecording();

  public static native void nativeStopTrackRecording();

  public static native void nativeSaveTrackRecordingWithName(String name);

  public static native boolean nativeIsTrackRecordingEmpty();

  public static native boolean nativeIsTrackRecordingEnabled();
}
