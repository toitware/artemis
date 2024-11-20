// Copyright (C) 2023 Toitware ApS.

import host.directory
import uuid show Uuid
import artemis.cli.utils show
  read-json write-json-to-file write-yaml-to-file write-blob-to-file copy-directory

import .utils

class TestDeviceConfig:
  format/string
  path/string
  device-id/Uuid

  constructor --.format --.path --.device-id:

tmp-dir-counter := 0

/**
Uploads a pod to the fleet.

The $format is needed to determine which base pod-specification should be used.
*/
upload-pod -> Uuid
    --gold-name/string?=null
    --format/string
    --fleet/TestFleet
    --tmp-dir/string="$fleet.tester.tmp-dir/td-$format-$(tmp-dir-counter++)"
    --files/Map={:}
    --pod-spec/Map={:}
    --pod-spec-filename/string="my-pod.yaml":

  fleet.tester.ensure-available-artemis-service

  prefix := "--base-root="
  base-root/string? := null
  fleet.args.do:
    if it.starts-with prefix:
      if base-root:
        throw "Multiple $prefix arguments."
      base-root = it[prefix.size..]

  if not base-root:
    throw "Missing $prefix argument."

  directory.mkdir --recursive tmp-dir
  copy-directory --source="$base-root/base-$format" --target=tmp-dir

  files.do: | filename/string blob |
    write-blob-to-file "$tmp-dir/$filename" blob

  lock-file := "package.lock"
  lock-contents := make-lock-file-contents directory.cwd
  write-blob-to-file "$tmp-dir/$lock-file" lock-contents

  if not pod-spec.contains "artemis-version":
    pod-spec["artemis-version"] = TEST-ARTEMIS-VERSION
  if not pod-spec.contains "sdk-version":
    pod-spec["sdk-version"] = fleet.tester.sdk-version
  if not pod-spec.contains "extends":
    pod-spec["extends"] = ["base.yaml"]
  // The base contains the firmware-envelope entry.

  spec-path := "$tmp-dir/$pod-spec-filename"
  if spec-path.ends-with ".json":
    write-json-to-file spec-path pod-spec
  else if spec-path.ends-with ".yaml" or spec-path.ends-with ".yml":
    write-yaml-to-file spec-path pod-spec
  else:
    throw "Unknown pod spec file extension: $pod-spec-filename"
  pod-file := "$tmp-dir/$(pod-spec-filename).pod"

  fleet.run [
    "--fleet-root", fleet.fleet-dir,
    "pod", "build",
    "-o", pod-file,
    spec-path,
  ]

  upload-result := fleet.run --json [
    "--fleet-root", fleet.fleet-dir,
    "pod", "upload",
    pod-file,
  ]

  if gold-name:
    fleet.tester.replacements[upload-result["id"]] = pad-replacement-id gold-name
    fleet.tester.replacements[upload-result["name"]] = gold-name
    upload-result["tags"].do: | tag/string |
      if tag != "latest":
        fleet.tester.replacements[tag] = "auto-tag"

  return Uuid.parse upload-result["id"]

/**
Library to create a new device and extract the image for it.
*/

/**
Creates a new device and extracts the image for it.

The $format should be one supported by the `device extract` command. For
  testing it's typically either 'image' or 'tar'.
*/
create-extract-device -> TestDeviceConfig
    --format/string
    --fleet/TestFleet
    --files/Map
    --pod-spec/Map
    --pod-spec-filename/string="my-pod.yaml"
    --tmp-dir/string="$fleet.tester.tmp-dir/td-$format"
    --user-email/string=TEST-EXAMPLE-COM-EMAIL
    --user-password/string=TEST-EXAMPLE-COM-PASSWORD
    --org-id/Uuid=TEST-ORGANIZATION-UUID:

  upload-pod
      --format=format
      --fleet=fleet
      --files=files
      --pod-spec=pod-spec
      --pod-spec-filename=pod-spec-filename
      --tmp-dir=tmp-dir

  extension := format == "tar" ? "tar" : "bin"
  path := "$tmp-dir/$(pod-spec-filename).$extension"
  result := fleet.run --json [
    "fleet", "add-device",
    "--fleet-root", fleet.fleet-dir,
    "--format", format,
    "--output", path,
  ]

  return TestDeviceConfig --format=format --device-id=(Uuid.parse result["id"]) --path=path
