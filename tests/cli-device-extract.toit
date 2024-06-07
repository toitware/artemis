// Copyright (C) 2023 Toitware ApS.

import host.directory
import uuid
import artemis.cli.ui show Ui
import artemis.cli.utils show
  read-json write-json-to-file write-yaml-to-file write-blob-to-file copy-directory

import .utils

class TestDeviceConfig:
  format/string
  path/string
  device-id/uuid.Uuid

  constructor --.format --.path --.device-id:

/**
Uploads a pod to the fleet.

The $format is needed to determine which base pod-specification should be used.
*/
upload-pod
    --format/string
    --test-cli/TestCli
    --fleet-dir/string
    --args/List
    --tmp-dir/string="$test-cli.tmp-dir/td-$format"
    --files/Map={:}
    --pod-spec/Map={:}
    --pod-spec-filename/string="my-pod.yaml":

  test-cli.ensure-available-artemis-service

  prefix := "--base-root="
  base-root/string? := null
  args.do:
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
  lock-content := make-lock-file-content directory.cwd
  write-blob-to-file "$tmp-dir/$lock-file" lock-content

  if not pod-spec.contains "artemis-version":
    pod-spec["artemis-version"] = TEST-ARTEMIS-VERSION
  if not pod-spec.contains "sdk-version":
    pod-spec["sdk-version"] = test-cli.sdk-version
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

  test-cli.run [
    "--fleet-root", fleet-dir,
    "pod", "build",
    "-o", pod-file,
    spec-path,
  ]

  test-cli.run [
    "--fleet-root", fleet-dir,
    "pod", "upload",
    pod-file,
  ]

/**
Library to create a new device and extract the image for it.
*/

/**
Creates a new device and extracts the image for it.

The $format should be one supported by the `device extract` command. For
  testing it's typically either 'qemu' or 'tar'.
*/
create-extract-device -> TestDeviceConfig
    --format/string
    --test-cli/TestCli
    --fleet-dir/string
    --args/List
    --files/Map
    --pod-spec/Map
    --pod-spec-filename/string="my-pod.yaml"
    --tmp-dir/string="$test-cli.tmp-dir/td-$format"
    --user-email/string=TEST-EXAMPLE-COM-EMAIL
    --user-password/string=TEST-EXAMPLE-COM-PASSWORD
    --org-id/uuid.Uuid=TEST-ORGANIZATION-UUID
    --ui/Ui=TestUi:

  upload-pod
      --format=format
      --test-cli=test-cli
      --fleet-dir=fleet-dir
      --args=args
      --files=files
      --pod-spec=pod-spec
      --pod-spec-filename=pod-spec-filename
      --tmp-dir=tmp-dir

  extension := format == "tar" ? "tar" : "bin"
  path := "$tmp-dir/$(pod-spec-filename).$extension"
  result := test-cli.run --json [
    "fleet", "add-device",
    "--fleet-root", fleet-dir,
    "--format", format,
    "--output", path,
  ]

  return TestDeviceConfig --format=format --device-id=(uuid.parse result["id"]) --path=path
