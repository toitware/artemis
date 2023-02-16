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
        if ("${broker_flag}" STREQUAL "--supabase-local-artemis-broker" AND NOT "${artemis_flag}" STREQUAL "--supabase-local")
          # Skip the artemis broker test if the artemis server is not running.
          continue()
        endif()

        if ("${artemis_flag}" STREQUAL "--dummy")
          set(artemis_flag "")
        endif()
        if ("${broker_flag}" STREQUAL "--dummy")
          set(broker_flag "")
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

    add_test(
      NAME "${test_name}"
      COMMAND "${TOITRUN}" "${file}" ${flag}
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

# Lock the artemis server to a single test for the following tests.
# They use global properties interfering with the sdk table.
set_tests_properties("/tests/uploader_test.toit" PROPERTIES RESOURCE_LOCK "artemis_server")
set_tests_properties("/tests/supabase_policies_test.toit" PROPERTIES RESOURCE_LOCK "artemis_server")
