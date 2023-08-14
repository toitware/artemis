// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server-config as cli-server-config
import artemis.service
import artemis.shared.server-config show ServerConfig ServerConfigHttp
import artemis.cli.utils show read-json write-json-to-file write-blob-to-file
import encoding.json
import host.directory
import host.file
import host.os
import host.pipe
import uuid
import expect show *
import .artemis-server show TestArtemisServer
import .utils
import ..tools.service-image-uploader.uploader as uploader

main args/List:
  serial-port := os.env.get "ARTEMIS_TEST_SERIAL_PORT"
  if not serial-port:
    print "Missing ARTEMIS_TEST_SERIAL_PORT environment variable."
    exit 1
  wifi-ssid := os.env.get "ARTEMIS_TEST_WIFI_SSID"
  if not wifi-ssid:
    print "Missing ARTEMIS_TEST_WIFI_SSID environment variable."
    exit 1
  wifi-password := os.env.get "ARTEMIS_TEST_WIFI_PASSWORD"
  if not wifi-password:
    print "Missing ARTEMIS_TEST_WIFI_PASSWORD environment variable."
    exit 1

  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli serial-port wifi-ssid wifi-password



run-test test-cli/TestCli serial-port/string wifi-ssid/string wifi-password/string:
  tmp-dir := test-cli.tmp-dir
  ui := TestUi --no-quiet

  test-cli.replacements[serial-port] = "SERIAL-PORT"
  test-cli.replacements[wifi-ssid] = "WIFI-SSID"
  test-cli.replacements[wifi-password] = "WIFI-PASSWORD"
  test-cli.replacements[test-cli.sdk-version] = "SDK-VERSION"

  if test-cli.artemis.server-config is ServerConfigHttp:
    test-cli.run [
      "auth", "signup",
      "--email", ADMIN-EMAIL,
      "--password", ADMIN-PASSWORD
    ]

  test-cli.run [
    "auth", "login",
    "--email", ADMIN-EMAIL,
    "--password", ADMIN-PASSWORD
  ]

  service-version := "v0.0.$(random)-TEST"

  uploader.main
      --config=test-cli.config
      --cache=test-cli.cache
      --ui=ui
      [
        "service",
        "--sdk-version", test-cli.sdk-version,
        "--service-version", service-version,
        "--snapshot-directory", "$tmp-dir/snapshots",
        "--local",
      ]

  email := "test-$(%010d random)@example.com"
  password := "test-$(%010d random)"
  test-cli.replacements[email] = "USER@EMAIL"
  test-cli.replacements[password] = "USER-PASSWORD"

  test-cli.run-gold "BAA-signup"
      "Sign up for a new account."
      [
        "auth", "signup",
        "--email", email,
        "--password", password,
      ]

  test-cli.run-gold "BAK-login"
      "Log in to the newly created account."
      [
        "auth", "login",
        "--email", email,
        "--password", password,
      ]

  if test-cli.artemis.server-config != test-cli.broker.server-config:
    test-cli.run-gold "BBA-signup-broker"
        "Sign up for a new account."
        [
          "auth", "signup",
          "--broker",
          "--email", email,
          "--password", password,
        ]

    test-cli.run-gold "BBK-login-broker"
        "Log in to the newly created account in the broker."
        [
          "auth", "login",
          "--broker",
          "--email", email,
          "--password", password,
        ]

  // We might want to change this, but at the moment a new user does not have any
  // organizations.
  test-cli.run-gold "BCA-organizations"
      "List organizations directly aftern signup."
      [
        "org", "list",
      ]

  // Create a new organization.
  test-org-name := "Test organization $(%010d random)"
  REPLACEMENT-PREFIX := "ORGANIZATION_NAME"
  test-cli.replacements[test-org-name] = REPLACEMENT-PREFIX + " " * (test-org-name.size - REPLACEMENT-PREFIX.size)

  org-id/string? := null
  test-cli.run-gold "BCC-create-org"
      "Create an organization."
      --before-gold=: | output/string |
        // Something like "Created organization cce84fa4-b3cc-5ed8-a7cc-96b2d76bfd37 - foobar"
        space-index := 0
        2.repeat: space-index = output.index-of " " (space-index + 1)
        end-index := output.index-of " " (space-index + 1)
        org-id = output[space-index + 1 .. end-index]
        test-cli.replacements[org-id] = "-={| UUID-FOR-TEST-ORGANIZATION |}=-"
        output
      ["org", "create", test-org-name]

  test-cli.run-gold "BCD-organizations-after"
      "List organizations after creating a new one."
      [
        "org", "list",
      ]

  // Initialize a fleet.
  fleet-dir := "$tmp-dir/fleet"
  directory.mkdir --recursive fleet-dir
  test-cli.replacements[fleet-dir] = "FLEET-DIR"

  test-cli.run-gold "CAA-fleet-init"
      "Initialize a fleet."
      [
        "--fleet-root", fleet-dir,
        "fleet", "init",
      ]
  fleet-file := read-json "$fleet-dir/fleet.json"
  fleet-id := fleet-file["id"]
  test-cli.replacements[fleet-id] = "-={|       UUID-FOR-FLEET       |}=-"

  test-cli.run-gold "CAK-no-devices-yet"
      "List devices in the fleet."
      [
        "--fleet-root", fleet-dir,
        "fleet", "status",
      ]

  spec-path := "$fleet-dir/my-pod.json"
  test-cli.replacements["my-pod.json"] = "FLEET-POD-FILE"

  default-spec := read-json spec-path
  // Only replace the artemis version. Keep the rest as is.
  default-spec["artemis-version"] = service-version
  write-json-to-file --pretty spec-path default-spec


  print "Creating default firmware."
  // Create a firmware.
  // Just make sure that the example file works. We are not using that firmware otherwise.
  pod-file := "$tmp-dir/firmware.pod"
  test-cli.replacements[pod-file] = "FIRMWARE.POD"
  test-cli.run-gold "DAA-default-firmware"
      "Create the default firmware."
      [
        "--fleet-root", fleet-dir,
        "pod", "build",
        "-o", pod-file,
        spec-path,
      ]
  expect (file.is-file pod-file)

  add-replacements-for-pod := : | pod-json/Map |
    id := pod-json["id"]
    revision := pod-json["revision"]
    tags := pod-json["tags"]
    created-at := pod-json["created_at"]
    test-cli.replacements[id] = "-={|      UUID-FOR-MY-POD#$revision     |}=-"
    test-cli.replacements[created-at] = "CREATED-AT-FOR-MY-POD#$revision"
    tags.do:
      if it != "latest":
        test-cli.replacements[it] = "TAG-FOR-MY-POD#$revision"
    id

  add-replacements-for-last-pod := :
    available-pods := test-cli.run --json [
      "--fleet-root", fleet-dir,
      "pod", "list",
    ]
    add-replacements-for-pod.call available-pods[0]


  // Upload the firmware.
  test-cli.run-gold "DAB-upload-firmware"
      "Upload the firmware."
      --before-gold=:
        add-replacements-for-last-pod.call
        it
      [
        "--fleet-root", fleet-dir,
        "pod", "upload",
        pod-file,
      ]

  // Make our own specification.
  our-spec := read-json spec-path
  our-spec["max-offline"] = "10s"
  our-spec["artemis-version"] = service-version
  our-spec["connections"][0]["ssid"] = wifi-ssid
  our-spec["connections"][0]["password"] = wifi-password
  our-spec["containers"].remove "solar"
  write-json-to-file --pretty spec-path our-spec

  // Compile the specification.
  test-cli.run-gold "DAC-compile-modified-firmware"
      "Compile the modified specification."
      [
        "--fleet-root", fleet-dir,
        "pod", "build",
        "-o", pod-file,
        spec-path,
      ]

  // Upload the specification.
  test-cli.run-gold "DAD-upload-modified-pod"
      "Upload the modified pod."
      --before-gold=:
        add-replacements-for-last-pod.call
        it
      [
        "--fleet-root", fleet-dir,
        "pod", "upload", pod-file,
      ]

  available-pods := test-cli.run --json [
    "--fleet-root", fleet-dir,
    "pod", "list",
  ]
  flash-pod-id := available-pods[0]["id"]

  // List the available firmwares.
  test-cli.run-gold "DAE-list-firmwares"
      --ignore-spacing
      "List the available firmwares."
      [
        "--fleet-root", fleet-dir,
        "pod", "list"
      ]

  device-id/string? := null
  // Flash it.
  test-cli.run-gold "DAF-flash"
      "Flash the firmware to the device."
      --ignore-spacing
      --before-gold=: | output/string |
        provisioned-index := output.index-of "Successfully provisioned device"
        expect provisioned-index >= 0
        space-index := provisioned-index
        3.repeat: space-index = output.index-of " " (space-index + 1)
        expect space-index >= 0
        name-start-index := space-index + 1
        space-index = output.index-of " " (space-index + 1)
        name-end-index := space-index
        expect-equals '(' output[name-end-index + 1]
        device-start-index := name-end-index + 2
        device-end-index := output.index-of ")" device-start-index
        device-name := output[name-start-index..name-end-index]
        device-id = output[device-start-index..device-end-index]
        test-cli.replacements[device-name] = "DEVICE_NAME"
        test-cli.replacements[device-id] = "-={|    UUID-FOR-TEST-DEVICE    |}=-"
        output
      [
        "serial", "flash",
        "--fleet-root", fleet-dir,
        "--port", serial-port,
      ]

  test-device := test-cli.listen-to-serial-device
      --serial-port=serial-port
      --alias-id=uuid.parse device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=uuid.parse device-id

  test-device.wait-for "INFO: synchronized"

  with-timeout --ms=15_000:
    while true:
      // Wait for the device to come online.
      output := test-cli.run [
        "fleet", "status",
        "--fleet-root", fleet-dir,
      ]
      if output.contains device-id:
        break
      sleep --ms=100

  // Give the system time to recognize the check-in.
  sleep --ms=200

  // catch:
  //   with_timeout --ms=5_000:
  //     pipe.run_program "jag" "monitor"

  test-cli.run-gold "DAK-devices-after-flash"
      --ignore-spacing
      "List devices in the fleet."
      [
        "fleet", "status",
        "--fleet-root", fleet-dir,
      ]

  updated-spec := read-json spec-path
  // Unfortunately we can't go below 10 seconds as the device
  // prevents that. We could set it, but it wouldn't take effect.
  updated-spec["max-offline"] = "11s"
  write-json-to-file --pretty spec-path updated-spec

  test-cli.run-gold "DDA-device-show"
      "Show the device before update."
      --ignore-spacing
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          APP-ID-PREFIX ::= "      id: "
          if it.starts-with APP-ID-PREFIX:
            test-cli.replacements[it[APP-ID-PREFIX.size ..]] = "APP_ID"
        output
      [
        "device", "show",
        "-d", device-id,
        "--max-events", "0",
        "--fleet-root", fleet-dir,
      ]

  // Upload a new version.
  test-cli.run-gold "DDB-upload-new-firmware"
      "Upload a new version of the firmware."
      --before-gold=: | output/string |
        add-replacements-for-last-pod.call
        output
      [
        "--fleet-root", fleet-dir,
        "pod", "upload",
        spec-path,
      ]

  test-cli.run-gold "DDK-update-firmware"
      "Update the firmware."
      --ignore-spacing
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          UPLOADING-PREFIX ::= "Uploading patch "
          if it.starts-with UPLOADING-PREFIX:
            test-cli.replacements[it[UPLOADING-PREFIX.size ..]] = "PATCH-HASH-SIZE"
        output
      [
        "fleet", "roll-out",
        "--fleet-root", fleet-dir,
      ]

  print "Waiting for the device to apply the config."

  with-timeout --ms=60_000:
    while true:
      status-output := test-cli.run [
            "device", "show",
            "-d", device-id,
            "--max-events", "0",
            "--fleet-root", fleet-dir,
      ]
      if not status-output.contains flash-pod-id:
        break
      sleep --ms=1_000

  test-cli.run-gold "DEA-status"
      "List devices in the fleet after applied update."
      --ignore-spacing
      --before-gold=: | output/string |
        lines := output.split "\n"
        missed-index/int := -1
        fixed := []
        lines.do: | line/string |
          if missed-index < 0:
            missed-index = line.index-of "Missed"
            if missed-index < 0:
              continue.do

          // The update might have led to a missed checkin.
          // Remove the check-mark.
          // We use a string instead of a character, as the size of the cross is more
          // than one byte.
          CROSS ::= "✗"
          // Replacing the cross by using the index is a bit brittle.
          // Due to unicode characters before the cross, the index might not be the same.
          if line.size > missed-index and line[missed-index] == CROSS[0]:
            line = line[.. missed-index] + " " + line[missed-index + CROSS.size ..]
          fixed.add line
        fixed.join "\n"
      [
        "--fleet-root", fleet-dir,
        "fleet", "status",
      ]

  after-firmware/string? := null
  test-cli.run-gold "DEK-device-show"
      "Show the device after update."
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          FIRMWARE-PREFIX ::= "  firmware: "
          if it.starts-with FIRMWARE-PREFIX:
            after-firmware = it[FIRMWARE-PREFIX.size ..]
            test-cli.replacements[after-firmware] = "AFTER_FIRMWARE"
        output
      [
        "device", "show",
        "-d", device-id,
        "--max-events", "0",
        "--fleet-root", fleet-dir,
      ]

  hello-world := """
    main: print "hello world"
    """
  hello-world-path := "$fleet-dir/hello-world.toit"
  write-blob-to-file hello-world-path hello-world

  test-device.clear-output

  test-cli.run-gold "EAA-container-install"
      "Install a container"
      [
        "--fleet-root", fleet-dir,
        "device", "-d", device-id,
        "container", "install",
        "hello",
        hello-world-path,
      ]

  with-timeout --ms=25_000:
    test-device.wait-for "hello world"
