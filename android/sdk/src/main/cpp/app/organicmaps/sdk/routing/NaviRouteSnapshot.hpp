#pragma once

#include "map/navi_route_snapshot.hpp"
#include <jni.h>

// knownGeometryRevision is the revision actually drawn, not just the last BUILDING snapshot.
// Use -1 for a fresh view. The caller must be on the existing Framework GUI thread.
jobject ToJavaNaviRouteSnapshot(JNIEnv * env, navi::RouteSnapshot const & snapshot, jlong knownGeometryRevision);
