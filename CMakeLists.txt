cmake_minimum_required(VERSION 3.25)
project(MacRemote VERSION 0.1.0 LANGUAGES C OBJC)
if(NOT APPLE)
  message(FATAL_ERROR "MacRemote requires macOS")
endif()
if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64|x86_64)$")
  message(FATAL_ERROR "Unsupported macOS CPU architecture: ${CMAKE_SYSTEM_PROCESSOR}")
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "Minimum macOS")
set(FREERDP_SOURCE_ROOT "" CACHE PATH "Pinned FreeRDP 3.33.1 checkout")
set(FREERDP_BUILD_ROOT "" CACHE PATH "Matching FreeRDP 3.33.1 build")
if(NOT IS_DIRECTORY "${FREERDP_SOURCE_ROOT}" OR
   NOT IS_DIRECTORY "${FREERDP_BUILD_ROOT}")
  message(FATAL_ERROR "Set FREERDP_SOURCE_ROOT and FREERDP_BUILD_ROOT")
endif()

set(SRC "${FREERDP_SOURCE_ROOT}")
set(BLD "${FREERDP_BUILD_ROOT}")
set(IMPL "${BLD}/server/shadow/Mac/libfreerdp-shadow-subsystem-impl.a")
set(LIBS
  "${BLD}/server/shadow/libfreerdp-shadow3.dylib"
  "${BLD}/server/common/libfreerdp-server3.dylib"
  "${BLD}/winpr/tools/libwinpr-tools3.dylib"
  "${BLD}/libfreerdp/libfreerdp3.dylib"
  "${BLD}/winpr/libwinpr/libwinpr3.dylib")
foreach(dep IN ITEMS ${IMPL} ${LIBS})
  if(NOT EXISTS "${dep}")
    message(FATAL_ERROR "FreeRDP dependency missing: ${dep}")
  endif()
endforeach()

set(CLIPRDR_OBJECTS
  "${BLD}/channels/cliprdr/server/CMakeFiles/cliprdr-server.dir/cliprdr_main.c.o"
  "${BLD}/channels/cliprdr/server/CMakeFiles/cliprdr-server.dir/__/cliprdr_common.c.o")
add_executable(macremote src/macremote.c src/graphics/rdp_graphics.c src/input/karabiner_compat.m
  src/input/mac_clipboard.m)

target_include_directories(macremote PRIVATE
  "${SRC}/include" "${BLD}/include" "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(macremote PRIVATE -Wall -Wextra -Werror)
target_compile_options(macremote PRIVATE "$<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>")
target_link_libraries(macremote PRIVATE ${IMPL} ${CLIPRDR_OBJECTS} ${LIBS}
  "-framework ScreenCaptureKit" "-framework CoreMedia"
  "-framework CoreVideo" "-framework Foundation"
  "-framework ApplicationServices" "-framework IOKit"
  "-framework AppKit" "-framework Carbon" "-lpam")
foreach(dir IN ITEMS
  "${BLD}/server/shadow" "${BLD}/server/common"
  "${BLD}/winpr/tools" "${BLD}/winpr/libwinpr" "${BLD}/libfreerdp")
  set_property(TARGET macremote APPEND PROPERTY BUILD_RPATH "${dir}")
endforeach()

enable_testing()
add_executable(test-karabiner-modifiers tests/test_karabiner_modifier_flags.c)
target_compile_options(test-karabiner-modifiers PRIVATE -Wall -Wextra -Werror)
target_link_libraries(test-karabiner-modifiers PRIVATE
  "-framework CoreGraphics" "-framework CoreFoundation")
add_test(NAME karabiner-modifier-flags COMMAND test-karabiner-modifiers)
# Exercise the actual pinned FreeRDP macOS Shadow keyboard callback.
# The test defines CGEventPost locally, so no keyboard event reaches the desktop.
add_executable(test-freerdp-karabiner-callback tests/test_freerdp_karabiner_callback.c src/input/karabiner_compat.m)
target_include_directories(test-freerdp-karabiner-callback PRIVATE
  "${SRC}/include" "${BLD}/include" "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(test-freerdp-karabiner-callback PRIVATE -Wall -Wextra -Werror)
target_compile_options(test-freerdp-karabiner-callback PRIVATE "$<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>")
target_link_libraries(test-freerdp-karabiner-callback PRIVATE ${IMPL} ${LIBS}
  "-framework ScreenCaptureKit" "-framework CoreMedia"
  "-framework CoreVideo" "-framework Foundation"
  "-framework ApplicationServices" "-framework IOKit"
  "-framework AppKit" "-framework Carbon" "-lpam")
foreach(dir IN ITEMS
  "${BLD}/server/shadow" "${BLD}/server/common"
  "${BLD}/winpr/tools" "${BLD}/winpr/libwinpr" "${BLD}/libfreerdp")
  set_property(TARGET test-freerdp-karabiner-callback APPEND PROPERTY BUILD_RPATH "${dir}")
endforeach()

add_test(NAME freerdp-karabiner-callback COMMAND test-freerdp-karabiner-callback)
add_executable(test-karabiner-compat
  tests/test_karabiner_compat.m src/input/karabiner_compat.m)
target_compile_options(test-karabiner-compat PRIVATE
  -Wall -Wextra -Werror -fobjc-arc)
target_link_libraries(test-karabiner-compat PRIVATE
  "-framework ApplicationServices" "-framework AppKit"
  "-framework Foundation" "-framework Carbon" "-framework IOKit")
add_test(NAME karabiner-compat COMMAND test-karabiner-compat)
add_executable(test-clipboard-crlf tests/test_clipboard_crlf.m)
target_include_directories(test-clipboard-crlf PRIVATE
  "${SRC}/include" "${BLD}/include"
  "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(test-clipboard-crlf PRIVATE -Wall -Wextra -Werror -fobjc-arc)
target_link_libraries(test-clipboard-crlf PRIVATE
  ${CLIPRDR_OBJECTS} ${LIBS} "-framework AppKit" "-framework Foundation")
foreach(dir IN ITEMS "${BLD}/server/shadow" "${BLD}/server/common"
   "${BLD}/winpr/tools" "${BLD}/winpr/libwinpr"
   "${BLD}/libfreerdp")
  set_property(TARGET test-clipboard-crlf APPEND PROPERTY BUILD_RPATH "${dir}")
endforeach()
add_test(NAME clipboard-windows-crlf COMMAND test-clipboard-crlf)
add_test(NAME version COMMAND macremote version)
add_test(NAME doctor COMMAND macremote doctor)
add_test(NAME reject-bad-port COMMAND macremote serve --port 0)
set_tests_properties(reject-bad-port PROPERTIES WILL_FAIL TRUE)

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  add_test(NAME cli-options
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_SOURCE_DIR}/tests/test_cli.py"
      "$<TARGET_FILE:macremote>")
endif()


# Actual FreeRDP server capability settings and 444/444v2 encoding smoke test.
add_executable(test-graphics-modes
  tests/test_graphics_modes.c src/graphics/rdp_graphics.c)
target_include_directories(test-graphics-modes PRIVATE
  "${SRC}/include" "${BLD}/include"
  "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(test-graphics-modes PRIVATE -Wall -Wextra -Werror)
target_link_libraries(test-graphics-modes PRIVATE "${BLD}/libfreerdp/libfreerdp3.dylib" "${BLD}/winpr/libwinpr/libwinpr3.dylib")
set_property(TARGET test-graphics-modes APPEND PROPERTY BUILD_RPATH
  "${BLD}/libfreerdp" "${BLD}/winpr/libwinpr")
add_test(NAME graphics-capability-modes COMMAND test-graphics-modes)

add_executable(test-avc444-encoder tests/test_avc444_encoder.c)
target_include_directories(test-avc444-encoder PRIVATE
  "${SRC}/include" "${BLD}/include"
  "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(test-avc444-encoder PRIVATE -Wall -Wextra -Werror)
target_link_libraries(test-avc444-encoder PRIVATE "${BLD}/libfreerdp/libfreerdp3.dylib" "${BLD}/winpr/libwinpr/libwinpr3.dylib")
set_property(TARGET test-avc444-encoder APPEND PROPERTY BUILD_RPATH
  "${BLD}/libfreerdp" "${BLD}/winpr/libwinpr")
add_test(NAME avc444-real-encoder COMMAND test-avc444-encoder)


# Verify actual AVC444 codecs round-trip images across two observed desktop
# sizes, not merely that they emit a compressed stream.
add_executable(test-avc444-roundtrip tests/test_avc444_roundtrip.c)
target_include_directories(test-avc444-roundtrip PRIVATE
  "${SRC}/include" "${BLD}/include"
  "${SRC}/winpr/include" "${BLD}/winpr/include")
target_compile_options(test-avc444-roundtrip PRIVATE -Wall -Wextra -Werror)
target_link_libraries(test-avc444-roundtrip PRIVATE
  "${BLD}/libfreerdp/libfreerdp3.dylib"
  "${BLD}/winpr/libwinpr/libwinpr3.dylib")
set_property(TARGET test-avc444-roundtrip APPEND PROPERTY BUILD_RPATH
  "${BLD}/libfreerdp" "${BLD}/winpr/libwinpr")
add_test(NAME avc444-real-roundtrip COMMAND test-avc444-roundtrip)
