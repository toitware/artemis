# Copyright (C) 2023 Toitware ApS. All rights reserved.

file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.yaml")

foreach(TEST ${TESTS})
  file(RELATIVE_PATH TEST_NAME "${CMAKE_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/${TEST}")
  string(REPLACE "_test.yaml" "_expected.json" EXPECTED ${TEST})
  string(REPLACE "_test.yaml" "_fail.gold" FAIL ${TEST})

  add_test(
    NAME "${TEST_NAME}"
    COMMAND "${TOIT}" run.toit ${TEST} ${EXPECTED} ${FAIL}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS default
  )
endforeach()
