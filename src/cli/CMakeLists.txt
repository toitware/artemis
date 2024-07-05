# Copyright (C) 2023 Toitware ApS.

set(ARTEMIS_SOURCE "${CMAKE_CURRENT_LIST_DIR}/cli.toit")
set(ARTEMIS_EXE "${CMAKE_BINARY_DIR}/bin/artemis${CMAKE_EXECUTABLE_SUFFIX}")
set(ARTEMIS_SNAPSHOT "${CMAKE_BINARY_DIR}/snapshots/artemis.snapshot")
set(ARTEMIS_DEP_EXE "${CMAKE_CURRENT_BINARY_DIR}/artemis_exe.toit.dep")
set(ARTEMIS_DEP_SNAPSHOT "${CMAKE_CURRENT_BINARY_DIR}/artemis_snapshot.toit.dep")
set(ARTEMIS_ARCH CACHE STRING "Target architecture for artemis")
set(ARTEMIS_OS CACHE STRING "Target OS for artemis")


ADD_TOIT_SNAPSHOT(
  ${ARTEMIS_SOURCE}
  ${ARTEMIS_SNAPSHOT}
  ${ARTEMIS_DEP_SNAPSHOT}
  ""
)

# Test that ARTEMIS_ARCH and ARTEMIS_OS are given if one of them is given.
if (ARTEMIS_ARCH AND NOT ARTEMIS_OS)
  message(FATAL_ERROR "ARTEMIS_ARCH is given but ARTEMIS_OS is not")
endif()
if (ARTEMIS_OS AND NOT ARTEMIS_ARCH)
  message(FATAL_ERROR "ARTEMIS_OS is given but ARTEMIS_ARCH is not")
endif()

set(ARCH_FLAG "")
if (ARTEMIS_ARCH)
  set(ARCH_FLAG "--arch" "${ARTEMIS_ARCH}")
endif()

set(OS_FLAG "")
if (ARTEMIS_OS)
  set(OS_FLAG "--os" "${ARTEMIS_OS}")
endif()

add_custom_command(
  OUTPUT ${ARTEMIS_EXE}
  COMMAND ${TOIT} compile ${ARCH_FLAG} ${OS_FLAG} -o ${ARTEMIS_EXE} ${ARTEMIS_SNAPSHOT}
  DEPENDS ${ARTEMIS_SNAPSHOT}
)

add_custom_target(
  build_cli
  DEPENDS ${ARTEMIS_EXE} ${ARTEMIS_SNAPSHOT}
)

add_dependencies(build build_cli)
