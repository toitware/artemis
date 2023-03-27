# Copyright (C) 2022 Toitware ApS.

cmake_minimum_required(VERSION 3.23)

project(artemis)

set(TOITRUN "toit.run" CACHE FILEPATH "The executable used to run the tests")
set(TOITC "toit.compile" CACHE FILEPATH "The executable used to compile executables")
set(TOITPKG "toit.pkg" CACHE FILEPATH "The executable used to install the packages")

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
  src/shared/version.toit.in
  ${CMAKE_CURRENT_SOURCE_DIR}/src/shared/version.toit
  @ONLY)

include("tools/toit.cmake")

# The package.yaml is located here, so we need to add the project here.
toit_project(artemis "${CMAKE_CURRENT_LIST_DIR}")

add_custom_target(build)

enable_testing()
add_subdirectory(tests)
add_subdirectory(src/cli)
add_subdirectory(tools/lan_ip)
add_subdirectory(tools/service_image_uploader)
add_subdirectory(tools/snapshot)
