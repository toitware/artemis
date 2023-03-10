// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.utils show parse_duration

parse str/string -> Duration:
  return parse_duration str --on_error=: throw "Illegal"

expect_parse_error str/string:
  parse_duration str --on_error=: return
  throw "Expected parse error"

expect_equals_seconds s/int duration/Duration:
  expect_equals s duration.in_s

main:
  expect_equals_seconds 0 (parse "0s")
  expect_equals_seconds 0 (parse "0m")
  expect_equals_seconds 0 (parse "0h")
  expect_equals_seconds 0 (parse "0h0m0s")

  expect_equals_seconds 5 (parse "5s")
  expect_equals_seconds 5 * 60 (parse "5m")
  expect_equals_seconds 5 * 60 * 60 (parse "5h")
  expect_equals_seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2h3m4s")
  expect_equals_seconds 2 * 60 * 60 + 3 * 60 (parse "2h3m")
  expect_equals_seconds 2 * 60 * 60 + 4 (parse "2h4s")

  expect_equals_seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2h 3m 4s")
  expect_equals_seconds 2 * 60 * 60 + 4 (parse "2h 4s")

  expect_equals_seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2 h 3 m 4 s")
  expect_equals_seconds 2 * 60 * 60 + 4 (parse "2 h 4 s")

  expect_parse_error ""
  expect_parse_error "0"
  expect_parse_error "0x"
  expect_parse_error "0s0"
  expect_parse_error "a"
  expect_parse_error "0a"
  expect_parse_error "0s0a"
  expect_parse_error "0s0m"
  expect_parse_error "0s0h"
  expect_parse_error "0m0h"
  expect_parse_error "0s0m0h"
  expect_parse_error "0s0s0s"
  expect_parse_error "0ss"
  expect_parse_error " "
  expect_parse_error " 0s "
  expect_parse_error " 2h4s "
  expect_parse_error " 2h3m4s "
