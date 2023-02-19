# Copyright (C) 2023 Toitware ApS.

set(ARTEMIS_SOURCE "${CMAKE_CURRENT_LIST_DIR}/cli.toit")
set(ARTEMIS_EXE "${CMAKE_BINARY_DIR}/bin/artemis${CMAKE_EXECUTABLE_SUFFIX}")
set(ARTEMIS_SNAPSHOT "${CMAKE_BINARY_DIR}/snapshots/artemis.snapshot")
set(ARTEMIS_DEP_EXE "${CMAKE_CURRENT_BINARY_DIR}/artemis_exe.toit.dep")
set(ARTEMIS_DEP_SNAPSHOT "${CMAKE_CURRENT_BINARY_DIR}/artemis_snapshot.toit.dep")

ADD_TOIT_EXE(
  ${ARTEMIS_SOURCE}
  ${ARTEMIS_EXE}
  ${ARTEMIS_DEP_EXE}
  ""
)

ADD_TOIT_SNAPSHOT(
  ${ARTEMIS_SOURCE}
  ${ARTEMIS_SNAPSHOT}
  ${ARTEMIS_DEP_SNAPSHOT}
  ""
)

add_custom_target(
  build_cli
  DEPENDS ${ARTEMIS_EXE} ${ARTEMIS_SNAPSHOT}
)

add_dependencies(build build_cli)
