#include "Framework.hpp"

#include "map/gps_tracker.hpp"

#include "app/organicmaps/sdk/core/jni_helper.hpp"

#include <chrono>
#include <exception>

extern "C"
{
JNIEXPORT void JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeSetEnabled(JNIEnv * env, jclass clazz,
                                                                                        jboolean enable)
{
  GpsTracker::Instance().SetEnabled(enable);
  Framework * const f = frm();
  if (f == nullptr)
    return;
  if (enable)
    f->ConnectToGpsTracker();
  else
    f->DisconnectFromGpsTracker();
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeIsEnabled(JNIEnv * env, jclass clazz)
{
  return GpsTracker::Instance().IsEnabled();
}

JNIEXPORT void JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeStartTrackRecording(JNIEnv * env,
                                                                                                 jclass clazz)
{
  frm()->StartTrackRecording();
}

JNIEXPORT void JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeStopTrackRecording(JNIEnv * env,
                                                                                                jclass clazz)
{
  frm()->StopTrackRecording();
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeStartNaviTrip(
    JNIEnv * env, jclass, jstring identifier, jboolean passenger, jlong startedAtMs)
{
  try
  {
    auto & framework = *frm();
    auto store = framework.GetNaviTripStore();
    auto const role = passenger ? navi::TripRole::Passenger : navi::TripRole::Driver;
    framework.StartNaviTrip(store, jni::ToNativeString(env, identifier), role, startedAtMs);
    return JNI_TRUE;
  }
  catch (std::exception const &)
  {
    return JNI_FALSE;
  }
}

JNIEXPORT void JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeStopNaviTrip(
    JNIEnv * env, jclass, jlong endedAtMs, jobject listener)
{
  auto const method = jni::GetMethodID(env, listener, "onTripArchived", "(I)V");
  try
  {
    auto & framework = *frm();
    auto store = framework.GetNaviTripStore();
    framework.StopNaviTrip(store, endedAtMs, [target = jni::make_global_ref(listener), method](navi::TripArchiveResult result)
    {
      jni::GetEnv()->CallVoidMethod(*target, method, static_cast<jint>(result));
    });
  }
  catch (std::exception const &)
  {
    env->CallVoidMethod(listener, method, static_cast<jint>(navi::TripArchiveResult::Failed));
  }
}

JNIEXPORT void JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeSaveTrackRecordingWithName(JNIEnv * env,
                                                                                                        jclass clazz,
                                                                                                        jstring name)
{
  frm()->SaveTrackRecordingWithName(jni::ToNativeString(env, name));
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeIsTrackRecordingEmpty(JNIEnv * env,
                                                                                                       jclass clazz)
{
  return frm()->IsTrackRecordingEmpty();
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeIsTrackRecordingEnabled(JNIEnv * env,
                                                                                                         jclass clazz)
{
  return frm()->IsTrackRecordingEnabled();
}
}
