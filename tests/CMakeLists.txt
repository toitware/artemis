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

function(extract_test_flags file result)
  file(READ "${file}" content)
  string(REGEX MATCHALL "// TEST_FLAGS: ([^\n]*)" flags "${content}")
  string(REPLACE " " ";" flags "${CMAKE_MATCH_1}")
  set(${result} "${flags}" PARENT_SCOPE)
endfunction()

foreach(file ${TESTS})
  extract_test_flags("${CMAKE_CURRENT_SOURCE_DIR}/${file}" flags)
  if (NOT flags)
    set(flags "--dummy")
  endif()

  foreach (flag ${flags})
    set(test_name "/tests/${file}")
    if (${flag} MATCHES "--dummy")
      set(flag "")
    endif()

    if (NOT "${flag}" STREQUAL "")
      set(test_name "${test_name}${flag}")
    endif()

    if("${test_name}" IN_LIST SKIP_TESTS)
      continue()
    endif()

    # Split the flags at "|".
    string(REPLACE "|" ";" flag "${flag}")

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
