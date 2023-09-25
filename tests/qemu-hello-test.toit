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

HELLO-WORLD-CODE ::= """
main: print "hello world"
"""

ETHERNET-PROVIDER-CODE ::= """
import esp32.net.ethernet as esp32

main:
  provider := esp32.EthernetServiceProvider.mac-openeth
      --phy-chip=esp32.PHY-CHIP-DP83848
  provider.install
"""


main args/List:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
  tmp-dir := test-cli.tmp-dir
  ui := TestUi --no-quiet

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

  test-cli.run [
    "auth", "login",
    "--email", TEST-EXAMPLE-COM-EMAIL,
    "--password", TEST-EXAMPLE-COM-PASSWORD,
  ]

  if test-cli.artemis.server-config != test-cli.broker.server-config:
    test-cli.run [
      "auth", "login",
      "--broker",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

  org-id := TEST-ORGANIZATION-UUID

  // Initialize a fleet.
  fleet-dir := "$tmp-dir/fleet"
  directory.mkdir --recursive fleet-dir
  test-cli.replacements[fleet-dir] = "FLEET-DIR"

  test-cli.run [
    "--fleet-root", fleet-dir,
    "fleet", "init",
    "--organization-id", "$org-id",
  ]
  fleet-file := read-json "$fleet-dir/fleet.json"
  fleet-id := fleet-file["id"]

  spec-path := "$fleet-dir/my-pod.json"

  default-spec := read-json spec-path
  // Only replace the artemis version. Keep the rest as is.
  default-spec["artemis-version"] = service-version
  write-json-to-file --pretty spec-path default-spec

  hello-world-path := "$fleet-dir/hello-world.toit"
  write-blob-to-file hello-world-path HELLO-WORLD-CODE

  eth-provider-path := "$fleet-dir/eth-provider.toit"
  write-blob-to-file eth-provider-path ETHERNET-PROVIDER-CODE

  print "Creating QEMU firmware."
  pod-file := "$tmp-dir/firmware.pod"
  qemu-spec := read-json spec-path
  qemu-spec["firmware-envelope"] = "esp32-qemu"
  qemu-spec["connections"] = [
    {
      "type": "ethernet",
      "requires": ["eth-qemu"],
    }
  ]
  qemu-spec["containers"] = {
    "hello": {
      "entrypoint": hello-world-path,
    },
    "eth-qemu": {
      "entrypoint": eth-provider-path,
      "background": true,
    },
  }
  write-json-to-file --pretty spec-path qemu-spec

  test-cli.run [
    "--fleet-root", fleet-dir,
    "pod", "build",
    "-o", pod-file,
    spec-path,
  ]
  expect (file.is-file pod-file)

  // Upload the firmware.
  test-cli.run [
    "--fleet-root", fleet-dir,
    "pod", "upload",
    pod-file,
  ]

  available-pods := test-cli.run --json [
    "--fleet-root", fleet-dir,
    "pod", "list",
  ]
  flash-pod-id := available-pods[0]["id"]

  image-path := "$tmp-dir/qemu.img"
  // Generate qemu image.
  test-cli.run [
    "serial", "flash",
    "--fleet-root", fleet-dir,
    "--port", "xxx",
    "--qemu-image", image-path,
  ]

  status := test-cli.run --json [
    "--fleet-root", fleet-dir,
    "fleet", "status",
    "--include-never-seen"
  ]

  expect-equals 1 status.size
  device-id/string? := status[0]["device-id"]

  test-device := test-cli.start-device
      --alias-id=uuid.parse device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=uuid.parse device-id
      --qemu-image=image-path

  test-device.wait-for "hello world"
  test-device.wait-for "INFO: synchronized"
