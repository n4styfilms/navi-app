#pragma once

#import "NaviRouteBridge.h"
#include "map/navi_route_snapshot.hpp"

// Kept out of the Swift bridging header. This copies values, never exposes the mutable core.
NaviRouteSnapshot * _Nonnull NaviSnapshotFromCore(navi::RouteSnapshot const & snapshot,
                                                 std::optional<uint64_t> knownGeometryRevision);
