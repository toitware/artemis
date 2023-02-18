# Copyright (C) 2022 Toitware ApS.

cmake_minimum_required(VERSION 3.23)

project(artemis)

set(TOITRUN "toit.run" CACHE FILEPATH "The executable used to run the tests")
set(TOITC "toit.compile" CACHE FILEPATH "The executable used to compile executables")
set(TOITPKG "toit.pkg" CACHE FILEPATH "The executable used to install the packages")

include("tools/toit.cmake")

# The package.yaml is located here, so we need to add the project here.
toit_project(artemis "${CMAKE_CURRENT_LIST_DIR}")

add_custom_target(build)

enable_testing()
add_subdirectory(tests)
add_subdirectory(src/cli)
add_subdirectory(tools/service_image_uploader)
