// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig ServerConfigHttpToit
import artemis.cli.utils show read_json write_json_to_file
import host.directory
import host.file
import host.os
import host.pipe
import expect show *
import .artemis_server show TestArtemisServer
import .utils
import ..tools.service_image_uploader.uploader as uploader

main args/List:
  serial_port := os.env.get "ARTEMIS_TEST_SERIAL_PORT"
  if not serial_port:
    print "Missing ARTEMIS_TEST_SERIAL_PORT environment variable."
    exit 1
  wifi_ssid := os.env.get "ARTEMIS_TEST_WIFI_SSID"
  if not wifi_ssid:
    print "Missing ARTEMIS_TEST_WIFI_SSID environment variable."
    exit 1
  wifi_password := os.env.get "ARTEMIS_TEST_WIFI_PASSWORD"
  if not wifi_password:
    print "Missing ARTEMIS_TEST_WIFI_PASSWORD environment variable."
    exit 1

  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli serial_port wifi_ssid wifi_password

run_test test_cli/TestCli serial_port/string wifi_ssid/string wifi_password/string:
  tmp_dir := test_cli.tmp_dir
  ui := TestUi --no-quiet

  test_cli.replacements[serial_port] = "SERIAL-PORT"
  test_cli.replacements[wifi_ssid] = "WIFI-SSID"
  test_cli.replacements[wifi_password] = "WIFI-PASSWORD"
  test_cli.replacements[test_cli.sdk_version] = "SDK-VERSION"

  if test_cli.artemis.server_config is ServerConfigHttpToit:
    test_cli.run [
      "auth", "signup",
      "--email", ADMIN_EMAIL,
      "--password", ADMIN_PASSWORD
    ]

  test_cli.run [
    "auth", "login",
    "--email", ADMIN_EMAIL,
    "--password", ADMIN_PASSWORD
  ]

  service_version := "v0.0.$(random)-TEST"

  uploader.main
      --config=test_cli.config
      --cache=test_cli.cache
      --ui=ui
      [
        "service",
        "--sdk-version", test_cli.sdk_version,
        "--service-version", service_version,
        "--snapshot-directory", "$tmp_dir/snapshots",
        "--local",
      ]

  email := "test-$(%010d random)@example.com"
  password := "test-$(%010d random)"
  test_cli.replacements[email] = "USER@EMAIL"
  test_cli.replacements[password] = "USER-PASSWORD"

  test_cli.run_gold "BAA-signup"
      "Sign up for a new account."
      [
        "auth", "signup",
        "--email", email,
        "--password", password,
      ]

  test_cli.run_gold "BAK-login"
      "Log in to the newly created account."
      [
        "auth", "login",
        "--email", email,
        "--password", password,
      ]

  if test_cli.artemis.server_config != test_cli.broker.server_config:
    test_cli.run_gold "BBA-signup-broker"
        "Sign up for a new account."
        [
          "auth", "signup",
          "--broker",
          "--email", email,
          "--password", password,
        ]

    test_cli.run_gold "BBK-login-broker"
        "Log in to the newly created account in the broker."
        [
          "auth", "login",
          "--broker",
          "--email", email,
          "--password", password,
        ]

  // We might want to change this, but at the moment a new user does not have any
  // organizations.
  test_cli.run_gold "BCA-organizations"
      "List organizations directly aftern signup."
      [
        "org", "list",
      ]

  // Create a new organization.
  test_org_name := "Test organization $(%010d random)"
  REPLACEMENT_PREFIX := "ORGANIZATION_NAME"
  test_cli.replacements[test_org_name] = REPLACEMENT_PREFIX + " " * (test_org_name.size - REPLACEMENT_PREFIX.size)

  org_id/string? := null
  test_cli.run_gold "BCC-create-org"
      "Create an organization."
      --before_gold=: | output/string |
        // Something like "Created organization cce84fa4-b3cc-5ed8-a7cc-96b2d76bfd37 - foobar"
        space_index := 0
        2.repeat: space_index = output.index_of " " (space_index + 1)
        end_index := output.index_of " " (space_index + 1)
        org_id = output[space_index + 1 .. end_index]
        test_cli.replacements[org_id] = "-={| UUID-FOR-TEST-ORGANIZATION |}=-"
        output
      ["org", "create", test_org_name]

  test_cli.run_gold "BCD-organizations-after"
      "List organizations after creating a new one."
      [
        "org", "list",
      ]

  // Initialize a fleet.
  fleet_dir := "$tmp_dir/fleet"
  directory.mkdir --recursive fleet_dir
  test_cli.replacements[fleet_dir] = "FLEET-DIR"

  test_cli.run_gold "CAA-fleet-init"
      "Initialize a fleet."
      [
        "fleet", "init",
        "--fleet-root", fleet_dir,
      ]

  test_cli.run_gold "CAK-no-devices-yet"
      "List devices in the fleet."
      [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]

  default_spec := read_json "$fleet_dir/specification.json"
  // Only replace the artemis version. Keep the rest as is.
  default_spec["artemis-version"] = service_version
  write_json_to_file --pretty "$fleet_dir/specification.json" default_spec

  print "Creating default firmware."
  // Create a firmware.
  // Just make sure that the example file works. We are not using that firmware otherwise.
  pod_file := "$tmp_dir/firmware.pod"
  test_cli.replacements[pod_file] = "FIRMWARE.POD"
  test_cli.run_gold "DAA-default-firmware"
      "Create the default firmware."
      [
        "pod", "build",
        "--specification", "$fleet_dir/specification.json",
        "-o", pod_file,
        "--fleet-root", fleet_dir,
      ]
  expect (file.is_file pod_file)

  // Make our own specification.
  our_spec := read_json "$fleet_dir/specification.json"
  our_spec["max-offline"] = "10s"
  our_spec["artemis-version"] = service_version
  our_spec["connections"][0]["ssid"] = wifi_ssid
  our_spec["connections"][0]["password"] = wifi_password
  our_spec["containers"].remove "solar"
  write_json_to_file --pretty "$fleet_dir/specification.json" our_spec

  device_id/string? := null
  // Flash it.
  test_cli.run_gold "DAB-flash"
      "Flash the firmware to the device."
      --before_gold=: | output/string |
        provisioned_index := output.index_of "Successfully provisioned device"
        expect provisioned_index >= 0
        space_index := provisioned_index
        3.repeat: space_index = output.index_of " " (space_index + 1)
        expect space_index >= 0
        dot_index := output.index_of "." (space_index + 1)
        device_id = output[space_index + 1 .. dot_index]
        test_cli.replacements[device_id] = "-={|    UUID-FOR-TEST-DEVICE    |}=-"
        output
      [
        "serial", "flash",
        "--fleet-root", fleet_dir,
        "--port", serial_port,
      ]

  print "Successfully flashed."

  with_timeout --ms=15_000:
    while true:
      // Wait for the device to come online.
      output := test_cli.run [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]
      if output.contains device_id:
        break
      sleep --ms=500

  // Give the system time to recognize the check-in.
  sleep --ms=200

  // catch:
  //   with_timeout --ms=5_000:
  //     pipe.run_program "jag" "monitor"

  test_cli.run_gold "DAK-devices-after-flash"
      "List devices in the fleet."
      [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]

  updated_spec := read_json "$fleet_dir/specification.json"
  updated_spec["max-offline"] = "11s"
  write_json_to_file --pretty "$fleet_dir/specification.json" updated_spec

  initial_firmware/string? := null
  test_cli.run_gold "DDA-device-show"
      "Show the device before update."
      --before_gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          FIRMWARE_PREFIX ::= "  firmware: "
          if it.starts_with FIRMWARE_PREFIX:
            initial_firmware = it[FIRMWARE_PREFIX.size ..]
            test_cli.replacements[initial_firmware] = "INITIAL_FIRMWARE"
          APP_ID_PREFIX ::= "      id: "
          if it.starts_with APP_ID_PREFIX:
            test_cli.replacements[it[APP_ID_PREFIX.size ..]] = "APP_ID"
        output
      [
        "device", "show",
        "-d", device_id,
        "--max-events", "0",
        "--fleet-root", fleet_dir,
      ]

  test_cli.run_gold "DDK-update-firmware"
      "Update the firmware."
      --before_gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          UPLOADING_PREFIX ::= "Uploading patch "
          if it.starts_with UPLOADING_PREFIX:
            test_cli.replacements[it[UPLOADING_PREFIX.size ..]] = "PATCH-HASH-SIZE"
        output
      [
        "fleet", "update",
        "--fleet-root", fleet_dir,
      ]

  print "Waiting for the device to apply the config."

  with_timeout --ms=60_000:
    while true:
      status_output := test_cli.run [
            "device", "show",
            "-d", device_id,
            "--max-events", "0",
            "--fleet-root", fleet_dir,
      ]
      if not status_output.contains initial_firmware:
        break
      sleep --ms=1_000

  test_cli.run_gold "DEA-status"
      "List devices in the fleet after applied update."
      --before_gold=: | output/string |
        lines := output.split "\n"
        missed_index/int? := null
        fixed := []
        lines.do: | line/string |
          missed_index_tmp := line.index_of "Missed"
          if missed_index_tmp >= 0:
            missed_index = missed_index_tmp

          // The update might have led to a missed checkin.
          // Remove the check-mark.
          CROSS ::= "✗"
          cross_index := line.index_of CROSS
          if cross_index == missed_index:
            line = line[.. cross_index] + " " + line[cross_index + CROSS.size ..]
          fixed.add line
        fixed.join "\n"
      [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]

  after_firmware/string? := null
  test_cli.run_gold "BEK-device-show"
      "Show the device before update."
      --before_gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          FIRMWARE_PREFIX ::= "  firmware: "
          if it.starts_with FIRMWARE_PREFIX:
            after_firmware = it[FIRMWARE_PREFIX.size ..]
            test_cli.replacements[after_firmware] = "AFTER_FIRMWARE"
        output
      [
        "device", "show",
        "-d", device_id,
        "--max-events", "0",
        "--fleet-root", fleet_dir,
      ]
