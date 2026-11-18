cmake_minimum_required(VERSION 3.25)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "Minimum macOS")
project(MacRemote VERSION 0.2.1 LANGUAGES C OBJC)
if(NOT APPLE)
  message(FATAL_ERROR "MacRemote requires macOS")
endif()
if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64|x86_64)$")
  message(FATAL_ERROR "Unsupported macOS CPU architecture: ${CMAKE_SYSTEM_PROCESSOR}")
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(FREERDP_SOURCE_ROOT "" CACHE PATH "Pinned FreeRDP 3.33.1 checkout")
set(FREERDP_BUILD_ROOT "" CACHE PATH "Matching FreeRDP 3.33.1 build")
if(NOT IS_DIRECTORY "${FREERDP_SOURCE_ROOT}" OR
   NOT IS_DIRECTORY "${FREERDP_BUILD_ROOT}")
  message(FATAL_ERROR "Set FREERDP_SOURCE_ROOT and FREERDP_BUILD_ROOT")
endif()

set(src "${FREERDP_SOURCE_ROOT}")
set(build "${FREERDP_BUILD_ROOT}")
set(shadow_impl "${build}/server/shadow/Mac/libfreerdp-shadow-subsystem-impl.a")
set(cliprdr_dir "${build}/channels/cliprdr/server/CMakeFiles/cliprdr-server.dir")
set(cliprdr_objects
  "${cliprdr_dir}/cliprdr_main.c.o"
  "${cliprdr_dir}/__/cliprdr_common.c.o")

add_library(freerdp-codecs INTERFACE)
target_include_directories(freerdp-codecs INTERFACE
  "${src}/include" "${build}/include"
  "${src}/winpr/include" "${build}/winpr/include")
target_link_libraries(freerdp-codecs INTERFACE
  "${build}/libfreerdp/libfreerdp3.dylib"
  "${build}/winpr/libwinpr/libwinpr3.dylib")

add_library(freerdp-shadow INTERFACE)
target_link_libraries(freerdp-shadow INTERFACE
  "${build}/server/shadow/libfreerdp-shadow3.dylib"
  "${build}/server/common/libfreerdp-server3.dylib"
  "${build}/winpr/tools/libwinpr-tools3.dylib"
  freerdp-codecs)

add_compile_options(-Wall -Wextra -Werror "$<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>")

add_library(karabiner-compat STATIC src/input/karabiner_compat.m)
target_link_libraries(karabiner-compat PUBLIC
  "-framework AppKit" "-framework ApplicationServices"
  "-framework Carbon" "-framework IOKit")

add_library(mac-shadow INTERFACE)
target_link_libraries(mac-shadow INTERFACE
  "${shadow_impl}" freerdp-shadow karabiner-compat
  "-framework ScreenCaptureKit" "-framework CoreMedia" "-framework CoreVideo" "-lpam")

find_package(PkgConfig REQUIRED)
pkg_check_modules(OPUS REQUIRED IMPORTED_TARGET opus)
add_library(remote-audio STATIC src/audio/remote_audio.c)
target_include_directories(remote-audio PRIVATE "${src}/server/shadow/Mac")
target_link_libraries(remote-audio PUBLIC mac-shadow PkgConfig::OPUS)

add_executable(macremote
  src/macremote.c src/graphics/rdp_graphics.c src/input/mac_clipboard.m
  src/input/clipboard_formats.m src/display/device_display.m
  src/device/client_preferences.m)
target_link_libraries(macremote PRIVATE remote-audio ${cliprdr_objects})

enable_testing()

function(macremote_test name source)
  add_executable(test-${name} "${source}" ${ARGN})
  add_test(NAME ${name} COMMAND test-${name})
endfunction()

macremote_test(pointer-geometry tests/test_pointer_geometry.c)

macremote_test(surface-geometry tests/test_surface_geometry.c)
target_include_directories(test-surface-geometry PRIVATE "${src}/server/shadow/Mac")

macremote_test(capture-logical tests/test_capture_logical.c)
target_include_directories(test-capture-logical PRIVATE "${src}/server/shadow/Mac")
target_link_libraries(test-capture-logical PRIVATE "-framework CoreGraphics")

macremote_test(device-display-memory tests/test_device_display.m)
target_link_libraries(test-device-display-memory PRIVATE
  "-framework Foundation" "-framework ApplicationServices")

macremote_test(client-preferences-audio tests/test_client_preferences.m)
target_include_directories(test-client-preferences-audio PRIVATE "${src}/server/shadow/Mac")
target_link_libraries(test-client-preferences-audio PRIVATE remote-audio "-framework Foundation")

macremote_test(karabiner-modifier-flags tests/test_karabiner_modifier_flags.c)
target_link_libraries(test-karabiner-modifier-flags PRIVATE
  "-framework CoreGraphics" "-framework CoreFoundation")

# The callback test interposes CGEventPost to keep events off the desktop.
macremote_test(freerdp-karabiner-callback tests/test_freerdp_karabiner_callback.c)
target_link_libraries(test-freerdp-karabiner-callback PRIVATE mac-shadow)

macremote_test(karabiner-compat tests/test_karabiner_compat.m)
target_link_libraries(test-karabiner-compat PRIVATE karabiner-compat)

macremote_test(clipboard-interoperability tests/test_clipboard.m src/input/clipboard_formats.m)
target_link_libraries(test-clipboard-interoperability PRIVATE
  ${cliprdr_objects} freerdp-shadow "-framework AppKit" "-framework Foundation")

macremote_test(graphics-capability-modes tests/test_graphics_modes.c src/graphics/rdp_graphics.c)
target_link_libraries(test-graphics-capability-modes PRIVATE freerdp-codecs)

macremote_test(avc444-real-encoder tests/test_avc444_encoder.c)
target_link_libraries(test-avc444-real-encoder PRIVATE freerdp-codecs)

macremote_test(avc444-real-roundtrip tests/test_avc444_roundtrip.c)
target_link_libraries(test-avc444-real-roundtrip PRIVATE freerdp-codecs)

add_test(NAME version COMMAND macremote version)
add_test(NAME doctor COMMAND macremote doctor)
add_test(NAME reject-bad-port COMMAND macremote serve --port 0)
set_tests_properties(reject-bad-port PROPERTIES WILL_FAIL TRUE)

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  add_test(NAME cli-options COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_cli.py" "$<TARGET_FILE:macremote>")
endif()
