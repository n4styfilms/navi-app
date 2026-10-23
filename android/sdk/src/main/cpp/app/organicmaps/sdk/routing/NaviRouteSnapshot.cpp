#include "app/organicmaps/sdk/routing/NaviRouteSnapshot.hpp"
#include "3party/utfcpp/source/utf8.h"

#include <iterator>
#include <string>

namespace
{
jstring ToString(JNIEnv * env, std::string const & value)
{
  // JNI's NewStringUTF takes modified UTF-8, not the core's UTF-8 (including emoji).
  std::string valid;
  utf8::replace_invalid(value.begin(), value.end(), std::back_inserter(valid));
  std::u16string text;
  utf8::utf8to16(valid.begin(), valid.end(), std::back_inserter(text));
  return env->NewString(reinterpret_cast<jchar const *>(text.data()), static_cast<jsize>(text.size()));
}

jobjectArray Points(JNIEnv * env, std::vector<navi::LatLon> const & points, jclass type, jmethodID ctor)
{
  auto result = env->NewObjectArray(static_cast<jsize>(points.size()), type, nullptr);
  if (!result) return nullptr;
  for (jsize i = 0; i < static_cast<jsize>(points.size()); ++i)
  {
    auto const & p = points[i];
    auto point = env->NewObject(type, ctor, p.latitude, p.longitude);
    if (!point) return nullptr;
    env->SetObjectArrayElement(result, i, point);
    env->DeleteLocalRef(point);
    if (env->ExceptionCheck()) return nullptr;
  }
  return result;
}
}  // namespace

jobject ToJavaNaviRouteSnapshot(JNIEnv * env, navi::RouteSnapshot const & s, jlong knownGeometryRevision)
{
  static_assert(static_cast<int>(navi::RouteState::Failed) == 4);
  static_assert(static_cast<int>(navi::RoadWarningType::Unpaved) == 2);
  if (env->PushLocalFrame(40) < 0) return nullptr;
  auto finish = [env](jobject result) { return env->PopLocalFrame(result); };
  auto type = env->FindClass("app/organicmaps/sdk/routing/NaviRouteSnapshot");
  if (!type) return finish(nullptr);
  auto pointType = env->FindClass("app/organicmaps/sdk/routing/NaviRouteSnapshot$LatLon");
  if (!pointType) return finish(nullptr);
  auto warningType = env->FindClass("app/organicmaps/sdk/routing/NaviRouteSnapshot$RoadWarning");
  if (!warningType) return finish(nullptr);
  auto stringType = env->FindClass("java/lang/String");
  if (!stringType) return finish(nullptr);
  auto doubleType = env->FindClass("java/lang/Double");
  if (!doubleType) return finish(nullptr);
  auto pointCtor = env->GetMethodID(pointType, "<init>", "(DD)V");
  if (!pointCtor) return finish(nullptr);
  auto warningCtor = env->GetMethodID(warningType, "<init>",
      "(ILapp/organicmaps/sdk/routing/NaviRouteSnapshot$LatLon;D)V");
  if (!warningCtor) return finish(nullptr);
  auto doubleCtor = env->GetMethodID(doubleType, "<init>", "(D)V");
  if (!doubleCtor) return finish(nullptr);
  auto ctor = env->GetMethodID(type, "<init>",
      "(JIZ[Lapp/organicmaps/sdk/routing/NaviRouteSnapshot$LatLon;"
      "Ljava/lang/Double;Ljava/lang/Double;Ljava/lang/Double;Ljava/lang/Double;"
      "Ljava/lang/Double;Ljava/lang/Double;ILjava/lang/String;Ljava/lang/String;"
      "[Ljava/lang/String;[Lapp/organicmaps/sdk/routing/NaviRouteSnapshot$RoadWarning;"
      "[Lapp/organicmaps/sdk/routing/NaviRouteSnapshot$LatLon;I)V");
  if (!ctor) return finish(nullptr);

  bool const ready = s.state == navi::RouteState::Preview || s.state == navi::RouteState::Navigating;
  bool const includeGeometry = !ready || static_cast<jlong>(s.revision) != knownGeometryRevision;
  static std::vector<navi::LatLon> const emptyGeometry;
  auto geometry = Points(env, includeGeometry ? s.geometry : emptyGeometry, pointType, pointCtor);
  if (!geometry) return finish(nullptr);
  auto lights = Points(env, s.trafficLights, pointType, pointCtor);
  if (!lights) return finish(nullptr);
  auto warnings = env->NewObjectArray(static_cast<jsize>(s.roadWarnings.size()), warningType, nullptr);
  if (!warnings) return finish(nullptr);
  for (jsize i = 0; i < static_cast<jsize>(s.roadWarnings.size()); ++i)
  {
    auto const & w = s.roadWarnings[i];
    auto position = env->NewObject(pointType, pointCtor, w.position.latitude, w.position.longitude);
    if (!position) return finish(nullptr);
    auto warning = env->NewObject(warningType, warningCtor, static_cast<jint>(w.type), position, w.distanceMeters);
    env->DeleteLocalRef(position);
    if (!warning) return finish(nullptr);
    env->SetObjectArrayElement(warnings, i, warning);
    env->DeleteLocalRef(warning);
    if (env->ExceptionCheck()) return finish(nullptr);
  }
  auto notifications = env->NewObjectArray(static_cast<jsize>(s.turnNotifications.size()), stringType, nullptr);
  if (!notifications) return finish(nullptr);
  for (jsize i = 0; i < static_cast<jsize>(s.turnNotifications.size()); ++i)
  {
    auto text = ToString(env, s.turnNotifications[i]);
    if (!text) return finish(nullptr);
    env->SetObjectArrayElement(notifications, i, text);
    env->DeleteLocalRef(text);
    if (env->ExceptionCheck()) return finish(nullptr);
  }
  auto street = ToString(env, s.street);
  if (!street) return finish(nullptr);
  auto nextStreet = ToString(env, s.nextStreet);
  if (!nextStreet) return finish(nullptr);
  auto box = [&](std::optional<double> const & value) -> jobject
  {
    return value ? env->NewObject(doubleType, doubleCtor, *value) : nullptr;
  };
  jobject metrics[6];
  std::optional<double> const values[] = {s.totalDistanceMeters, s.remainingDistanceMeters,
      s.totalTimeSeconds, s.remainingTimeSeconds, s.distanceToTurnMeters, s.speedLimitKmh};
  for (size_t i = 0; i < 6; ++i)
  {
    metrics[i] = box(values[i]);
    if (env->ExceptionCheck()) return finish(nullptr);
  }
  auto result = env->NewObject(type, ctor, static_cast<jlong>(s.revision), static_cast<jint>(s.state),
      static_cast<jboolean>(includeGeometry), geometry, metrics[0], metrics[1], metrics[2], metrics[3],
      metrics[4], metrics[5], static_cast<jint>(s.nextTurn), street, nextStreet,
      notifications, warnings, lights, static_cast<jint>(s.errorCode));
  return finish(result);
}
