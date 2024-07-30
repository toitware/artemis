// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server-config as cli-server-config
import artemis.service
import artemis.shared.server-config show ServerConfig ServerConfigHttp
import artemis.cli.utils show read-json read-yaml write-yaml-to-file write-blob-to-file
import cli show Cli
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

  with-tester --args=args: | tester/Tester |
    run-test tester serial-port wifi-ssid wifi-password

run-test tester/Tester serial-port/string wifi-ssid/string wifi-password/string:
  tmp-dir := tester.tmp-dir
  ui := TestUi --no-quiet

  tester.replacements[serial-port] = "SERIAL-PORT"
  tester.replacements[wifi-ssid] = "WIFI-SSID"
  tester.replacements[wifi-password] = "WIFI-PASSWORD"
  tester.replacements[tester.sdk-version] = "SDK-VERSION"

  if tester.artemis.server-config is ServerConfigHttp:
    tester.run [
      "auth", "signup",
      "--email", ADMIN-EMAIL,
      "--password", ADMIN-PASSWORD
    ]

  tester.run [
    "auth", "login",
    "--email", ADMIN-EMAIL,
    "--password", ADMIN-PASSWORD
  ]

  service-version := "v0.0.$(random)-TEST"

  cli := tester.cli.with --ui=ui
  uploader.main
      --cli=cli
      [
        "service",
        "--sdk-version", tester.sdk-version,
        "--service-version", service-version,
        "--snapshot-directory", "$tmp-dir/snapshots",
        "--local",
      ]

  email := "test-$(%010d random)@example.com"
  password := "test-$(%010d random)"
  tester.replacements[email] = "USER@EMAIL"
  tester.replacements[password] = "USER-PASSWORD"

  tester.run-gold "BAA-signup"
      "Sign up for a new account."
      [
        "auth", "signup",
        "--email", email,
        "--password", password,
      ]

  tester.run-gold "BAK-login"
      "Log in to the newly created account."
      [
        "auth", "login",
        "--email", email,
        "--password", password,
      ]

  if tester.artemis.server-config != tester.broker.server-config:
    tester.run-gold "BBA-signup-broker"
        "Sign up for a new account."
        [
          "auth", "signup",
          "--broker",
          "--email", email,
          "--password", password,
        ]

    tester.run-gold "BBK-login-broker"
        "Log in to the newly created account in the broker."
        [
          "auth", "login",
          "--broker",
          "--email", email,
          "--password", password,
        ]

  // We might want to change this, but at the moment a new user does not have any
  // organizations.
  tester.run-gold "BCA-organizations"
      "List organizations directly aftern signup."
      [
        "org", "list",
      ]

  // Create a new organization.
  test-org-name := "Test organization $(%010d random)"
  REPLACEMENT-PREFIX := "ORGANIZATION_NAME"
  tester.replacements[test-org-name] = REPLACEMENT-PREFIX + " " * (test-org-name.size - REPLACEMENT-PREFIX.size)

  org-id/string? := null
  tester.run-gold "BCC-create-org"
      "Create an organization."
      --before-gold=: | output/string |
        // Something like "Added organization cce84fa4-b3cc-5ed8-a7cc-96b2d76bfd37 - foobar"
        space-index := 0
        2.repeat: space-index = output.index-of " " (space-index + 1)
        end-index := output.index-of " " (space-index + 1)
        org-id = output[space-index + 1 .. end-index]
        tester.replacements[org-id] = "-={| UUID-FOR-TEST-ORGANIZATION |}=-"
        output
      ["org", "add", test-org-name]

  tester.run-gold "BCD-organizations-after"
      "List organizations after creating a new one."
      [
        "org", "list",
      ]

  // Initialize a fleet.
  fleet-dir := "$tmp-dir/fleet"
  directory.mkdir --recursive fleet-dir
  tester.replacements[fleet-dir] = "FLEET-DIR"

  tester.run-gold "CAA-fleet-init"
      "Initialize a fleet."
      [
        "--fleet-root", fleet-dir,
        "fleet", "init",
      ]
  fleet-file := read-json "$fleet-dir/fleet.json"
  fleet-id := fleet-file["id"]
  tester.replacements[fleet-id] = "-={|       UUID-FOR-FLEET       |}=-"

  tester.run-gold "CAK-no-devices-yet"
      "List devices in the fleet."
      [
        "--fleet-root", fleet-dir,
        "fleet", "status",
      ]

  spec-path := "$fleet-dir/my-pod.yaml"
  tester.replacements["my-pod.yaml"] = "FLEET-POD-FILE"

  default-spec := read-yaml spec-path
  // Only replace the artemis version. Keep the rest as is.
  default-spec["artemis-version"] = service-version
  write-yaml-to-file spec-path default-spec


  print "Creating default firmware."
  // Create a firmware.
  // Just make sure that the example file works. We are not using that firmware otherwise.
  pod-file := "$tmp-dir/firmware.pod"
  tester.replacements[pod-file] = "FIRMWARE.POD"
  tester.run-gold "DAA-default-firmware"
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
    tester.replacements[id] = "-={|      UUID-FOR-MY-POD#$revision     |}=-"
    tester.replacements[created-at] = "CREATED-AT-FOR-MY-POD#$revision"
    tags.do:
      if it != "latest":
        tester.replacements[it] = "TAG-FOR-MY-POD#$revision"
    id

  add-replacements-for-last-pod := :
    available-pods := tester.run --json [
      "--fleet-root", fleet-dir,
      "pod", "list",
    ]
    add-replacements-for-pod.call available-pods[0]


  // Upload the firmware.
  tester.run-gold "DAB-upload-firmware"
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
  our-spec := read-yaml spec-path
  our-spec["max-offline"] = "10s"
  our-spec["artemis-version"] = service-version
  our-spec["connections"][0]["ssid"] = wifi-ssid
  our-spec["connections"][0]["password"] = wifi-password
  our-spec["containers"].remove "solar"
  write-yaml-to-file spec-path our-spec

  // Compile the specification.
  tester.run-gold "DAC-compile-modified-firmware"
      "Compile the modified specification."
      [
        "--fleet-root", fleet-dir,
        "pod", "build",
        "-o", pod-file,
        spec-path,
      ]

  // Upload the specification.
  tester.run-gold "DAD-upload-modified-pod"
      "Upload the modified pod."
      --before-gold=:
        add-replacements-for-last-pod.call
        it
      [
        "--fleet-root", fleet-dir,
        "pod", "upload", pod-file,
      ]

  available-pods := tester.run --json [
    "--fleet-root", fleet-dir,
    "pod", "list",
  ]
  flash-pod-id := available-pods[0]["id"]

  // List the available firmwares.
  tester.run-gold "DAE-list-firmwares"
      --ignore-spacing
      "List the available firmwares."
      [
        "--fleet-root", fleet-dir,
        "pod", "list"
      ]

  device-id/string? := null
  FLASH-DEVICE-NAME ::= "test-device"
  // Flash it.
  tester.run-gold "DAF-flash"
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
        expect-equals FLASH-DEVICE-NAME device-name
        device-id = output[device-start-index..device-end-index]
        tester.replacements[device-name] = "DEVICE_NAME"
        tester.replacements[device-id] = "-={|    UUID-FOR-TEST-DEVICE    |}=-"
        output
      [
        "serial", "flash",
        "--name", FLASH-DEVICE-NAME,
        "--fleet-root", fleet-dir,
        "--port", serial-port,
      ]

  test-device := tester.listen-to-serial-device
      --serial-port=serial-port
      --alias-id=uuid.parse device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=uuid.parse device-id

  pos := test-device.wait-for-synchronized --start-at=0

  with-timeout --ms=15_000:
    while true:
      // Wait for the device to come online.
      output := tester.run [
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

  tester.run-gold "DAK-devices-after-flash"
      --ignore-spacing
      "List devices in the fleet."
      [
        "fleet", "status",
        "--fleet-root", fleet-dir,
      ]

  updated-spec := read-yaml spec-path
  // Unfortunately we can't go below 10 seconds as the device
  // prevents that. We could set it, but it wouldn't take effect.
  updated-spec["max-offline"] = "11s"
  write-yaml-to-file spec-path updated-spec

  tester.run-gold "DDA-device-show"
      "Show the device before update."
      --ignore-spacing
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          APP-ID-PREFIX ::= "      id: "
          if it.starts-with APP-ID-PREFIX:
            tester.replacements[it[APP-ID-PREFIX.size ..]] = "APP_ID"
        output
      [
        "device", "show",
        "-d", device-id,
        "--max-events", "0",
        "--fleet-root", fleet-dir,
      ]

  // Upload a new version.
  tester.run-gold "DDB-upload-new-firmware"
      "Upload a new version of the firmware."
      --before-gold=: | output/string |
        add-replacements-for-last-pod.call
        output
      [
        "--fleet-root", fleet-dir,
        "pod", "upload",
        spec-path,
      ]

  tester.run-gold "DDK-update-firmware"
      "Update the firmware."
      --ignore-spacing
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          UPLOADING-PREFIX ::= "Uploading patch "
          if it.starts-with UPLOADING-PREFIX:
            tester.replacements[it[UPLOADING-PREFIX.size ..]] = "PATCH-HASH-SIZE"
        output
      [
        "fleet", "roll-out",
        "--fleet-root", fleet-dir,
      ]

  print "Waiting for the device to apply the config."

  with-timeout --ms=120_000:
    while true:
      status-output := tester.run [
            "device", "show",
            "-d", device-id,
            "--max-events", "0",
            "--fleet-root", fleet-dir,
      ]
      if not status-output.contains flash-pod-id:
        break
      sleep --ms=1_000

  tester.run-gold "DEA-status"
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
          // We use a string instead of a character, as the size of the cross could be
          // more than one byte if we use Unicode.
          CROSS ::= "x"
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
  tester.run-gold "DEK-device-show"
      "Show the device after update."
      --before-gold=: | output/string |
        lines := output.split "\n"
        lines.do:
          FIRMWARE-PREFIX ::= "  firmware: "
          if it.starts-with FIRMWARE-PREFIX:
            after-firmware = it[FIRMWARE-PREFIX.size ..]
            tester.replacements[after-firmware] = "AFTER_FIRMWARE"
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

  tester.run-gold "EAA-container-install"
      "Install a container"
      [
        "--fleet-root", fleet-dir,
        "device", "-d", device-id,
        "container", "install",
        "hello",
        hello-world-path,
      ]

  with-timeout --ms=35_000:
    test-device.wait-for "hello world" --start-at=pos
