// Copyright (C) 2024 Toitware ApS.

import artemis.cli.server-config as cli-server-config
import monitor
import uuid
import .utils
import .broker show TestBroker
import .cli-device-extract as device-extract
import .broker show with-http-broker TestBroker ToitHttpBackdoor

class MigrationTest:
  test-cli/TestCli
  tmp-dir/string
  fleet-dir/string
  args/List
  brokers/List := []
  devices/Map := {:}

  constructor --.test-cli --.tmp-dir --.fleet-dir --.args:

  upload-pod gold-name/string -> uuid.Uuid:
    return device-extract.upload-pod
        --gold-name=gold-name
        --format="tar"
        --test-cli=test-cli
        --fleet-dir=fleet-dir
        --args=args

  create-device name/string --start/bool -> MigrationDevice:
    tar-file := "$tmp-dir/dev-$(name).tar"
    added-device := test-cli.run --json [
      "fleet", "add-device", "--format", "tar", "-o", tar-file, "--name", name
    ]
    device-id := uuid.parse added-device["id"]
    device-config := device-extract.TestDeviceConfig
        --device-id=device-id
        --format="tar"
        --path=tar-file

    test-device := test-cli.create-device
        --alias-id=device-id
        --hardware-id=device-id  // Not really used anyway.
        --device-config=device-config

    test-cli.replacements["$device-id"] = pad-replacement-id name

    migration-device := MigrationDevice name (test-device as TestDevicePipe) --test-cli=test-cli
    devices[name] = migration-device

    if start:
      migration-device.start
      migration-device.wait-for-synchronization

    return migration-device

  check-no-migration-stop:
    run --expect-exit-1 ["fleet", "migration", "stop"]

  update-device-output-positions -> none:
    devices.do --values: | device/MigrationDevice |
      device.update-output-pos

  get-status -> List:
    return test-cli.run --json ["fleet", "status"]

  /**
  Creates a new broker with the given name.
  */
  start-broker name/string -> MigrationBroker:
    started := monitor.Latch
    task::
      with-http-broker --name=name: | broker/TestBroker |
        cli-server-config.add-server-to-config test-cli.config broker.server-config
        done := monitor.Latch
        result := MigrationBroker name broker done
        started.set result
        // Keep the server running until we are done.
        done.get
    return started.get

  stop-main-broker -> none:
    (test-cli.broker.backdoor as ToitHttpBackdoor).stop

  run command/List --expect-exit-1/bool=false -> string:
    return test-cli.run --expect-exit-1=expect-exit-1 command

  run-gold --ignore-spacing/bool=false name/string description/string command/List -> none:
    test-cli.run-gold --ignore-spacing=ignore-spacing name description command

with-migration-test --args/List [block]:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    with-tmp-directory: | tmp-dir |
      test-cli.run [
        "auth", "login",
        "--email", TEST-EXAMPLE-COM-EMAIL,
        "--password", TEST-EXAMPLE-COM-PASSWORD,
      ]

      test-cli.run [
        "auth", "login",
        "--broker",
        "--email", TEST-EXAMPLE-COM-EMAIL,
        "--password", TEST-EXAMPLE-COM-PASSWORD,
      ]

      test := MigrationTest
          --test-cli=test-cli
          --tmp-dir=tmp-dir
          --fleet-dir=fleet-dir
          --args=args
      block.call test

class MigrationBroker:
  name/string
  test-broker/TestBroker
  done-latch/monitor.Latch

  constructor .name .test-broker .done-latch:

  close:
    done-latch.set true

class MigrationDevice:
  name/string
  test-device/TestDevicePipe
  test-cli/TestCli
  pos/int := 0

  constructor .name .test-device --.test-cli:

  id -> uuid.Uuid: return test-device.alias-id

  wait-for-synchronization:
    pos = test-device.wait-for-synchronized --start-at=pos

  wait-for needle/string:
    pos = test-device.wait-for needle --start-at=pos

  start:
    test-device.start

  stop:
    test-device.stop

  get-status_ -> List:
    return test-cli.run --json ["fleet", "status"]

  /**
  Updates the position in the output stream to the current size of the output.
  Any further $wait-for call will start from this position.
  */
  update-output-pos -> none:
    pos = test-device.output.size

  /**
  Waits until this device is on the new broker.
  Returns the last status line.
  */
  wait-to-be-on-broker broker/MigrationBroker --status/List?=null -> List:
    wait-for "[artemis] INFO: starting"
    if not status: status = get-status_
    while true:
      for i := 0; i < status.size; i++:
        status-line := status[i]
        if status-line["device-id"] != "$id":
          continue
        if status-line["broker"] == broker.name:
          return status
      sleep --ms=300
      status = test-cli.run --json ["fleet", "status"]

  /**
  Waits until this device is on the given pod.
  Returns the last status line.
  */
  wait-to-be-on-pod pod-id/uuid.Uuid --status/List?=null -> List:
    wait-for "[artemis.synchronize] INFO: firmware update: validated"
    if not status: status = get-status_
    while true:
      for i := 0; i < status.size; i++:
        status-line := status[i]
        if status-line["device-id"] != "$id":
          continue
        if status-line["pod-id"] == "$pod-id":
          return status
      sleep --ms=300
      status = test-cli.run --json ["fleet", "status"]

  get-current-broker --status=get-status_:
    for i := 0; i < status.size; i++:
      status-line := status[i]
      if status-line["device-id"] != "$id":
        continue
      return status-line["broker"]
    unreachable
