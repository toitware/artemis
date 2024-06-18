// Copyright (C) 2023 Toitware ApS.

import ar show ArReader
import artemis.cli.utils show write-blob-to-file write-yaml-to-file
import artemis.cli.firmware show get-envelope
import artemis.cli.pod show Pod
import artemis.cli.pod-specification show PodSpecification
import artemis.cli.sdk show Sdk
import expect show *
import host.file
import io
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet-dir := fleet.fleet-dir
  test-cli := fleet.test-cli
  ui := TestUi
  fleet.test-cli.ensure-available-artemis-service

  spec := {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "test-pod",
      "sdk-version": "$test-cli.sdk-version",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "firmware-envelope": "esp32",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test",
        },
      ],
  }
  spec-path := "$fleet-dir/test-pod.yaml"
  write-yaml-to-file spec-path spec
  fleet.run [
    "pod", "build", spec-path, "-o", "$fleet-dir/test-pod.pod"
  ]
  validate-pod "$fleet-dir/test-pod.pod"
      --name="test-pod"
      --containers=["artemis"]
      --test-cli=test-cli

  // Test custom firmwares.
  spec = {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "test-pod2",
      "sdk-version": "$test-cli.sdk-version",
      "firmware-envelope": "file://custom.envelope",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test",
        },
      ],
    }
  spec-path = "$fleet-dir/test-pod2.yaml"
  write-yaml-to-file spec-path spec

  custom-path := "$fleet-dir/custom.envelope"

  default-envelope := get-envelope-for --sdk-version=test-cli.sdk-version --cache=test-cli.cache --ui=ui
  write-blob-to-file custom-path default-envelope

  print "custom-path: $custom-path"
  sdk := Sdk --envelope-path=custom-path --cache=test-cli.cache --ui=ui
  custom-program := """
  main: print "custom"
  """
  custom-toit := "$fleet-dir/custom.toit"
  custom-snapshot := "$fleet-dir/custom.snapshot"
  write-blob-to-file custom-toit custom-program
  sdk.compile-to-snapshot --out=custom-snapshot custom-toit
  sdk.firmware-add-container "custom"
      --envelope=custom-path
      --program-path=custom-snapshot
      --trigger="none"

  fleet.run [
    "pod", "build", spec-path, "-o", "$fleet-dir/test-pod2.pod"
  ]
  validate-pod "$fleet-dir/test-pod2.pod"
      --name="test-pod2"
      --containers=["artemis", "custom"]
      --test-cli=test-cli

  // Test compiler flags.
  spec = {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "test-pod3",
      "sdk-version": "$test-cli.sdk-version",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "firmware-envelope": "esp32",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ],
      "containers": {
        "hello": {
          "entrypoint": "hello.toit",
          "compile-flags": ["-O0"]
        }
      }
    }
  spec-path = "$fleet-dir/test-pod3.yaml"
  write-yaml-to-file spec-path spec
  write-blob-to-file "$fleet-dir/hello.toit" """
    main: print "hello"
    """

  fleet.run [
    "pod", "build", spec-path, "-o", "$fleet-dir/test-pod3.pod"
  ]
  validate-pod "$fleet-dir/test-pod3.pod"
      --name="test-pod3"
      --containers=["artemis", "hello"]
      --test-cli=test-cli

  // Test invalid compiler flag.
  // This ensures that the compiler flags are actually passed to the compiler.
  spec = {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "test-pod4",
      "sdk-version": "$test-cli.sdk-version",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "firmware-envelope": "esp32",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ],
      "containers": {
        "hello": {
          "entrypoint": "hello.toit",
          "compile-flags": ["-O0", "--invalid"]
        }
      }
    }
  spec-path = "$fleet-dir/test-pod4.yaml"
  write-yaml-to-file spec-path spec

  fleet.run --expect-exit-1 --no-quiet [
    "pod", "build", spec-path, "-o", "$fleet-dir/test-pod4.pod"
  ]

validate-pod pod-path/string --name/string --containers/List --test-cli/TestCli:
  artemis := test-cli
  with-tmp-directory: | tmp-dir |
    pod := Pod.parse pod-path --tmp-directory=tmp-dir --ui=(TestUi --no-quiet)
    expect-equals name pod.name
    envelope := pod.envelope
    seen := {}
    reader := ArReader (io.Reader envelope)
    while file := reader.next:
      seen.add file.name
    containers.do:
      expect (seen.contains it)

get-envelope-for --sdk-version/string --cache --ui -> ByteArray:
  default-spec := {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "test-pod2",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "sdk-version": "$sdk-version",
      "firmware-envelope": "esp32",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ]
    }
  pod-specification := PodSpecification.from-json default-spec --path="ignored" --ui=TestUi

  default-envelope-path := get-envelope --specification=pod-specification --cache=cache --ui=ui
  return file.read-content default-envelope-path
