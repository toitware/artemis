// Copyright (C) 2022 Toitware ApS.

// TEST_FLAGS: --supabase-server|--http-broker --http-server|--http-broker --supabase-server|--supabase-broker --http-server|--supabase-broker
import .utils

main args:
  if args.is_empty: args = ["--http-server", "--http-broker"]

  artemis_type/string := ?
  if args.contains "--supabase-server":  artemis_type = "supabase"
  else if args.contains "--http-server": artemis_type = "http"
  else: throw "Unknown artemis type: $args[0]"

  broker_type/string := ?
  if args.contains "--supabase-broker":  broker_type = "supabase"
  else if args.contains "--http-broker": broker_type = "http"
  else: throw "Unknown broker type: $args[1]"

  with_test_cli
      --artemis_type=artemis_type
      --broker_type=broker_type: | test_cli/TestCli device/Device |
    test_cli.run [
      "auth", "broker", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "set-max-offline",
      "--device=$device.id", "3"
    ]

    with_timeout (Duration --s=10):
      counter := 0
      while true:
        if device.max_offline == (Duration --s=3): break
        sleep --ms=counter
        counter++
