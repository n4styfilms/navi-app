# CMake 3.22.1 with the NDK legacy toolchain can leave
# CMAKE_ANDROID_NDK_VERSION unset and select gold for IPO. NDK r28 ships LLD;
# selecting a host gold linker fails when linking ARM64 Android objects.
if(ANDROID)
  foreach(_navi_language C CXX)
    if(CMAKE_${_navi_language}_COMPILER_ID MATCHES "Clang")
      set(CMAKE_${_navi_language}_LINK_OPTIONS_IPO "-fuse-ld=lld")
    endif()
  endforeach()
  unset(_navi_language)
endif()
