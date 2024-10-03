# Copyright (C) 2022 Toitware ApS. All rights reserved.

file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit" "*-test-slow.toit")

set(TEST_TIMEOUT 200 CACHE STRING "The maximal amount of time each test is allowed to run")
set(SLOW_TEST_TIMEOUT 300 CACHE STRING "The maximal amount of time each slow test is allowed to run")
set(SERIAL_TEST_TIMEOUT 1000 CACHE STRING "The maximal amount of time each serial test is allowed to run")
set(WITH_LOCAL_SUPABASE TRUE CACHE BOOL "Whether the local supabase tests should be run")
set(WITH_QEMU TRUE CACHE BOOL "Whether the Qemu tests should run")

set(DEV_SDK_VERSION "" CACHE STRING "Version of the dev sdk")
set(DEV_SDK_PATH "" CACHE STRING "Path to the dev sdk")
set(DEV_ENVELOPE_ESP32_PATH "" CACHE STRING "Path to the dev esp32 envelope")
set(DEV_ENVELOPE_ESP32_QEMU_PATH "" CACHE STRING "Path to the dev esp32-qemu envelope")
set(DEV_ENVELOPE_HOST_PATH "" CACHE STRING "Path to the dev host envelope")

set(QEMU_PATH "qemu-system-xtensa" CACHE STRING "Path to the qemu binary")

toit_project(tests "${CMAKE_CURRENT_LIST_DIR}")

include(ProcessorCount)
ProcessorCount(NUM_CPU)

add_custom_target(
  check
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test --output-on-failure -C default
  USES_TERMINAL
)

add_custom_target(
  check_serial
  COMMAND ${CMAKE_CTEST_COMMAND} -j1 -T test --output-on-failure -C serial
  USES_TERMINAL
)

add_custom_target(
  check_supabase
  COMMAND ${CMAKE_CTEST_COMMAND} -j1 -T test --output-on-failure -C supabase
  USES_TERMINAL
)

set(TEST_PREFIX "")
include(fail.cmake OPTIONAL)

set (SUPABASE_ARTEMIS_TESTS
    "/tests/supabase-uploader-test.toit"
    "/tests/supabase-policies-test.toit"
    )

set (SUPABASE_ARTEMIS_BROKER_TESTS
    "/tests/supabase-artemis-broker-policies-test.toit"
    )

set (SUPABASE_BROKER_TESTS
    "/tests/supabase-broker-policies-test.toit"
    )

set (SUPABASE_ARTEMIS_FLAG "--supabase-server")
set (SUPABASE_ARTEMIS_BROKER_FLAG "--supabase-local-artemis-broker")
set (SUPABASE_BROKER_FLAG "--supabase-local-broker")

set (ARTEMIS_FLAGS ${SUPABASE_ARTEMIS_FLAG} "--http-server")
set (BROKER_FLAGS
      "--http-toit-broker"
      ${SUPABASE_BROKER_FLAG}
      ${SUPABASE_ARTEMIS_BROKER_FLAG}
    )

set (SUPABASE_FLAGS
      ${SUPABASE_ARTEMIS_FLAG}
      ${SUPABASE_BROKER_FLAG}
      ${SUPABASE_ARTEMIS_BROKER_FLAG}
)

if (NOT ${WITH_LOCAL_SUPABASE})
  list(REMOVE_ITEM ARTEMIS_FLAGS ${SUPABASE_ARTEMIS_FLAG})
  list(REMOVE_ITEM BROKER_FLAGS ${SUPABASE_BROKER_FLAG} ${SUPABASE_ARTEMIS_BROKER_FLAG})
endif()

function (takes_artemis_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCH "// ARTEMIS_TEST_FLAGS:.*ARTEMIS" match "${content}")
  # Return the match if there was one.
  set(${result} ${match} PARENT_SCOPE)
endfunction()

function (takes_broker_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCH "// ARTEMIS_TEST_FLAGS:.*BROKER" match "${content}")
  # Return the match if there was one.
  set(${result} ${match} PARENT_SCOPE)
endfunction()

function(extract_test_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCHALL "// TEST_FLAGS: ([^\n]*)" flags "${content}")
  string(REPLACE " " ";" flags "${CMAKE_MATCH_1}")
  set(${result} "${flags}" PARENT_SCOPE)
endfunction()

foreach(file ${TESTS})
  if ("${file}" MATCHES "supabase" AND NOT "${WITH_LOCAL_SUPABASE}")
    continue()
  endif()

  if ("${file}" MATCHES "qemu" AND NOT "${WITH_QEMU}")
    continue()
  endif()

  set (IS_SERIAL_TEST FALSE)
  if ("${file}" MATCHES "^serial")
    set (IS_SERIAL_TEST TRUE)
  endif()

  extract_test_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" flags)
  takes_artemis_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" artemis_match)
  takes_broker_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" broker_match)

  if (NOT "${artemis_match}" STREQUAL "" OR NOT "${broker_match}" STREQUAL "")
    # Build the test flags from the artemis and broker flags.
    if ("${artemis_match}" STREQUAL "")
      set(TEST_ARTEMIS_FLAGS "--dummy")
    else()
      set(TEST_ARTEMIS_FLAGS ${ARTEMIS_FLAGS})
    endif()
    if ("${broker_match}" STREQUAL "")
      set(TEST_BROKER_FLAGS "--dummy")
    else()
      set(TEST_BROKER_FLAGS ${BROKER_FLAGS})
    endif()
    foreach (artemis_flag ${TEST_ARTEMIS_FLAGS})
      foreach (broker_flag ${TEST_BROKER_FLAGS})
        if ("${artemis_flag}" STREQUAL "--dummy")
          set(artemis_flag "")
        endif()
        if ("${broker_flag}" STREQUAL "--dummy")
          set(broker_flag "")
        endif()

        if ("${broker_flag}" STREQUAL ${SUPABASE_ARTEMIS_BROKER_FLAG})
          if (NOT ("${artemis_flag}" STREQUAL ${SUPABASE_ARTEMIS_FLAG} OR "${artemis_flag}" STREQUAL ""))
            # Skip the artemis broker test if the test uses an artemis server but not the supabase one.
            continue()
          endif()
        endif()

        # Don't mix http and supabase flags.
        if ("${broker_flag}" IN_LIST SUPABASE_FLAGS AND NOT "${artemis_flag}" IN_LIST SUPABASE_FLAGS)
          continue()
        endif()
        if (NOT "${broker_flag}" IN_LIST SUPABASE_FLAGS AND "${artemis_flag}" IN_LIST SUPABASE_FLAGS)
          continue()
        endif()

        if ("${flags}" STREQUAL "")
          set(flags "${artemis_flag} ${broker_flag}")
        else()
          set(flags "${flags};${artemis_flag} ${broker_flag}")
        endif()
      endforeach()
    endforeach()
  endif()

  if (NOT flags)
    set(flags "--dummy")
  endif()

  foreach (flag ${flags})
    set(test_name "/tests/${file}")
    if (${flag} MATCHES "--dummy")
      set(flag "")
    endif()

    if (NOT "${flag}" STREQUAL "")
      set(test_name "${test_name} ${flag}")
    endif()

    if("${test_name}" IN_LIST SKIP_TESTS)
      continue()
    endif()

    # Split the flags at " ".
    string(REPLACE " " ";" flag "${flag}")

    set(IS_SUPABASE_TEST FALSE)

    set(RESOURCE_LOCKS)
    if (${test_name} IN_LIST SUPABASE_ARTEMIS_TESTS)
      list(APPEND RESOURCE_LOCKS "artemis_server")
      set(IS_SUPABASE_TEST TRUE)
    endif()
    if (${test_name} IN_LIST SUPABASE_ARTEMIS_BROKER_TESTS)
      list(APPEND RESOURCE_LOCKS "artemis_broker")
      set(IS_SUPABASE_TEST TRUE)
    endif()
    if (${test_name} IN_LIST SUPABASE_BROKER_TESTS)
      list(APPEND RESOURCE_LOCKS "broker")
      set(IS_SUPABASE_TEST TRUE)
    endif()
    if (SUPABASE_ARTEMIS_FLAG IN_LIST flag)
      list(APPEND RESOURCE_LOCKS "artemis_server")
      set(IS_SUPABASE_TEST TRUE)
    endif()
    if (SUPABASE_BROKER_FLAG IN_LIST flag)
      list(APPEND RESOURCE_LOCKS "broker")
      set(IS_SUPABASE_TEST TRUE)
    endif()
    if (SUPABASE_ARTEMIS_BROKER_FLAG IN_LIST flag)
      list(APPEND RESOURCE_LOCKS "artemis_broker")
      # Some broker tests need to modify the Artemis server to ensure that
      # devices exist. Make sure that the server is locked as well.
      list(APPEND RESOURCE_LOCKS "artemis_server")
      set(IS_SUPABASE_TEST TRUE)
    endif()

    if (${IS_SERIAL_TEST})
      list(APPEND RESOURCE_LOCKS "serial")
    endif()

    set(TEST_CONFIGURATIONS)
    if (${IS_SERIAL_TEST})
      set(TEST_CONFIGURATIONS "serial")
    else()
      set(TEST_CONFIGURATIONS "default")
    endif()
    if (${IS_SUPABASE_TEST} AND NOT ${IS_SERIAL_TEST})
      list(APPEND TEST_CONFIGURATIONS "supabase")
    endif()

    set(QEMU_FLAG "")
    if (${WITH_QEMU})
      set(QEMU_FLAG "--qemu=${QEMU_PATH}")
    endif()

    add_test(
      NAME "${test_name}"
      COMMAND cmake -E env TOIT_PACKAGE_CACHE_PATHS=${CMAKE_CURRENT_SOURCE_DIR}/.packages
        "${TOITRUN}" "${file}"
            ${flag}
            "--toit-run=${TOITRUN}"
            "--sdk-version=${DEV_SDK_VERSION}"
            "--sdk-path=${DEV_SDK_PATH}"
            "--envelope-esp32-path=${DEV_ENVELOPE_ESP32_PATH}"
            "--envelope-esp32-qemu-path=${DEV_ENVELOPE_ESP32_QEMU_PATH}"
            "--envelope-host-path=${DEV_ENVELOPE_HOST_PATH}"
            "--resource-locks=${RESOURCE_LOCKS}"
            "--base-root=${CMAKE_CURRENT_SOURCE_DIR}"
            ${QEMU_FLAG}
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      CONFIGURATIONS ${TEST_CONFIGURATIONS}
    )

    if (RESOURCE_LOCKS)
      set_tests_properties("${test_name}" PROPERTIES RESOURCE_LOCK "${RESOURCE_LOCKS}")
    endif()

    if ("${file}" MATCHES "-slow.toit")
      set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${SLOW_TEST_TIMEOUT})
    elseif ("${file}" MATCHES "^qemu-")
      set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${SLOW_TEST_TIMEOUT})
    elseif (${IS_SERIAL_TEST})
      set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${SERIAL_TEST_TIMEOUT})
    else()
      set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${TEST_TIMEOUT})
    endif()

    if("${test_name}" IN_LIST FAILING_TESTS)
      set_tests_properties("${test_name}" PROPERTIES WILL_FAIL TRUE)
    endif()
  endforeach()
endforeach()

add_subdirectory("spec_extends_tests")
