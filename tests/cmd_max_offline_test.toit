// Copyright (C) 2022 Toitware ApS.

// TEST_FLAGS: --supabase-server --http-server
import .utils

main args:
  if args.is_empty: args = ["--http-server"]

  artemis_type/string := ?
  if args[0] == "--supabase-server":  artemis_type = "supabase"
  else if args[0] == "--http-server": artemis_type = "http"
  else: throw "Unknown artemis type: $args[0]"

  with_test_cli --artemis_type=artemis_type: | test_cli/TestCli device/Device |
    test_cli.run [
      "set-max-offline",
      "--device=$device.id", "3"
    ]

    with_timeout --ms=2_000:
      counter := 0
      while true:
        if device.max_offline == (Duration --s=3): break
        sleep --ms=counter
        counter++
