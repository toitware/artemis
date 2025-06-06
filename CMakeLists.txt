# Copyright (C) 2022 Toitware ApS.

cmake_minimum_required(VERSION 3.23)

project(artemis)

set(TOIT "toit${CMAKE_EXECUTABLE_SUFFIX}" CACHE FILEPATH "The path to the toit executable")
set(TOIT_PKG_AUTO_SYNC ON CACHE BOOL "Whether toit pkg sync should be called automatically")

set(DEFAULT_SDK_VERSION CACHE STRING "The default SDK version to use")

set(ARTEMIS_GIT_VERSION "$ENV{ARTEMIS_GIT_VERSION}")
if ("${ARTEMIS_GIT_VERSION}" STREQUAL "")
  include(tools/gitversion.cmake)
  # The Git version is only computed when cmake generates the Ninja files, but
  # that should be good enough.
  compute_git_version(ARTEMIS_GIT_VERSION)
endif()

# Pull the major and minor version from the Git version.
string(REGEX MATCH "^v([0-9]+)\\.([0-9]+)" IGNORED "${ARTEMIS_GIT_VERSION}")
set(ARTEMIS_GIT_VERSION_MAJOR "${CMAKE_MATCH_1}")
set(ARTEMIS_GIT_VERSION_MINOR "${CMAKE_MATCH_2}")

# Replace the version in src/shared/version.toit.
configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/src/shared/version.toit.in
  ${CMAKE_CURRENT_SOURCE_DIR}/src/shared/version.toit
  @ONLY)

include("tools/toit.cmake")

# The package.yaml is located here, so we need to add the project here.
toit_project(artemis "${CMAKE_CURRENT_LIST_DIR}")

add_custom_target(build)

enable_testing()
add_subdirectory(tests)
add_subdirectory(src/cli)
add_subdirectory(tools/http_servers)
add_subdirectory(tools/lan_ip)
add_subdirectory(tools/service_image_uploader)
add_subdirectory(tools/snapshot)
