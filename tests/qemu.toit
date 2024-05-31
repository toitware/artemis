// Copyright (C) 2023 Toitware ApS.

import host.directory
import uuid
import artemis.cli.ui show Ui
import artemis.cli.utils show
  read-json write-json-to-file write-yaml-to-file write-blob-to-file copy-directory

import .utils

build-qemu-image -> Map
    --test-cli/TestCli
    --fleet-dir/string
    --args/List
    --files/Map
    --pod-spec/Map
    --pod-spec-filename/string="my-pod.yaml"
    --tmp-dir/string="$test-cli.tmp-dir/qemu"
    --user-email/string=TEST-EXAMPLE-COM-EMAIL
    --user-password/string=TEST-EXAMPLE-COM-PASSWORD
    --org-id/uuid.Uuid=TEST-ORGANIZATION-UUID
    --ui/Ui=TestUi:

  test-cli.ensure-available-artemis-service

  prefix := "--qemu-base="
  qemu-base/string? := null
  args.do:
    if it.starts-with prefix:
      if qemu-base:
        throw "Multiple --qemu-base arguments."
      qemu-base = it[prefix.size..]

  if not qemu-base:
    throw "Missing --qemu-base argument."

  directory.mkdir --recursive tmp-dir
  copy-directory --source=qemu-base --target=tmp-dir

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
    pod-spec["extends"] = ["$qemu-base/base.yaml"]
  if not pod-spec.contains "firmware-envelope":
    pod-spec["firmware-envelope"] = "esp32"

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

  image-path := "$tmp-dir/$(pod-spec-filename).bin"
  output := test-cli.run [
    "serial", "flash",
    "--fleet-root", fleet-dir,
    "--port", "xxx",
    "--qemu-image", image-path,
  ]

  print "Output: $output"
  // Grep out the device-id.
  // The output is something like:
  // "Successfully provisioned device polished-virus (5e0a2c16-75e9-56d6-9aef-a4d2d81ed3f5)""
  open-paren := output.index-of "("
  close-paren := output.index-of ")"
  device-id := output[open-paren + 1..close-paren]

  return {
    "device-id": uuid.parse device-id,
    "image-path": image-path,
  }
