# Copyright (C) 2023 Toitware ApS. All rights reserved.

set(SKIP_TESTS
)

set(FAIL_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND SKIP_TESTS
    # TODO(florian): fix mqtt test on Windows.
    "/tests/cmd_max_offline_test.toit --http-server --toit-mqtt-broker"
  )
endif()
