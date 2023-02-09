// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.device_specification show DeviceSpecification

parse str/string -> int:
  return DeviceSpecification.parse_max_offline_ str

expect_throws --contains/string [block]:
  exception := catch: block.call
  expect_not_null exception
  expect (exception.contains contains)

main:
  expect_equals 0 (parse "")
  expect_equals 0 (parse "0s")
  expect_equals 0 (parse "0m")
  expect_equals 0 (parse "0h")
  expect_equals 0 (parse "0h0m0s")

  expect_equals 5 (parse "5s")
  expect_equals 5 * 60 (parse "5m")
  expect_equals 5 * 60 * 60 (parse "5h")
  expect_equals 2 * 60 * 60 + 3 * 60 + 4 (parse "2h3m4s")
  expect_equals 2 * 60 * 60 + 3 * 60 (parse "2h3m")
  expect_equals 2 * 60 * 60 + 4 (parse "2h4s")

  expect_equals 2 * 60 * 60 + 3 * 60 + 4 (parse "2h 3m 4s")
  expect_equals 2 * 60 * 60 + 4 (parse "2h 4s")

  expect_equals 2 * 60 * 60 + 3 * 60 + 4 (parse "2 h 3 m 4 s")
  expect_equals 2 * 60 * 60 + 4 (parse "2 h 4 s")

  expect_equals 0 (parse " 0s ")
  expect_equals 2 * 60 * 60 + 4 (parse " 2h4s ")
  expect_equals 2 * 60 * 60 + 3 * 60 + 4 (parse " 2h3m4s ")

  expect_throws --contains="Invalid": parse "0"
  expect_throws --contains="Invalid": parse "0x"
  expect_throws --contains="Invalid": parse "0s0"
  expect_throws --contains="Invalid": parse "a"
  expect_throws --contains="Invalid": parse "0a"
  expect_throws --contains="Invalid": parse "0s0a"
  expect_throws --contains="Invalid": parse "0s0m"
  expect_throws --contains="Invalid": parse "0s0h"
  expect_throws --contains="Invalid": parse "0m0h"
  expect_throws --contains="Invalid": parse "0s0m0h"
  expect_throws --contains="Invalid": parse "0s0s0s"
  expect_throws --contains="Invalid": parse "0ss"
