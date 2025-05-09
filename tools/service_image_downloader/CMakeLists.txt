# Copyright (C) 2023 Toitware ApS.

toit_project(uploader "${CMAKE_CURRENT_LIST_DIR}")

set(DOWNLOADER_SOURCE "${CMAKE_CURRENT_LIST_DIR}/downloader.toit")
set(DOWNLOADER_EXE "${CMAKE_BINARY_DIR}/bin/downloader${CMAKE_EXECUTABLE_SUFFIX}")
set(DOWNLOADER_DEP "${CMAKE_CURRENT_BINARY_DIR}/downloader.toit.dep")

ADD_TOIT_EXE(
  ${DOWNLOADER_SOURCE}
  ${DOWNLOADER_EXE}
  ${DOWNLOADER_DEP}
  ""
)

add_custom_target(
  build_uploader_exes
  DEPENDS ${UPLOADER_EXE} ${DOWNLOADER_EXE}
)

add_dependencies(build build_uploader_exes)
