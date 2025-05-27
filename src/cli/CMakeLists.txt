# Copyright (C) 2023 Toitware ApS.

set(ARTEMIS_SOURCE "${CMAKE_CURRENT_LIST_DIR}/cli.toit")
set(ARTEMIS_EXE "${CMAKE_BINARY_DIR}/bin/artemis${CMAKE_EXECUTABLE_SUFFIX}")
set(ARTEMIS_DEP_EXE "${CMAKE_CURRENT_BINARY_DIR}/artemis_exe.toit.dep")
set(ARTEMIS_ARCH CACHE STRING "Target architecture for artemis")
set(ARTEMIS_OS CACHE STRING "Target OS for artemis")

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
  OUTPUT "${ARTEMIS_EXE}"
  DEPFILE ${ARTEMIS_DEP_EXE}
  DEPENDS download_packages "${ARTEMIS_SOURCE}"
  COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false
    "${TOIT}" compile
    ${ARCH_FLAG} ${OS_FLAG}
    --dependency-file "${ARTEMIS_DEP_EXE}"
    --dependency-format ninja
    -O2
    -o "${ARTEMIS_EXE}"
    "${ARTEMIS_SOURCE}"
)

add_custom_target(
  build_cli
  DEPENDS ${ARTEMIS_EXE}
)

add_dependencies(build build_cli)
