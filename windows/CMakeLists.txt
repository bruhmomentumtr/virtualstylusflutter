# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(virtualstylus LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "virtualstylus")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
#
# Workaround for flutter_webrtc on Windows: the plugin's CMakeLists.txt
# downloads and extracts the libwebrtc archive via file(ARCHIVE_EXTRACT),
# which fails with "Cannot extract through symlink" because the plugin
# lives at windows/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/ —
# a Windows symlink to the read-only pub cache, and libarchive refuses
# to write through symlinks.
#
# We work around this by:
#   1. Copying the plugin source to a non-symlinked directory under
#      CMAKE_BINARY_DIR (only when not already present).
#   2. Pre-downloading the libwebrtc archive into that copy.
#   3. Pre-extracting it so the plugin's CMakeLists.txt sees the LICENSE
#      file and skips file(ARCHIVE_EXTRACT) entirely.
#   4. Patching generated_plugins.cmake in-memory so flutter_webrtc is
#      added from the copy, while every other plugin keeps using its
#      existing symlink. The original .plugin_symlinks/flutter_webrtc
#      symlink is left intact so subsequent `flutter pub get` /
#      `flutter build` invocations can recreate it without "path
# already exists" errors.
set(_vs_webRTC_real_root "${CMAKE_BINARY_DIR}/_vs_real_plugins")
set(_vs_webRTC_real_plugin "${_vs_webRTC_real_root}/flutter_webrtc/windows")
set(_vs_webRTC_sym_plugin "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/windows")

if(NOT EXISTS "${_vs_webRTC_real_plugin}/CMakeLists.txt")
  message(STATUS "flutter_webrtc: copying plugin to ${_vs_webRTC_real_plugin}")
  file(MAKE_DIRECTORY "${_vs_webRTC_real_plugin}")
  file(COPY "${_vs_webRTC_sym_plugin}/" DESTINATION "${_vs_webRTC_real_plugin}")
endif()

set(_vs_webRTC_third_party "${_vs_webRTC_real_plugin}/third_party")
set(_vs_webRTC_license "${_vs_webRTC_third_party}/libwebrtc-x64-release/LICENSE")
if(NOT EXISTS "${_vs_webRTC_license}")
  message(STATUS "flutter_webrtc: pre-extracting libwebrtc (skips plugin's file(ARCHIVE_EXTRACT))")
  set(_vs_webRTC_downloads "${_vs_webRTC_third_party}/downloads")
  file(MAKE_DIRECTORY "${_vs_webRTC_downloads}")
  set(_vs_webRTC_zip "${_vs_webRTC_downloads}/libwebrtc-win-x64-release.zip")
  file(DOWNLOAD
    "https://github.com/webrtc-sdk/libwebrtc/releases/download/libwebrtc.m144.7559.09/libwebrtc-win-x64-release.zip"
    "${_vs_webRTC_zip}"
    SHOW_PROGRESS
    STATUS _vs_webRTC_dl_status)
  list(GET _vs_webRTC_dl_status 0 _vs_webRTC_dl_code)
  if(NOT _vs_webRTC_dl_code EQUAL 0)
    message(FATAL_ERROR "flutter_webrtc: libwebrtc download failed: ${_vs_webRTC_dl_status}")
  endif()
  file(ARCHIVE_EXTRACT INPUT "${_vs_webRTC_zip}" DESTINATION "${_vs_webRTC_third_party}")
endif()

# Patch generated_plugins.cmake so flutter_webrtc is added from our
# non-symlinked copy, while every other plugin keeps its existing
# symlinked path. The substitution runs on the file contents as a string;
# the ${plugin} / ${CMAKE_BINARY_DIR} placeholders are preserved in the
# written file and expanded at include time.
set(_vs_plugins_file "${CMAKE_CURRENT_SOURCE_DIR}/flutter/generated_plugins.cmake")
file(READ "${_vs_plugins_file}" _vs_plugins_content)
set(_vs_orig_line "add_subdirectory(flutter/ephemeral/.plugin_symlinks/\${plugin}/windows plugins/\${plugin})")
set(_vs_patched_line "if(\${plugin} STREQUAL \"flutter_webrtc\")\n  add_subdirectory(\${CMAKE_BINARY_DIR}/_vs_real_plugins/\${plugin}/windows plugins/\${plugin})\nelse()\n  add_subdirectory(flutter/ephemeral/.plugin_symlinks/\${plugin}/windows plugins/\${plugin})\nendif()")
string(REPLACE "${_vs_orig_line}" "${_vs_patched_line}" _vs_plugins_content_new "${_vs_plugins_content}")

if(_vs_plugins_content STREQUAL _vs_plugins_content_new)
  message(WARNING "flutter_webrtc: generated_plugins.cmake patch did not match; build may fail")
endif()

set(_vs_plugins_patched "${CMAKE_BINARY_DIR}/generated_plugins_patched.cmake")
file(WRITE "${_vs_plugins_patched}" "${_vs_plugins_content_new}")
include("${_vs_plugins_patched}")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
