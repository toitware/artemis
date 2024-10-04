// Copyright (C) 2023 Toitware ApS.

import host.directory
import host.file
import uuid show Uuid
import artemis.cli.utils show read-json write-json-to-file write-blob-to-file copy-directory

import .utils

flash-serial -> Uuid
    --fleet/TestFleet
    --port/string
    --files/Map
    --wifi-ssid/string?=null
    --wifi-password/string?=null
    --pod-spec/Map?=null
    --pod-spec-filename/string="my-pod.json"
    --tmp-dir/string="$fleet.tester.tmp-dir/serial":

  fleet-dir := fleet.fleet-dir
  fleet.tester.ensure-available-artemis-service

  directory.mkdir --recursive tmp-dir
  files.do: | filename/string blob |
    write-blob-to-file "$tmp-dir/$filename" blob

  write-lock-file --target-dir=tmp-dir --tests-dir=directory.cwd

  if not pod-spec:
    pod-spec = {:}

  if not pod-spec.contains "connections":
    if not wifi-ssid or not wifi-password:
      throw "wifi-ssid and wifi-password must be specified if pod-spec doesn't have a connections entry"
    pod-spec["connections"] = [
      {
        "type": "wifi",
        "ssid": wifi-ssid,
        "password": wifi-password,
      },
    ]

  if not pod-spec.contains "containers":
    containers := {:}
    files.do: | filename/string _ |
      container-name := (filename.split ".")[0]
      containers[container-name] = {
        "entrypoint": filename,
      }
    pod-spec["containers"] = containers

  if not pod-spec.contains "\$schema": pod-spec["\$schema"] = "https://toit.io/schemas/artemis/pod-specification/v1.json"
  if not pod-spec.contains "name": pod-spec["name"] = "my-pod"
  if not pod-spec.contains "artemis-version": pod-spec["artemis-version"] = TEST-ARTEMIS-VERSION
  if not pod-spec.contains "sdk-version": pod-spec["sdk-version"] = fleet.tester.sdk-version
  if not pod-spec.contains "firmware-envelope": pod-spec["firmware-envelope"] = "esp32"

  pod-name := pod-spec["name"]

  spec-path := "$tmp-dir/$pod-spec-filename"
  write-json-to-file spec-path pod-spec
  pod-file := "$tmp-dir/$(pod-spec-filename).pod"

  fleet.run [
    "--fleet-root", fleet-dir,
    "pod", "build",
    "-o", pod-file,
    spec-path,
  ]

  fleet.run [
    "--fleet-root", fleet-dir,
    "pod", "upload",
    pod-file,
  ]

  output := fleet.run [
    "serial", "flash",
    "--fleet-root", fleet-dir,
    "--port", port,
    "--local", pod-file,
  ]

  print "Output: $output"
  // Grep out the device-id.
  // The output is something like:
  // "Successfully provisioned device polished-virus (5e0a2c16-75e9-56d6-9aef-a4d2d81ed3f5)""
  open-paren := output.index-of "("
  close-paren := output.index-of ")"
  device-id := output[open-paren + 1..close-paren]

  return Uuid.parse device-id
