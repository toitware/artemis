# Copyright (C) 2022 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.toit" "*_test_slow.toit")

set(TEST_TIMEOUT 40 CACHE STRING "The maximal amount of time each test is allowed to run")
set(SLOW_TEST_TIMEOUT 200 CACHE STRING "The maximal amount of time each slow test is allowed to run")
set(WITH_MOSQUITTO TRUE CACHE BOOL "Whether the tests should run with mosquitto")
set(WITH_TOIT_MQTT TRUE CACHE BOOL "Whether the tests should run with Toit's MQTT broker")

toit_project(tests "${CMAKE_CURRENT_LIST_DIR}")

include(ProcessorCount)
ProcessorCount(NUM_CPU)

add_custom_target(
  check
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test --output-on-failure
  USES_TERMINAL
)

set(TEST_PREFIX "")
include(fail.cmake OPTIONAL)

message("Failing tests: ${FAILING_TESTS}")
message("Skipped tests: ${SKIP_TESTS}")

if (${WITH_MOSQUITTO})
  set(TEST_FLAGS ${TEST_FLAGS} "mosquitto")
endif()

if (${WITH_TOIT_MQTT})
  set(TEST_FLAGS ${TEST_FLAGS} "toit-mqtt")
endif()

foreach(file ${TESTS})
  set(test_name "/tests/${file}")
  if("${test_name}" IN_LIST SKIP_TESTS)
    continue()
  endif()

  add_test(
    NAME "${test_name}"
    COMMAND "${TOITRUN}" "${file}" ${TEST_FLAGS}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  )

  if ("${file}" MATCHES "slow.toit")
    set_tests_properties(${test_name} PROPERTIES TIMEOUT ${SLOW_TEST_TIMEOUT})
  else()
    set_tests_properties(${test_name} PROPERTIES TIMEOUT ${TEST_TIMEOUT})
  endif()

  if("${test_name}" IN_LIST FAILING_TESTS)
    set_tests_properties("${test_name}" PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
