# Copyright (C) 2023 Toitware ApS.

toit_project(snapshot_uuid "${CMAKE_CURRENT_LIST_DIR}")

set(SNAPSHOT_UUID_SOURCE "${CMAKE_CURRENT_LIST_DIR}/snapshot-uuid.toit")
set(SNAPSHOT_UUID_EXE "${CMAKE_BINARY_DIR}/bin/snapshot_uuid${CMAKE_EXECUTABLE_SUFFIX}")
set(SNAPSHOT_UUID_DEP "${CMAKE_CURRENT_BINARY_DIR}/snapshot-uuid.toit.dep")

ADD_TOIT_EXE(
  ${SNAPSHOT_UUID_SOURCE}
  ${SNAPSHOT_UUID_EXE}
  ${SNAPSHOT_UUID_DEP}
  ""
)

add_custom_target(
  build_snapshot_uuid
  DEPENDS ${SNAPSHOT_UUID_EXE}
)

add_dependencies(build build_snapshot_uuid)
