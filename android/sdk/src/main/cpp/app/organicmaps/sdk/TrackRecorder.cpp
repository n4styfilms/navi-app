#include "Framework.hpp"

#include "map/gps_tracker.hpp"

#include "app/organicmaps/sdk/core/jni_helper.hpp"
#include "cppjansson/cppjansson.hpp"

#include <chrono>
#include <exception>

namespace
{
base::JSONPtr TripMetadata(navi::TripMetadata const & trip)
{
  auto result = base::NewJSONObject();
  ToJSONObject(*result, "id", trip.id);
  ToJSONObject(*result, "passenger", trip.role == navi::TripRole::Passenger);
  ToJSONObject(*result, "startedAtMs", trip.startedAtMs);
  ToJSONObject(*result, "endedAtMs", trip.endedAtMs);
  return result;
}

jstring TripJson(JNIEnv * env, base::JSONPtr const & value)
{
  std::unique_ptr<char, JSONFreeDeleter> json(json_dumps(value.get(), JSON_COMPACT));
  return json ? jni::ToJavaString(env, json.get()) : nullptr;
}
}

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

JNIEXPORT jstring JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeNaviTripState(JNIEnv * env, jclass)
{
  try
  {
    auto store = frm()->GetNaviTripStore();
    auto result = base::NewJSONObject();
    auto trips = base::NewJSONArray();
    for (auto const & trip : store.List())
      json_array_append_new(trips.get(), TripMetadata(trip).release());
    ToJSONObject(*result, "trips", std::move(trips));
    if (auto const pending = store.Pending())
      ToJSONObject(*result, "pending", TripMetadata(*pending));
    return TripJson(env, result);
  }
  catch (std::exception const &)
  {
    return nullptr;
  }
}

JNIEXPORT jstring JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeNaviTripStatistics(
    JNIEnv * env, jclass, jstring identifier)
{
  try
  {
    auto const analysis = frm()->GetNaviTripStore().Load(jni::ToNativeString(env, identifier));
    auto result = base::NewJSONObject();
    ToJSONObject(*result, "distanceMeters", analysis.distanceMeters);
    ToJSONObject(*result, "rawCount", static_cast<uint64_t>(analysis.rawCount));
    ToJSONObject(*result, "gapCount", static_cast<uint64_t>(analysis.gapCount));
    ToJSONObject(*result, "rejectedCount", static_cast<uint64_t>(analysis.rejected.size()));
    if (analysis.maximumSpeedMetersPerSecond)
      ToJSONObject(*result, "maximumSpeedMetersPerSecond", *analysis.maximumSpeedMetersPerSecond);
    auto const preview = navi::BuildTripGeometry(analysis, 8192, 100);
    auto segments = base::NewJSONArray();
    for (auto const & segment : preview.segments)
    {
      auto coordinates = base::NewJSONArray();
      for (auto const & point : segment)
      {
        auto pair = base::NewJSONArray();
        json_array_append_new(pair.get(), json_real(point.m_lat));
        json_array_append_new(pair.get(), json_real(point.m_lon));
        json_array_append_new(coordinates.get(), pair.release());
      }
      json_array_append_new(segments.get(), coordinates.release());
    }
    ToJSONObject(*result, "segments", std::move(segments));
    ToJSONObject(*result, "geometrySimplified", preview.simplified);
    return TripJson(env, result);
  }
  catch (std::exception const &)
  {
    return nullptr;
  }
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeSetNaviTripPassenger(
    JNIEnv * env, jclass, jstring identifier, jboolean passenger)
{
  try
  {
    auto const role = passenger ? navi::TripRole::Passenger : navi::TripRole::Driver;
    frm()->GetNaviTripStore().SetRole(jni::ToNativeString(env, identifier), role);
    return JNI_TRUE;
  }
  catch (std::exception const &)
  {
    return JNI_FALSE;
  }
}

JNIEXPORT jboolean JNICALL Java_app_organicmaps_sdk_location_TrackRecorder_nativeDeleteNaviTrip(
    JNIEnv * env, jclass, jstring identifier)
{
  try
  {
    frm()->GetNaviTripStore().Delete(jni::ToNativeString(env, identifier));
    return JNI_TRUE;
  }
  catch (std::exception const &)
  {
    return JNI_FALSE;
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
