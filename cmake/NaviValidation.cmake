# Numerical input boundaries must reject NaN/Infinity even when the surrounding
# rendering/routing project is built with fast floating-point optimizations.
function(navi_require_finite_math source)
  if(MSVC)
    set_property(SOURCE "${source}" APPEND PROPERTY COMPILE_OPTIONS /fp:precise)
  elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    set_property(SOURCE "${source}" APPEND PROPERTY COMPILE_OPTIONS -fno-fast-math)
  endif()
endfunction()
