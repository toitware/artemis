# Copyright (C) 2022 Toitware ApS.

file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.toit" "*_test_slow.toit")

set(TEST_TIMEOUT 40 CACHE STRING "The maximal amount of time each test is allowed to run")
set(SLOW_TEST_TIMEOUT 200 CACHE STRING "The maximal amount of time each slow test is allowed to run")

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

set (ARTEMIS_FLAGS "--supabase-server" "--http-server")
set (BROKER_FLAGS
      "--http-toit-broker"
      "--mosquitto-broker"
      # TODO(florian): reenable the toit MQTT server.
      # "--toit-mqtt"
      "--supabase-local-broker"
      "--supabase-local-artemis-broker"
    )

function (takes_artemis_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCH "// TEST_FLAGS:.*ARTEMIS" match "${content}")
  # Return the match if there was one.
  set(${result} ${match} PARENT_SCOPE)
endfunction()

function (takes_broker_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCH "// TEST_FLAGS:.*BROKER" match "${content}")
  # Return the match if there was one.
  set(${result} ${match} PARENT_SCOPE)
endfunction()

foreach(file ${TESTS})
  takes_artemis_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" artemis_match)
  takes_broker_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" broker_match)

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
      set(test_name "/tests/${file}")
      if (${artemis_flag} MATCHES "--dummy")
        set(artemis_flag "")
      endif()
      if (${broker_flag} MATCHES "--dummy")
        set(broker_flag "")
      endif()
      if ("${broker_flag}" STREQUAL "--supabase-local-artemis-broker" AND NOT "${artemis_flag}" STREQUAL "--supabase-server")
        # The supabase local broker requires the supabase server.
        continue()
      endif()
      if (NOT "${artemis_flag}" STREQUAL "" OR NOT "${broker_flag}" STREQUAL "")
        set(test_name "${test_name}${artemis_flag}${broker_flag}")
      endif()

      if("${test_name}" IN_LIST SKIP_TESTS)
        continue()
      endif()

      add_test(
        NAME "${test_name}"
        COMMAND "${TOITRUN}" "${file}" ${artemis_flag} ${broker_flag}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      )

      if ("${file}" MATCHES "_slow.toit")
        set_tests_properties(${test_name} PROPERTIES TIMEOUT ${SLOW_TEST_TIMEOUT})
      else()
        set_tests_properties(${test_name} PROPERTIES TIMEOUT ${TEST_TIMEOUT})
      endif()

      if("${test_name}" IN_LIST FAILING_TESTS)
        set_tests_properties("${test_name}" PROPERTIES WILL_FAIL TRUE)
      endif()
    endforeach()
  endforeach()
endforeach()
