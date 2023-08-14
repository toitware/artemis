// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.utils show parse-duration

parse str/string -> Duration:
  return parse-duration str --on-error=: throw "Illegal"

expect-parse-error str/string:
  parse-duration str --on-error=: return
  throw "Expected parse error"

expect-equals-seconds s/int duration/Duration:
  expect-equals s duration.in-s

main:
  expect-equals-seconds 0 (parse "0s")
  expect-equals-seconds 0 (parse "0m")
  expect-equals-seconds 0 (parse "0h")
  expect-equals-seconds 0 (parse "0h0m0s")

  expect-equals-seconds 5 (parse "5s")
  expect-equals-seconds 5 * 60 (parse "5m")
  expect-equals-seconds 5 * 60 * 60 (parse "5h")
  expect-equals-seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2h3m4s")
  expect-equals-seconds 2 * 60 * 60 + 3 * 60 (parse "2h3m")
  expect-equals-seconds 2 * 60 * 60 + 4 (parse "2h4s")

  expect-equals-seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2h 3m 4s")
  expect-equals-seconds 2 * 60 * 60 + 4 (parse "2h 4s")

  expect-equals-seconds 2 * 60 * 60 + 3 * 60 + 4 (parse "2 h 3 m 4 s")
  expect-equals-seconds 2 * 60 * 60 + 4 (parse "2 h 4 s")

  expect-parse-error ""
  expect-parse-error "0"
  expect-parse-error "0x"
  expect-parse-error "0s0"
  expect-parse-error "a"
  expect-parse-error "0a"
  expect-parse-error "0s0a"
  expect-parse-error "0s0m"
  expect-parse-error "0s0h"
  expect-parse-error "0m0h"
  expect-parse-error "0s0m0h"
  expect-parse-error "0s0s0s"
  expect-parse-error "0ss"
  expect-parse-error " "
  expect-parse-error " 0s "
  expect-parse-error " 2h4s "
  expect-parse-error " 2h3m4s "
