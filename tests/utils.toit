// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli as cli-pkg
import cli.ui as cli-pkg
import encoding.base64
import encoding.json
import encoding.json as json-encoding
import encoding.ubjson
import expect show *
import log
import host.directory
import host.pipe
import host.file
import host.os
import fs
import http
import net
import system
import uuid show Uuid
import artemis.cli as artemis-pkg
import artemis.cli.server-config as cli-server-config
import artemis.cli.cache as artemis-cache
import artemis.cli.utils show read-json write-json-to-file untar
import artemis.shared.server-config
import artemis.shared.version as configured-version
import artemis.service
import artemis.service.brokers.broker show BrokerConnection BrokerService
import artemis.service.device show Device
import artemis.service.storage show Storage
import artemis.cli.utils show write-blob-to-file read-base64-ubjson
import ..tools.service-image-uploader.uploader as uploader
import monitor
import .artemis-server
import .broker
import .broker as broker-lib
import .cli-device-extract show TestDeviceConfig
import .cli-device-extract as device-extract
import .test-device show BACKDOOR-FOOTER extract-backdoor-url
import .supabase-local-server

export Device

/** test@example.com is an admin of the $TEST-ORGANIZATION-UUID. */
TEST-EXAMPLE-COM-EMAIL ::= "test@example.com"
TEST-EXAMPLE-COM-PASSWORD ::= "password"
TEST-EXAMPLE-COM-UUID ::= Uuid.parse "f76629c5-a070-4bbc-9918-64beaea48848"
TEST-EXAMPLE-COM-NAME ::= "Test User"

/** demo@example.com is a member of the $TEST-ORGANIZATION-UUID. */
DEMO-EXAMPLE-COM-EMAIL ::= "demo@example.com"
DEMO-EXAMPLE-COM-PASSWORD ::= "password"
DEMO-EXAMPLE-COM-UUID ::= Uuid.parse "d9064bb5-1501-4ec9-bfee-21ab74d645b8"
DEMO-EXAMPLE-COM-NAME ::= "Demo User"

ADMIN-EMAIL ::= "test-admin@toit.io"
ADMIN-PASSWORD ::= "password"
ADMIN-UUID ::= Uuid.parse "6ac69de5-7b56-4153-a31c-7b4e29bbcbcf"
ADMIN-NAME ::= "Admin User"

/** Preseeded "Test Organization". */
TEST-ORGANIZATION-NAME ::= "Test Organization"
TEST-ORGANIZATION-UUID ::= Uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

/** Preseeded test device in $TEST-ORGANIZATION-UUID. */
TEST-DEVICE-UUID ::= Uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
TEST-DEVICE-ALIAS ::= Uuid.parse "191149e5-a95b-47b1-80dd-b149f953d272"

TEST-POD-UUID ::= Uuid.parse "0e29c450-f802-49cc-b695-c5add71fdac3"

NON-EXISTENT-UUID ::= Uuid.uuid5 "non" "existent"

UPDATE-GOLD-ENV ::= "UPDATE_GOLD"

TEST-SDK-VERSION/string := configured-version.SDK-VERSION
// Only add the '-TEST' suffix if it's not already there.
TEST-ARTEMIS-VERSION ::= "$(configured-version.ARTEMIS-VERSION.trim --right "-TEST")-TEST"

with-tmp-directory [block]:
  tmp-dir := directory.mkdtemp "/tmp/artemis-test-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

with-tmp-config-cli [block]:
  with-tmp-directory: | directory |
    config-path := "$directory/config"
    app-name := "artemis-test"
    config := cli-pkg.Config --app-name=app-name --path=config-path --data={:}
    cli := cli-pkg.Cli app-name --config=config

    block.call cli

class TestExit:

interface TestPrinter:
  set-test-ui_ test-ui/TestUi?

class TestHumanPrinter extends cli-pkg.HumanPrinter implements TestPrinter:
  test-ui_/TestUi? := null

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.stdout += "$str\n"

  set-test-ui_ test-ui/TestUi:
    test-ui_ = test-ui

class TestJsonPrinter extends cli-pkg.JsonPrinter implements TestPrinter:
  test-ui_/TestUi? := null

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.stderr += "$str\n"

  emit-structured --kind/int data:
    test-ui_.stdout += json.stringify data

  set-test-ui_ test-ui/TestUi:
    test-ui_ = test-ui

class TestUi extends cli-pkg.Ui:
  stdout/string := ""
  stderr/string := ""
  quiet_/bool
  json_/bool

  constructor --level/int=cli-pkg.Ui.NORMAL-LEVEL --quiet/bool=true --json/bool=false:
    quiet_ = quiet
    json_ = json
    printer := create-printer_ --json=json
    super --printer=printer --level=level
    (printer as TestPrinter).set-test-ui_ this

  static create-printer_ --json/bool -> cli-pkg.Printer:
    if json: return TestJsonPrinter
    return TestHumanPrinter

  abort:
    throw TestExit


class TestCli implements cli-pkg.Cli:
  name/string
  ui/TestUi

  constructor --.name/string="test" --quiet/bool=true:
    ui=(TestUi --quiet=quiet)

  cache -> cli-pkg.Cache:
    unreachable

  config -> cli-pkg.Config:
    unreachable

  with --name=null --cache=null --config=null --ui=null:
    unreachable

class Tester:
  cli/cli-pkg.Cli
  artemis/TestArtemisServer
  broker/TestBroker
  toit-run-path_/string
  qemu-path_/string?
  test-devices_/List ::= []
  /** A map of strings to be replaced in the output of $run. */
  replacements/Map ::= {:}
  gold-name/string
  sdk-version/string
  tmp-dir/string

  constructor .artemis .broker
      --toit-run-path/string
      --qemu-path/string?
      --.gold-name
      --.sdk-version
      --.tmp-dir
      --.cli:
    toit-run-path_ = toit-run-path
    qemu-path_ = qemu-path

  close:
    test-devices_.do: | device/TestDevice |
      device.close
      artemis.backdoor.remove-device device.hardware-id

  login:
    run [
      "auth", "login",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

    run [
      "auth", "login",
      "--broker",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

  run args/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true -> string:
    return run args --expect-exit-1=expect-exit-1 --allow-exception=allow-exception --quiet=quiet --no-json

  run args/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true --json/bool -> any:
    ui := TestUi --quiet=quiet --json=json
    run-cli := cli.with --ui=ui
    exception := null
    try:
      exception = catch --unwind=(: not expect-exit-1 or (not allow-exception and it is not TestExit)):
        artemis-pkg.main args --cli=run-cli
    finally: | is-exception _ |
      if is-exception:
        print "Execution of '$args' failed unexpectedly."
        print ui.stdout

    if expect-exit-1 and not exception:
      throw "Expected exit 1, but got exit 0"
    if json: return json-encoding.parse ui.stdout
    return ui.stdout

  /**
  Variant of $(run-gold test-name description args [--before-gold]).
  */
  run-gold
      test-name/string
      description/string
      args/List
      --ignore-spacing/bool=false
      --expect-exit-1/bool=false:
    run-gold test-name
        description
        args
        --expect-exit-1=expect-exit-1
        --ignore-spacing=ignore-spacing
        --before-gold=: it

  /**
  Runs the CLI with the given $args.

  The $test-name is used as filename for the gold file.
  The $description is embedded in the output of the gold file.

  If $expect-exit-1 then the test is negative and must fail.

  If $ignore-spacing is true, then all whitespace is ignored when comparing.
    Also, all table characters (like "┌────┬────────┐") are ignored.

  The $before-gold block is called with the output of the running the command.
    It must return a new output (or the same as the input). It can be used
    to update the $replacements.
  */
  run-gold
      test-name/string
      description/string
      args/List
      --ignore-spacing/bool=false
      --expect-exit-1/bool=false
      [--before-gold]:
    output := run args --expect-exit-1=expect-exit-1
    output = before-gold.call output
    output = canonicalize-gold_ output args --description=description
    gold-path := "gold/$gold-name/$(test-name).txt"
    if os.env.get UPDATE-GOLD-ENV or not file.is-file gold-path:
      directory.mkdir --recursive "gold/$gold-name"
      write-blob-to-file gold-path output
      print "Updated gold file '$gold-path'."
    gold-contents := (file.read-contents gold-path).to-string
    // In case we are on Windows or something else introduced \r\n.
    gold-contents = gold-contents.replace --all "\r\n" "\n"

    if ignore-spacing:
      [" ", "┌", "─", "┬", "┐", "│", "├",  "┼", "┤", "└", "┴", "┘"].do: | char |
        gold-contents = gold-contents.replace --all char ""
        output = output.replace --all char ""
    if gold-contents != output:
      print "Gold file '$gold-path' does not match output."
      print "Output:"
      print output
      print "Gold:"
      print gold-contents
      print "gold-contents.size: $gold-contents.size"
      print "output.size: $output.size"
      for i := 0; i < (min output.size gold-contents.size); i++:
        if output[i] != gold-contents[i]:
          print "First difference at $i $output[i] != $gold-contents[i]."
          break
    expect-equals gold-contents output

  canonicalize-gold_ output/string args --description/string -> string:
    result := "# $description\n# $args\n$output"
    replacements.do: | key val|
      result = result.replace --all key val
    result = result.replace --all "\r\n" "\n"
    return result

  /**
  Creates and starts new device in the given $organization-id.
  Neither the 'check-in', nor the firmware service are set up.

  The $firmware-token is used to build the encoded firmware.
  By default a random token is used.
  */
  create-device -> TestDevice
      --organization-id/Uuid=TEST-ORGANIZATION-UUID
      --firmware-token/ByteArray?=null:
    device-description := create-device_ organization-id firmware-token
    hardware-id/Uuid := device-description["id"]
    alias-id/Uuid := device-description["alias"]
    encoded-firmware := device-description["encoded_firmware"]

    result := TestDevicePipe.fake-host
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --toit-run=toit-run-path_
        --encoded-firmware=encoded-firmware
        --tester=this
    test-devices_.add result
    return result

  create-device -> TestDevice
      --alias-id/Uuid
      --hardware-id/Uuid
      --device-config/TestDeviceConfig
      --organization-id=TEST-ORGANIZATION-UUID:
    result/TestDevice := ?
    if device-config.format == "image":
      result = TestDevicePipe.qemu
          --broker=broker
          --alias-id=alias-id
          --hardware-id=hardware-id
          --organization-id=TEST-ORGANIZATION-UUID
          --image-path=device-config.path
          --qemu-path=qemu-path_
          --tester=this
    else if device-config.format == "tar":
      result = TestDevicePipe.host
          --broker=broker
          --alias-id=alias-id
          --hardware-id=hardware-id
          --organization-id=TEST-ORGANIZATION-UUID
          --tar-path=device-config.path
          --tester=this
    else:
      throw "Unknown format"

    test-devices_.add result
    return result

  listen-to-serial-device -> TestDevicePipe
      --alias-id/Uuid
      --hardware-id/Uuid
      --serial-port/string:
    result := TestDevicePipe.serial
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --serial-port=serial-port
        --toit-run=toit-run-path_
        --tester=this
    result.start
    test-devices_.add result
    return result

  start-fake-device -> FakeDevice
      --organization-id/Uuid=TEST-ORGANIZATION-UUID
      --firmware-token/ByteArray?=null:
    device-description := create-device_ organization-id firmware-token
    hardware-id/Uuid := device-description["id"]
    alias-id/Uuid := device-description["alias"]
    encoded-firmware := device-description["encoded_firmware"]

    result := FakeDevice
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --encoded-firmware=encoded-firmware
        --tester=this
    result.start
    test-devices_.add result
    return result

  start-fake-device --identity/Map --firmware-token/ByteArray?=null -> FakeDevice:
    device-description := identity["artemis.device"]
    hardware-id/Uuid := Uuid.parse device-description["hardware_id"]
    alias-id/Uuid := Uuid.parse device-description["device_id"]
    organization-id/Uuid := Uuid.parse device-description["organization_id"]

    encoded-firmware := build-encoded-firmware
        --firmware-token=firmware-token
        --device-id=alias-id
        --organization-id=TEST-ORGANIZATION-UUID
        --hardware-id=hardware-id

    result := FakeDevice
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=organization-id
        --encoded-firmware=encoded-firmware
        --tester=this
    result.start
    test-devices_.add result
    return result

  create-device_ organization-id/Uuid firmware-token/ByteArray?=null -> Map:
    device-description := artemis.backdoor.create-device --organization-id=organization-id
    hardware-id/Uuid := device-description["id"]
    alias-id/Uuid := device-description["alias"]
    initial-state := {
      "identity": {
        "device_id": "$alias-id",
        "organization_id": "$organization-id",
        "hardware_id": "$hardware-id",
      }
    }

    broker.backdoor.create-device --device-id=alias-id --state=initial-state

    encoded-firmware := build-encoded-firmware
        --firmware-token=firmware-token
        --device-id=alias-id
        --organization-id=TEST-ORGANIZATION-UUID
        --hardware-id=hardware-id

    device-description["encoded_firmware"] = encoded-firmware

    return device-description

  /**
  Ensures that there exists a service image uploaded.
  */
  ensure-available-artemis-service
      --sdk-version=TEST-SDK-VERSION
      --artemis-version=TEST-ARTEMIS-VERSION:
    if TEST-ARTEMIS-VERSION != configured-version.ARTEMIS-VERSION:
      // The uploader will call 'make' if the versions don't match.
      // That's not safe when multiple tests run in parallel. The
      // testing framework has a pre-build step that ensures that the
      // versions match.
      throw "The configured version is not the test version"
    with-tmp-directory: | admin-tmp-dir |
      admin-config := cli-pkg.Config
          --app-name="test"
          --path="$admin-tmp-dir/config"
          --data=(deep-copy_ cli.config.data)
      ui := TestUi
      admin-cli := cli-pkg.Cli "test"
          --config=admin-config
          --ui=ui
          --cache=cli.cache
      artemis-pkg.main --cli=admin-cli [
            "auth", "login",
            "--email", ADMIN-EMAIL,
            "--password", ADMIN-PASSWORD,
          ]
      uploader.main --cli=admin-cli
          [
            "service",
            "--sdk-version", sdk-version,
            "--service-version", artemis-version,
            "--force",
            "--local"
          ]


  /**
  Stops the main broker.

  This is only possible with the HTTP broker.
  */
  stop-main-broker -> none:
    (broker.backdoor as broker-lib.ToitHttpBackdoor).stop

abstract class TestDevice:
  hardware-id/Uuid
  alias-id/Uuid
  organization-id/Uuid
  broker/TestBroker
  tester/Tester
  pos_/int := 0

  constructor --.broker --.hardware-id --.alias-id --.organization-id --.tester:

  /**
  Starts the device.

  Typically, the device is automatically started when it is created.
  */
  abstract start -> none

  /**
  Stops the device.

  Not all test devices support stopping (and resuming).
  */
  abstract stop -> none

  /**
  Closes the test device and releases all broker connections.
  */
  abstract close -> none

  /**
  The output of the device.
  Grows as the device runs.
  */
  abstract output -> string

  /**
  Clears the output of the device.
  */
  abstract clear-output -> none

  /**
  Waits for a specific $needle in the output.

  Starts searching at $start-at.
  Returns the index *after* the needle.
  */
  abstract wait-for needle/string --start-at/int=pos_ --not-followed-by/string?=null --update-pos/bool=true -> int

  /**
  Updates the position in the output stream to the current size of the output.
  Any further $wait-for call will start from this position.
  */
  abstract update-output-pos -> none

  id -> Uuid: return alias-id

  wait-for-synchronized --start-at/int=pos_ --update-pos/bool=true -> int:
    new-pos := wait-for "[artemis.synchronize] INFO: synchronized"
        --start-at=start-at
        --not-followed-by=" state"
    if update-pos: pos_ = new-pos
    return new-pos


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
      status = tester.run --json ["fleet", "status"]

  /**
  Waits until this device is on the given pod.
  Returns the last status line.
  */
  wait-to-be-on-pod pod-id/Uuid --status/List?=null -> List:
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
      status = tester.run --json ["fleet", "status"]


  get-current-broker --status=get-status_:
    for i := 0; i < status.size; i++:
      status-line := status[i]
      if status-line["device-id"] != "$id":
        continue
      return status-line["broker"]
    unreachable

  get-status_ -> List:
    return tester.run --json ["fleet", "status"]

  /**
  Waits until the device has connected to the broker.

  Periodically queries the broker to see whether the device has
    reported its state.
  */
  wait-until-connected --timeout=(Duration --ms=10_000) -> none:
      // Wait until the device has reported its state.
      with-timeout timeout:
        while true:
          state := broker.backdoor.get-state alias-id
          // The initial state has the field "identity" in it.
          if not state.contains "identity": break
          sleep --ms=100

class FakeDevice extends TestDevice:
  device_/Device := ?
  pending-state_/Map? := null
  goal-state/Map? := null
  network_/net.Client? := ?

  constructor
      --broker/TestBroker
      --hardware-id/Uuid
      --alias-id/Uuid
      --organization-id/Uuid
      --encoded-firmware/string
      --tester/Tester:
    network_ = net.open
    firmware-state := {
      "firmware": encoded-firmware
    }
    device_ = Device
        --id=alias-id
        --hardware-id=hardware-id
        --organization-id=organization-id
        --firmware-state=firmware-state
        --storage=Storage
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id
        --tester=tester

  start:
    // Do nothing.

  stop:
    // Do nothing.

  close:
    if network_:
      network_.close
      network_ = null

  output -> string:
    throw "UNIMPLEMENTED"

  clear-output -> none:
    throw "UNIMPLEMENTED"

  wait-for needle/string --start-at/int=pos_ --not-followed-by/string?=null --update-pos/bool=true -> int:
    throw "UNIMPLEMENTED"

  wait-until-connected --timeout=(Duration --ms=5_000) -> none:
    // Do nothing.

  update-output-pos -> none:
    // Do nothing.

  with-broker-connection_ [block]:
    broker.with-service: | service/BrokerService |
      broker-connection := service.connect --device=device_ --network=network_
      try:
        block.call broker-connection
      finally:
        broker-connection.close

  /**
  Reports the state to the broker.

  Basically a copy of `report_state` of the synchronize library.
  */
  report-state:
    state := {
      "firmware-state": device_.firmware-state,
    }
    if device_.pending-firmware:
      state["pending-firmware"] = device_.pending-firmware
    if device_.is-current-state-modified:
      state["current-state"] = device_.current-state
    if goal-state:
      state["goal-state"] = goal-state

    with-broker-connection_: | broker-connection/BrokerConnection |
      broker-connection.report-state state

  /**
  Synchronizes with the broker.
  Use $flash to simulate flashing the goal.
  */
  synchronize:
    with-broker-connection_: | broker-connection/BrokerConnection |
      goal-state = broker-connection.fetch-goal-state --no-wait

  /**
  Simulates flashing the goal state.
  */
  flash:
    if not goal-state: return
    pending-state_ = goal-state
    device_.pending-firmware = pending-state_["firmware"]

  /**
  Simulates a reboot, thus making the pending state the firmware state.
  */
  reboot:
    if not pending-state_: return
    // We can't change the firmware state (final variable).
    // Replace the whole device object.
    device_ = Device
        --id=alias-id
        --hardware-id=hardware-id
        --organization-id=organization-id
        --firmware-state=pending-state_
        --storage=Storage
    if pending-state_ == goal-state:
      goal-state = null
    pending-state_ = null

class TestDeviceBackdoor:
  network_/net.Client? := ?
  client_/http.Client? := ?
  address_/string

  constructor .address_:
    network_ = net.open
    client_ = http.Client network_

  device-id -> Uuid:
    return Uuid.parse (get_ "device-id")

  get-storage --ram/bool=false --flash/bool=false key/string:
    if not ram and not flash:
      throw "At least one of --ram or --flash must be true"
    if ram and flash:
      throw "Only one of --ram or --flash can be true"
    scheme := ram ? "ram" : "flash"
    return get_ "storage/$scheme/$key"

  set-storage --ram/bool=false --flash/bool=false key/string value/any:
    if not ram and not flash:
      throw "At least one of --ram or --flash must be true"
    if ram and flash:
      throw "Only one of --ram or --flash can be true"
    scheme := ram ? "ram" : "flash"
    return post_ "storage/$scheme/$key" value

  get_ path/string -> any:
    uri := "$address_/$path"
    response := client_.get --uri=uri
    return json.decode-stream response.body

  post_ path/string payload/any=null -> any:
    uri := "$address_/$path"
    print "URI: $uri"
    response := client_.post-json --uri=uri payload
    return json.decode-stream response.body

  close:
    if client_:
      client_.close
      client_ = null
    if network_:
      network_.close
      network_ = null

class TestDevicePipe extends TestDevice:
  output_/ByteArray := #[]
  child-process_/any := null
  signal_ := monitor.Signal
  stdout-task_/Task? := null
  stderr-task_/Task? := null
  tmp-dir/string? := null
  command_/List := ?
  has-backdoor/bool ::= false
  backdoor/TestDeviceBackdoor? := null

  constructor.fake-host
      --broker/TestBroker
      --hardware-id/Uuid
      --alias-id/Uuid
      --organization-id/Uuid
      --encoded-firmware/string
      --toit-run/string
      --tester/Tester:

    broker-config-json := broker.server-config.to-service-json --der-serializer=: unreachable
    encoded-broker-config := json.stringify broker-config-json

    command_ = [
      toit-run,
      "test-device.toit",
      "--hardware-id=$hardware-id",
      "--alias-id=$alias-id",
      "--organization-id=$organization-id",
      "--encoded-firmware=$encoded-firmware",
      "--broker-config-json=$encoded-broker-config",
    ]
    has-backdoor = true
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id
        --tester=tester

  constructor.serial
      --broker/TestBroker
      --hardware-id/Uuid
      --alias-id/Uuid
      --organization-id/Uuid
      --serial-port/string
      --toit-run/string
      --tester/Tester:
    command_ = [
      toit-run,
      "test-device-serial.toit",
      "--port", serial-port
    ]
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id
        --tester=tester

  constructor.qemu
        --broker/TestBroker
        --hardware-id/Uuid
        --alias-id/Uuid
        --organization-id/Uuid
        --image-path/string
        --qemu-path/string
        --tester/Tester:
    command_ = [
      qemu-path,
      "-L", (fs.dirname qemu-path),
      "-M", "esp32",
      "-nographic",
      "-drive", "file=$image-path,format=raw,if=mtd",
      "-nic", "user,model=open_eth",
    ]
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id
        --tester=tester

  constructor.host
      --broker/TestBroker
      --hardware-id/Uuid
      --alias-id/Uuid
      --organization-id/Uuid
      --tar-path/string
      --tester/Tester:
    tmp-dir = directory.mkdtemp "/tmp/artemis-test-"
    untar tar-path --target=tmp-dir
    boot-sh := "$tmp-dir/boot.sh"
    command_ = ["bash", boot-sh]
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id
        --tester=tester

  start --env/Map?=null:
    if child-process_: throw "Already started"
    fork_ --env=env
    if has-backdoor:
      wait-for BACKDOOR-FOOTER
      backdoor-address := extract-backdoor-url output_[..pos_]
      backdoor = TestDeviceBackdoor backdoor-address

  stop:
    if child-process_:
      kill-subprocess_
    if stdout-task_:
      stdout-task_.cancel
      stdout-task_ = null
    if stderr-task_:
      stderr-task_.cancel
      stderr-task_ = null

  fork_ --env/Map?=null:
    fork-data := pipe.fork
        --environment=env
        true                // use_path.
        // We create a stdin pipe, so that qemu can't interfere with
        // our terminal.
        pipe.PIPE-CREATED   // stdin.
        pipe.PIPE-CREATED   // stdout.
        pipe.PIPE-CREATED   // stderr.
        command_.first
        command_
    stdin := fork-data[0]
    stdout := fork-data[1]
    stderr := fork-data[2]
    child-process_ = fork-data[3]

    stdin.close

    // We are listening to both stdout and stderr.
    // We expect only one to be really used. Otherwise, looking for
    // specific strings in the output might not work, as the stdout and
    // stderr could be interleaved.

    stdout-task_ = task --background::
      try:
        catch --trace:
          reader := stdout.in
          while chunk := reader.read:
            output_ += chunk
            print-on-stderr_ "STDOUT: '$chunk.to-string-non-throwing'"
            signal_.raise
      finally:
        stdout.close

    stderr-task_ = task --background::
      try:
        catch --trace:
          reader := stderr.in
          while chunk := reader.read:
            output_ += chunk
            print-on-stderr_ "STDERR: '$chunk.to-string-non-throwing'"
            signal_.raise
      finally:
        stderr.close

  kill-subprocess_:
    SIGTERM ::= 15
    SIGKILL ::= 9
    [SIGTERM, SIGKILL].do: | signal |
      catch:
        with-timeout --ms=250:
          pipe.kill_ child-process_ signal
          pipe.wait-for child-process_
          child-process_ = null
        return

  close:
    critical-do:
      stop
      if tmp-dir:
        directory.rmdir --recursive tmp-dir
        tmp-dir = null
    if backdoor:
      backdoor.close
      backdoor = null

  output -> string:
    return output_.to-string-non-throwing

  clear-output -> none:
    pos_ = 0
    output_ = #[]

  update-output-pos -> none:
    pos_ = output_.size

  wait-for needle/string --start-at/int=pos_ --not-followed-by/string?=null --update-pos/bool=true -> int:
    not-followed-size := not-followed-by ? not-followed-by.size : 0
    start := start-at
    signal_.wait:
      if output_.size < start-at + needle.size + not-followed-size: continue.wait false
      output-string := output_.to-string-non-throwing
      while true:
        index := output-string.index-of needle start
        if index == -1: continue.wait false
        if not-followed-by and
            output-string[index + needle.size ..].starts-with not-followed-by:
          // This occurrence was followed by the "not-followed-by" string.
          // Try again starting at the next character.
          start = index + 1
          continue
        if update-pos: pos_ = index + needle.size
        return index + needle.size
    unreachable

/**
Starts the artemis server and broker.

Calls the given $block with a $Tester instance and a $Device or null.

If the type is supabase, uses the running supabase instances. Otherwise,
  creates fresh instances of the brokers.

If the $args parameter contains a '--toit-run=...' argument, it is
  used to launch devices.
*/
with-tester
    --args/List
    --artemis-type=(server-type-from-args args)
    --broker-type=(broker-type-from-args args)
    --logger/log.Logger=log.default
    --gold-name/string?=null
    [block]:
  with-artemis-server --args=args --type=artemis-type: | artemis-server |
    with-tester
        --artemis-server=artemis-server
        broker-type
        --logger=logger
        --args=args
        --gold-name=gold-name
        block

with-tester
    --artemis-server/TestArtemisServer
    broker-type
    --logger/log.Logger
    --args/List
    --gold-name/string?
    [block]:
  with-broker --args=args --type=broker-type --logger=logger: | broker/TestBroker |
    with-tester
        --artemis-server=artemis-server
        --broker=broker
        --logger=logger
        --args=args
        --gold-name=gold-name
        block

with-tester
    --artemis-server/TestArtemisServer
    --broker/TestBroker
    --logger/log.Logger
    --args/List
    --gold-name/string?
    [block]:

  // Use 'toit.run' (or 'toit.run.exe' on Windows), unless there is an
  // argument `--toit-run=...`.
  is-windows := system.platform == system.PLATFORM-WINDOWS
  toit-run-path := is-windows ? "toit.run.exe" : "toit.run"
  qemu-path := is-windows ? "qemu-system-xtensa.exe" : "qemu-system-xtensa"
  toit-run-prefix := "--toit-run="
  qemu-prefix := "--qemu="
  for i := 0; i < args.size; i++:
    arg := args[i]
    if arg.starts-with toit-run-prefix:
      toit-run-path = arg[toit-run-prefix.size..]
    if arg.starts-with qemu-prefix:
      qemu-path = arg[qemu-prefix.size..]

  with-tmp-directory: | tmp-dir |
    config-file := "$tmp-dir/config"
    config := cli-pkg.Config --app-name="test" --path=config-file --init=: {:}
    cache-dir := "$tmp-dir/CACHE"
    directory.mkdir cache-dir
    cache := cli-pkg.Cache --app-name="artemis-test" --path=cache-dir

    cli := cli-pkg.Cli "test" --config=config --cache=cache --ui=TestUi

    SDK-VERSION-OPTION ::= "--sdk-version="
    SDK-PATH-OPTION ::= "--sdk-path="
    ENVELOPE-PATH-ESP32-OPTION ::= "--envelope-esp32-path="
    ENVELOPE-PATH-ESP32-QEMU-OPTION ::= "--envelope-esp32-qemu-path="
    ENVELOPE-PATH-HOST-OPTION ::= "--envelope-host-path="

    sdk-version := "v0.0.0"
    sdk-path/string? := null
    envelope-esp32-path/string? := null
    envelope-esp32-qemu-path/string? := null
    envelope-host-path/string? := null
    args.do: | arg/string |
      if arg.starts-with SDK-VERSION-OPTION:
        sdk-version = arg[SDK-VERSION-OPTION.size ..]
      else if arg.starts-with SDK-PATH-OPTION:
        sdk-path = arg[SDK-PATH-OPTION.size ..]
      else if arg.starts-with ENVELOPE-PATH-ESP32-OPTION:
        envelope-esp32-path = arg[ENVELOPE-PATH-ESP32-OPTION.size ..]
      else if arg.starts-with ENVELOPE-PATH-ESP32-QEMU-OPTION:
        envelope-esp32-qemu-path = arg[ENVELOPE-PATH-ESP32-QEMU-OPTION.size ..]
      else if arg.starts-with ENVELOPE-PATH-HOST-OPTION:
        envelope-host-path = arg[ENVELOPE-PATH-HOST-OPTION.size ..]

    if sdk-version == ""
        or not sdk-path
        or not envelope-esp32-path
        or not envelope-esp32-qemu-path
        or not envelope-host-path:
      print "Missing SDK version, SDK path or envelope path."
      exit 1
    TEST-SDK-VERSION = sdk-version

    // Prefill the cache with the Dev SDK from the Makefile.
    sdk-key := artemis-cache.cache-key-sdk --version=sdk-version
    cache.get-directory-path sdk-key: | store/cli-pkg.DirectoryStore |
      store.copy sdk-path

    ENVELOPES-URL-PREFIX ::= "github.com/toitlang/envelopes/releases/download/$sdk-version"
    ENVELOPE-ARCHITECTURES ::= {
      "esp32": envelope-esp32-path,
      "esp32-qemu": envelope-esp32-qemu-path,
      // We are using "host" as envelope name for the current platform.
      // The github release page does not have any "host" envelope, but this way
      // we don't need to change the tests depending on which platform they run.
      "host": envelope-host-path,
     }
    ENVELOPE-ARCHITECTURES.do: | envelope-arch/string cached-path/string |
      envelope-url := "$ENVELOPES-URL-PREFIX/firmware-$(envelope-arch).envelope.gz"
      envelope-key := artemis-cache.cache-key-url-artifact
          --url=envelope-url
          --kind=artemis-cache.CACHE-ARTIFACT-KIND-ENVELOPE
      cache.get-file-path envelope-key: | store/cli-pkg.FileStore |
        print "Caching envelope: $cached-path for $envelope-arch"
        store.copy cached-path

    artemis-config := artemis-server.server-config
    broker-config := broker.server-config
    cli-server-config.add-server-to-config artemis-config --cli=cli
    cli-server-config.add-server-to-config broker-config --cli=cli

    artemis-task/Task? := null

    if not gold-name:
      toit-file := system.program-name
      last-separator := max (toit-file.index-of --last "/") (toit-file.index-of --last "\\")
      gold-name = toit-file[last-separator + 1 ..].trim --right ".toit"
      gold-name = gold-name.trim --right "_slow"

    tester := Tester artemis-server broker
        --toit-run-path=toit-run-path
        --qemu-path=qemu-path
        --gold-name=gold-name
        --sdk-version=sdk-version
        --tmp-dir=tmp-dir
        --cli=cli

    tester.replacements[tmp-dir] = "TMP_DIR"
    tester.replacements[TEST-SDK-VERSION] = "TEST_SDK_VERSION"
    tester.replacements[TEST-ARTEMIS-VERSION] = "TEST_ARTEMIS_VERSION"

    try:
      tester.run ["config", "broker", "--artemis", "default", artemis-config.name]
      tester.run ["config", "broker", "default", broker-config.name]
      block.call tester
    finally:
      tester.close
      if artemis-task: artemis-task.cancel
      directory.rmdir --recursive cache-dir

build-encoded-firmware -> string
    --device-id/Uuid
    --organization-id/Uuid=TEST-ORGANIZATION-UUID
    --hardware-id/Uuid=device-id
    --firmware-token/ByteArray=#[random 256, random 256, random 256, random 256]
    --sdk-version/string=TEST-SDK-VERSION
    --pod-id/Uuid=TEST-POD-UUID:
  device-specific := ubjson.encode {
    "artemis.device": {
      "device_id": "$device-id",
      "organization_id": "$organization-id",
      "hardware_id": "$hardware-id",
    },
    "parts": ubjson.encode [{
      "from": 0,
      "to": 10,
      "hash": firmware-token,
    }],
    "sdk-version": sdk-version,
    "pod-id": pod-id.to-byte-array
  }
  return base64.encode (ubjson.encode {
    "device-specific": device-specific,
    "checksum": #[],
  })

build-encoded-firmware -> string
    --device/Device
    --sdk-version/string?=null
    --pod-id/Uuid?=null:
  return build-encoded-firmware
      --device-id=device.id
      --organization-id=device.organization-id
      --hardware-id=device.hardware-id
      --sdk-version=sdk-version
      --pod-id=pod-id

server-type-from-args args/List:
  args.do: | arg |
    if not arg.ends-with "-server": continue.do
    return arg[2..].trim --right "-server"
  return "http"

broker-type-from-args args/List:
  args.do: | arg |
    if not arg.ends-with "-broker": continue.do
    return arg[2..].trim --right "-broker"
  return "http"

random-uuid -> Uuid:
  return Uuid.uuid5 "random" "uuid $Time.now.ns-since-epoch $random"


class MigrationBroker:
  name/string
  test-broker/TestBroker
  done-latch/monitor.Latch

  constructor .name .test-broker .done-latch:

  close:
    done-latch.set true

class TestFleet:
  id/Uuid
  tester/Tester
  fleet-dir/string
  args/List
  devices/Map := {:}
  brokers_/List ::= []

  /**
  Creates a new test fleet.

  The $devices can be a list of $FakeDevice s.
  It is not recommended to mix these devices with other types of
    test devices (like host devices).
  */
  constructor --.id --.tester --.fleet-dir --.args --devices/List:
    devices.do: | device/FakeDevice |
      this.devices[device.alias-id] = device

  close:
    devices.do: | _ device/TestDevice |
      device.close
    brokers_.do: | broker/MigrationBroker |
      broker.close

  get-status -> List:
    return tester.run --json ["fleet", "status"]

  check-no-migration-stop:
    run --expect-exit-1 ["fleet", "migration", "stop"]

  upload-pod gold-name/string --format/string -> Uuid:
    return device-extract.upload-pod
        --fleet=this
        --gold-name=gold-name
        --format=format

  create-host-device name/string --start/bool -> TestDevicePipe:
    tar-file := "$tester.tmp-dir/dev-$(name).tar"
    added-device := tester.run --json [
      "fleet", "add-device", "--format", "tar", "-o", tar-file, "--name", name
    ]
    device-id := Uuid.parse added-device["id"]
    device-config := device-extract.TestDeviceConfig
        --device-id=device-id
        --format="tar"
        --path=tar-file

    test-device := tester.create-device
        --alias-id=device-id
        --hardware-id=device-id  // Not really used anyway.
        --device-config=device-config

    tester.replacements["$device-id"] = pad-replacement-id name

    if start:
      test-device.start
      test-device.wait-for-synchronized

    devices[device-id] = test-device
    return test-device as TestDevicePipe

  listen-to-serial-device -> TestDevicePipe
      --alias-id/Uuid
      --hardware-id/Uuid
      --serial-port/string:
    return tester.listen-to-serial-device
        --alias-id=alias-id
        --hardware-id=hardware-id
        --serial-port=serial-port

  /**
  Updates the parse position of all devices to be at the end
    of their current output.
  */
  update-device-output-positions -> none:
    devices.do --values: | device/TestDevice |
      device.update-output-pos

  /**
  Creates a new broker with the given name.
  */
  start-broker name/string -> MigrationBroker:
    started := monitor.Latch
    task::
      with-http-broker --name=name: | broker/TestBroker |
        cli-server-config.add-server-to-config broker.server-config --cli=tester.cli
        done := monitor.Latch
        result := MigrationBroker name broker done
        started.set result
        // Keep the server running until we are done.
        done.get
    result := started.get
    brokers_.add result
    return result

  run command/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true -> string:
    return tester.run --expect-exit-1=expect-exit-1 --allow-exception=allow-exception --quiet=quiet command

  run args/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true --json/bool -> any:
    return tester.run --expect-exit-1=expect-exit-1 --allow-exception=allow-exception --quiet=quiet --json=json args

  run-gold --expect-exit-1/bool=false --ignore-spacing/bool=false name/string description/string command/List -> none:
    tester.run-gold --expect-exit-1=expect-exit-1 --ignore-spacing=ignore-spacing name description command


with-fleet --args/List --count/int=0 [block]:
  with-tester --args=args: | tester/Tester |
    with-tmp-directory: | fleet-dir |
      os.env["ARTEMIS_FLEET"] = fleet-dir

      tester.replacements[fleet-dir] = "<FLEET_ROOT>"
      tester.login

      tester.run [
        "fleet",
        "init",
        "--organization-id", "$TEST-ORGANIZATION-UUID",
      ]

      fleet-file := read-json "$fleet-dir/fleet.json"
      fleet-id := fleet-file["id"]
      tester.replacements[fleet-id] = pad-replacement-id "FLEET_ID"

      identity-dir := "$fleet-dir/identities"
      directory.mkdir --recursive identity-dir
      tester.run [
        "fleet",
        "create-identities",
        "--output-directory", identity-dir,
        "$count",
      ]

      devices := read-json "$fleet-dir/devices.json"
      // Replace the names with something deterministic.
      counter := 0
      devices.do: | _ device |
        device["name"] = "name-$(counter++)"
      write-json-to-file "$fleet-dir/devices.json" devices --pretty

      ids := devices.keys
      expect-equals count ids.size

      fake-devices := []
      ids.do: | id/string |
        id-file := "$identity-dir/$(id).identity"
        expect (file.is-file id-file)
        contents := read-base64-ubjson id-file
        fake-device := tester.start-fake-device --identity=contents
        tester.replacements[id] = "-={| UUID-FOR-FAKE-DEVICE $(%05d fake-devices.size) |}=-"
        fake-devices.add fake-device

      fleet := TestFleet
          --id=(Uuid.parse fleet-id)
          --tester=tester
          --fleet-dir=fleet-dir
          --args=args
          --devices=fake-devices
      try:
        block.call fleet
      finally:
        fleet.close

expect-throws [--check-exception] [block]:
  exception := catch: block.call
  expect-not-null exception
  expect (check-exception.call exception)

expect-throws --contains/string [block]:
  expect-throws --check-exception=(: it.contains contains) block

deep-copy_ o/any -> any:
  if o is Map:
    return o.map: | _ value | deep-copy_ value
  if o is List:
    return o.map: deep-copy_ it
  return o

/**
Takes a string 'str' and returns a string that can be used as a replacement
  for an ID. That is, it has the same length as a UUID, and is visibly a UUID.
*/
pad-replacement-id str/string -> string:
  prefix := "-={|"
  suffix := "|}=-"
  total-chars := prefix.size + suffix.size + str.size
  padding := 36 - total-chars
  if padding < 0: throw "Replacement string too long: $str"
  left-padding := padding / 2
  right-padding := padding - left-padding
  return "$prefix$("~" * left-padding)$str$("~" * right-padding)$suffix"

check-resource-lock --args/List lock-type/string:
  args.do:
    if it.starts-with "--resource-locks=":
      resource-locks := it["--resource-locks=".size..].split ";"
      expect (resource-locks.contains lock-type)
      return
  throw "Expected --resource-locks=$lock-type"

make-lock-file-contents tests-dir/string -> string:
  // Hackish way to make the package file work with the pod file.
  // The build system already adds the .packages of the tests dir to the
  // environment variable TOIT_PACKAGE_CACHE_PATHS.
  lock-contents := (file.read-contents "package.lock").to-string
  lock-contents = lock-contents.replace --all "path: " "path: $tests-dir/"
  return lock-contents

write-lock-file --target-dir/string --tests-dir/string -> none:
  lock-contents := make-lock-file-contents tests-dir
  file.write-contents --path="$target-dir/package.lock" lock-contents
