// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig ServerConfigHttp
import artemis.cli.utils show read_json write_json_to_file write_blob_to_file
import encoding.json
import host.directory
import host.file
import host.os
import host.pipe
import uuid
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

  if test_cli.artemis.server_config is ServerConfigHttp:
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
        "--fleet-root", fleet_dir,
        "fleet", "init",
      ]
  fleet_file := read_json "$fleet_dir/fleet.json"
  fleet_id := fleet_file["id"]
  test_cli.replacements[fleet_id] = "-={|       UUID-FOR-FLEET       |}=-"

  test_cli.run_gold "CAK-no-devices-yet"
      "List devices in the fleet."
      [
        "--fleet-root", fleet_dir,
        "fleet", "status",
      ]

  spec_path := "$fleet_dir/my-pod.json"
  test_cli.replacements["my-pod.json"] = "FLEET-POD-FILE"

  default_spec := read_json spec_path
  // Only replace the artemis version. Keep the rest as is.
  default_spec["artemis-version"] = service_version
  write_json_to_file --pretty spec_path default_spec


  print "Creating default firmware."
  // Create a firmware.
  // Just make sure that the example file works. We are not using that firmware otherwise.
  pod_file := "$tmp_dir/firmware.pod"
  test_cli.replacements[pod_file] = "FIRMWARE.POD"
  test_cli.run_gold "DAA-default-firmware"
      "Create the default firmware."
      [
        "--fleet-root", fleet_dir,
        "pod", "build",
        "-o", pod_file,
        spec_path,
      ]
  expect (file.is_file pod_file)

  add_replacements_for_pod := : | pod_json/Map |
    id := pod_json["id"]
    revision := pod_json["revision"]
    tags := pod_json["tags"]
    created_at := pod_json["created_at"]
    test_cli.replacements[id] = "-={|      UUID-FOR-MY-POD#$revision     |}=-"
    test_cli.replacements[created_at] = "CREATED-AT-FOR-MY-POD#$revision"
    tags.do:
      if it != "latest":
        test_cli.replacements[it] = "TAG-FOR-MY-POD#$revision"
    id

  add_replacements_for_last_pod := :
    available_pods := test_cli.run --json [
      "--fleet-root", fleet_dir,
      "pod", "list",
    ]
    add_replacements_for_pod.call available_pods[0]


  // Upload the firmware.
  test_cli.run_gold "DAB-upload-firmware"
      "Upload the firmware."
      --before_gold=:
        add_replacements_for_last_pod.call
        it
      [
        "--fleet-root", fleet_dir,
        "pod", "upload",
        pod_file,
      ]

  // Make our own specification.
  our_spec := read_json spec_path
  our_spec["max-offline"] = "10s"
  our_spec["artemis-version"] = service_version
  our_spec["connections"][0]["ssid"] = wifi_ssid
  our_spec["connections"][0]["password"] = wifi_password
  our_spec["containers"].remove "solar"
  write_json_to_file --pretty spec_path our_spec

  // Compile the specification.
  test_cli.run_gold "DAC-compile-modified-firmware"
      "Compile the modified specification."
      [
        "--fleet-root", fleet_dir,
        "pod", "build",
        "-o", pod_file,
        spec_path,
      ]

  // Upload the specification.
  test_cli.run_gold "DAD-upload-modified-pod"
      "Upload the modified pod."
      --before_gold=:
        add_replacements_for_last_pod.call
        it
      [
        "--fleet-root", fleet_dir,
        "pod", "upload", pod_file,
      ]

  available_pods := test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list",
  ]
  flash_pod_id := available_pods[0]["id"]

  // List the available firmwares.
  test_cli.run_gold "DAE-list-firmwares"
      --ignore_spacing
      "List the available firmwares."
      [
        "--fleet-root", fleet_dir,
        "pod", "list"
      ]

  device_id/string? := null
  // Flash it.
  test_cli.run_gold "DAF-flash"
      "Flash the firmware to the device."
      --ignore_spacing
      --before_gold=: | output/string |
        provisioned_index := output.index_of "Successfully provisioned device"
        expect provisioned_index >= 0
        space_index := provisioned_index
        3.repeat: space_index = output.index_of " " (space_index + 1)
        expect space_index >= 0
        name_start_index := space_index + 1
        space_index = output.index_of " " (space_index + 1)
        name_end_index := space_index
        expect_equals '(' output[name_end_index + 1]
        device_start_index := name_end_index + 2
        device_end_index := output.index_of ")" device_start_index
        device_name := output[name_start_index..name_end_index]
        device_id = output[device_start_index..device_end_index]
        test_cli.replacements[device_name] = "DEVICE_NAME"
        test_cli.replacements[device_id] = "-={|    UUID-FOR-TEST-DEVICE    |}=-"
        output
      [
        "serial", "flash",
        "--fleet-root", fleet_dir,
        "--port", serial_port,
      ]

  test_device := test_cli.listen_to_serial_device
      --serial_port=serial_port
      --alias_id=uuid.parse device_id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware_id=uuid.parse device_id

  test_device.wait_for "INFO: synchronized"

  with_timeout --ms=15_000:
    while true:
      // Wait for the device to come online.
      output := test_cli.run [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]
      if output.contains device_id:
        break
      sleep --ms=100

  // Give the system time to recognize the check-in.
  sleep --ms=200

  // catch:
  //   with_timeout --ms=5_000:
  //     pipe.run_program "jag" "monitor"

  test_cli.run_gold "DAK-devices-after-flash"
      --ignore_spacing
      "List devices in the fleet."
      [
        "fleet", "status",
        "--fleet-root", fleet_dir,
      ]

  updated_spec := read_json spec_path
  // Unfortunately we can't go below 10 seconds as the device
  // prevents that. We could set it, but it wouldn't take effect.
  updated_spec["max-offline"] = "11s"
  write_json_to_file --pretty spec_path updated_spec

  test_cli.run_gold "DDA-device-show"
      "Show the device before update."
      --ignore_spacing
      --before_gold=: | output/string |
        lines := output.split "\n"
        lines.do:
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

  // Upload a new version.
  test_cli.run_gold "DDB-upload-new-firmware"
      "Upload a new version of the firmware."
      --before_gold=: | output/string |
        add_replacements_for_last_pod.call
        output
      [
        "--fleet-root", fleet_dir,
        "pod", "upload",
        spec_path,
      ]

  test_cli.run_gold "DDK-update-firmware"
      "Update the firmware."
      --ignore_spacing
      --before_gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          UPLOADING_PREFIX ::= "Uploading patch "
          if it.starts_with UPLOADING_PREFIX:
            test_cli.replacements[it[UPLOADING_PREFIX.size ..]] = "PATCH-HASH-SIZE"
        output
      [
        "fleet", "roll-out",
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
      if not status_output.contains flash_pod_id:
        break
      sleep --ms=1_000

  test_cli.run_gold "DEA-status"
      "List devices in the fleet after applied update."
      --ignore_spacing
      --before_gold=: | output/string |
        lines := output.split "\n"
        missed_index/int := -1
        fixed := []
        lines.do: | line/string |
          if missed_index < 0:
            missed_index = line.index_of "Missed"
            if missed_index < 0:
              continue.do

          // The update might have led to a missed checkin.
          // Remove the check-mark.
          // We use a string instead of a character, as the size of the cross is more
          // than one byte.
          CROSS ::= "✗"
          // Replacing the cross by using the index is a bit brittle.
          // Due to unicode characters before the cross, the index might not be the same.
          if line.size > missed_index and line[missed_index] == CROSS[0]:
            line = line[.. missed_index] + " " + line[missed_index + CROSS.size ..]
          fixed.add line
        fixed.join "\n"
      [
        "--fleet-root", fleet_dir,
        "fleet", "status",
      ]

  after_firmware/string? := null
  test_cli.run_gold "DEK-device-show"
      "Show the device after update."
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

  hello_world := """
    main: print "hello world"
    """
  hello_world_path := "$fleet_dir/hello-world.toit"
  write_blob_to_file hello_world_path hello_world

  test_device.clear_output

  test_cli.run_gold "EAA-container-install"
      "Install a container"
      [
        "--fleet-root", fleet_dir,
        "device", "-d", device_id,
        "container", "install",
        "hello",
        hello_world_path,
      ]

  with_timeout --ms=25_000:
    test_device.wait_for "hello world"
