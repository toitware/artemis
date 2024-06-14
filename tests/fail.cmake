# Copyright (C) 2023 Toitware ApS. All rights reserved.

set(SKIP_TESTS
)

set(FAIL_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND SKIP_TESTS
    # Windows doesn't have a good way to kill subprocesses.
    # Don't run tests that use the host-envelope.
    "/tests/cmd-device-extract-test.toit --http-server --http-toit-broker"
    "/tests/cmd-fleet-add-device-test.toit --http-server --http-toit-broker"
    "/tests/cmd-fleet-migration-test-slow.toit"
    "/tests/cmd-fleet-migration2-test-slow.toit"
    "/tests/host-hello-test.toit --http-server --http-toit-broker"
  )
endif()
