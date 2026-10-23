cmake_minimum_required(VERSION 3.22)
project(navi_capture_regression LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
get_filename_component(NAVI_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
include("${NAVI_ROOT}/cmake/NaviValidation.cmake")
navi_require_finite_math("${NAVI_ROOT}/libs/map/navi_route_snapshot.cpp")
navi_require_finite_math("${CMAKE_CURRENT_LIST_DIR}/../navi_capture_test.cpp")
if(NOT ANDROID)
  message(FATAL_ERROR "Use the Android NDK toolchain; this fixture runs on an Android device/emulator")
endif()
file(GLOB NAVI_BOOST_HEADERS LIST_DIRECTORIES true "${NAVI_ROOT}/3party/boost/libs/*/include")
set(NAVI_CAPTURE "${NAVI_ROOT}/libs/map/navi_route_capture.cpp")
add_executable(capture_tests
  ../navi_capture_test.cpp
  "${NAVI_CAPTURE}"
  "${NAVI_ROOT}/libs/map/navi_route_snapshot.cpp"
  "${NAVI_ROOT}/libs/routing/route.cpp"
  "${NAVI_ROOT}/libs/routing/road_warnings.cpp"
  "${NAVI_ROOT}/libs/routing/routing_options.cpp"
  "${NAVI_ROOT}/libs/routing/base/followed_polyline.cpp"
  "${NAVI_ROOT}/libs/routing/routing_settings.cpp"
  "${NAVI_ROOT}/libs/routing/segment.cpp"
  "${NAVI_ROOT}/libs/routing/vehicle_mask.cpp"
  "${NAVI_ROOT}/libs/routing/turns.cpp"
  "${NAVI_ROOT}/libs/geometry/mercator.cpp"
  "${NAVI_ROOT}/libs/geometry/distance_on_sphere.cpp"
  "${NAVI_ROOT}/libs/geometry/point_with_altitude.cpp"
  "${NAVI_ROOT}/libs/platform/distance.cpp"
  "${NAVI_ROOT}/libs/base/src_point.cpp"
  "${NAVI_ROOT}/libs/base/math.cpp"
)
target_include_directories(capture_tests PRIVATE "${NAVI_ROOT}" "${NAVI_ROOT}/libs"
  "${NAVI_ROOT}/3party/utfcpp/source" ${NAVI_BOOST_HEADERS})
target_compile_definitions(capture_tests PRIVATE RELEASE)
target_compile_options(capture_tests PRIVATE -O2 -ffast-math -ffunction-sections -fdata-sections)
target_link_options(capture_tests PRIVATE -Wl,--gc-sections)
navi_require_finite_math("${NAVI_CAPTURE}")
