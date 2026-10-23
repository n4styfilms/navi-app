if (NOT PLATFORM_ANDROID)
  message(FATAL_ERROR "The headless fixture currently requires Android")
endif()
add_executable(navi_headless_tests ../navi_headless_test.cpp ../navi_test_platform.cpp
  ${OMIM_ROOT}/libs/map/map_tests/navi_headless_routing_scenario.cpp
  ${OMIM_ROOT}/libs/platform/localization_dummy.cpp
  ${OMIM_ROOT}/libs/platform/secure_storage_dummy.cpp
  ${OMIM_ROOT}/libs/platform/http_uploader_dummy.cpp
  ${OMIM_ROOT}/libs/platform/http_uploader_background_dummy.cpp)
target_link_libraries(navi_headless_tests PRIVATE map log android GLESv3 EGL)
target_link_options(navi_headless_tests PRIVATE
  "-Wl,--thinlto-cache-dir=${CMAKE_CURRENT_BINARY_DIR}/thinlto-cache")

add_executable(navi_existing_regressions ../navi_existing_regressions.cpp ../navi_test_platform.cpp
  ${OMIM_ROOT}/libs/routing/routing_tests/index_graph_tools.cpp
  ${OMIM_ROOT}/generator/generator_tests_support/routing_helpers.cpp
  ${OMIM_ROOT}/libs/platform/localization_dummy.cpp
  ${OMIM_ROOT}/libs/platform/secure_storage_dummy.cpp
  ${OMIM_ROOT}/libs/platform/http_uploader_dummy.cpp
  ${OMIM_ROOT}/libs/platform/http_uploader_background_dummy.cpp)
target_link_libraries(navi_existing_regressions PRIVATE map log android GLESv3 EGL)
target_link_options(navi_existing_regressions PRIVATE
  "-Wl,--thinlto-cache-dir=${CMAKE_CURRENT_BINARY_DIR}/thinlto-cache")
