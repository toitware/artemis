// Copyright (C) 2022 Toitware ApS. All rights reserved.

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
import net
import system
import uuid
import artemis.cli
import artemis.cli.server-config as cli-server-config
import artemis.cli.cache as cli
import artemis.cli.config as cli
import artemis.cli.cache as artemis-cache
import artemis.cli.utils show read-json write-json-to-file
import artemis.shared.server-config
import artemis.shared.version as configured-version
import artemis.service
import artemis.service.brokers.broker show BrokerConnection BrokerService
import artemis.service.device show Device
import artemis.service.storage show Storage
import artemis.cli.ui show ConsolePrinter JsonPrinter Ui Printer
import artemis.cli.utils show write-blob-to-file read-base64-ubjson
import ..tools.service-image-uploader.uploader as uploader
import monitor
import .artemis-server
import .broker
import .supabase-local-server

export Device

/** test@example.com is an admin of the $TEST-ORGANIZATION-UUID. */
TEST-EXAMPLE-COM-EMAIL ::= "test@example.com"
TEST-EXAMPLE-COM-PASSWORD ::= "password"
TEST-EXAMPLE-COM-UUID ::= uuid.parse "f76629c5-a070-4bbc-9918-64beaea48848"
TEST-EXAMPLE-COM-NAME ::= "Test User"

/** demo@example.com is a member of the $TEST-ORGANIZATION-UUID. */
DEMO-EXAMPLE-COM-EMAIL ::= "demo@example.com"
DEMO-EXAMPLE-COM-PASSWORD ::= "password"
DEMO-EXAMPLE-COM-UUID ::= uuid.parse "d9064bb5-1501-4ec9-bfee-21ab74d645b8"
DEMO-EXAMPLE-COM-NAME ::= "Demo User"

ADMIN-EMAIL ::= "test-admin@toit.io"
ADMIN-PASSWORD ::= "password"
ADMIN-UUID ::= uuid.parse "6ac69de5-7b56-4153-a31c-7b4e29bbcbcf"
ADMIN-NAME ::= "Admin User"

/** Preseeded "Test Organization". */
TEST-ORGANIZATION-NAME ::= "Test Organization"
TEST-ORGANIZATION-UUID ::= uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

/** Preseeded test device in $TEST-ORGANIZATION-UUID. */
TEST-DEVICE-UUID ::= uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
TEST-DEVICE-ALIAS ::= uuid.parse "191149e5-a95b-47b1-80dd-b149f953d272"

TEST-POD-UUID ::= uuid.parse "0e29c450-f802-49cc-b695-c5add71fdac3"

NON-EXISTENT-UUID ::= uuid.uuid5 "non" "existent"

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

with-tmp-config [block]:
  with-tmp-directory: | directory |
    config-path := "$directory/config"
    config := cli.read-config-file config-path --init=: it

    block.call config

class TestExit:

// TODO(florian): Maybe it's better to use a simplified version of the
//   the UI, so it's easier to match against it. We probably want the
//   default version of the console UI to be simpler anyway.

class TestPrinter extends ConsolePrinter:
  test-ui_/TestUi
  constructor .test-ui_ prefix/string?:
    super prefix

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.stdout += "$str\n"

class TestJsonPrinter extends JsonPrinter:
  test-ui_/TestUi

  constructor .test-ui_ prefix/string? level/int:
    super prefix level

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.stderr += "$str\n"

  handle-structured_ data:
    test-ui_.stdout += json.stringify data

class TestUi extends Ui:
  stdout/string := ""
  stderr/string := ""
  quiet_/bool
  json_/bool

  constructor --level/int=Ui.NORMAL-LEVEL --quiet/bool=true --json/bool=false:
    quiet_ = quiet
    json_ = json
    super --level=level

  create-printer_ prefix/string? level/int -> Printer:
    if json_: return TestJsonPrinter this prefix level
    return TestPrinter this prefix

  abort:
    throw TestExit

  wants-structured-result -> bool:
    return json_

class TestCli:
  config/cli.Config
  cache/cli.Cache
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

  constructor .config .cache .artemis .broker
      --toit-run-path/string
      --qemu-path/string?
      --.gold-name
      --.sdk-version
      --.tmp-dir:
    toit-run-path_ = toit-run-path
    qemu-path_ = qemu-path

  close:
    test-devices_.do: | device/TestDevice |
      device.close
      artemis.backdoor.remove-device device.hardware-id

  run args/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true -> string:
    return run args --expect-exit-1=expect-exit-1 --allow-exception=allow-exception --quiet=quiet --no-json

  run args/List --expect-exit-1/bool=false --allow-exception/bool=false --quiet/bool=true --json/bool -> any:
    ui := TestUi --quiet=quiet --json=json
    exception := null
    try:
      exception = catch --unwind=(: not expect-exit-1 or (not allow-exception and it is not TestExit)):
        cli.main args --config=config --cache=cache --ui=ui
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
    gold-content := (file.read-content gold-path).to-string
    // In case we are on Windows or something else introduced \r\n.
    gold-content = gold-content.replace --all "\r\n" "\n"

    if ignore-spacing:
      [" ", "┌", "─", "┬", "┐", "│", "├",  "┼", "┤", "└", "┴", "┘"].do: | char |
        gold-content = gold-content.replace --all char ""
        output = output.replace --all char ""
    if gold-content != output:
      print "Gold file '$gold-path' does not match output."
      print "Output:"
      print output
      print "Gold:"
      print gold-content
      print "gold_content.size: $gold-content.size"
      print "output.size: $output.size"
      for i := 0; i < (min output.size gold-content.size); i++:
        if output[i] != gold-content[i]:
          print "First difference at $i $output[i] != $gold-content[i]."
          break
    expect-equals gold-content output

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
  start-device -> TestDevice
      --organization-id/uuid.Uuid=TEST-ORGANIZATION-UUID
      --firmware-token/ByteArray?=null:
    device-description := create-device_ organization-id firmware-token
    hardware-id/uuid.Uuid := device-description["id"]
    alias-id/uuid.Uuid := device-description["alias"]
    encoded-firmware := device-description["encoded_firmware"]

    result := TestDevicePipe.fake-host
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --toit-run=toit-run-path_
        --encoded-firmware=encoded-firmware
    test-devices_.add result
    return result

  start-device -> TestDevice
      --alias-id/uuid.Uuid
      --hardware-id/uuid.Uuid
      --qemu-image
      --organization-id=TEST-ORGANIZATION-UUID:
    result := TestDevicePipe.qemu
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --image-path=qemu-image
        --toit-run=toit-run-path_
        --qemu-path=qemu-path_
    test-devices_.add result
    return result

  listen-to-serial-device -> TestDevice
      --alias-id/uuid.Uuid
      --hardware-id/uuid.Uuid
      --serial-port/string:
    result := TestDevicePipe.serial
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --serial-port=serial-port
        --toit-run=toit-run-path_
    test-devices_.add result
    return result

  start-fake-device -> FakeDevice
      --organization-id/uuid.Uuid=TEST-ORGANIZATION-UUID
      --firmware-token/ByteArray?=null:
    device-description := create-device_ organization-id firmware-token
    hardware-id/uuid.Uuid := device-description["id"]
    alias-id/uuid.Uuid := device-description["alias"]
    encoded-firmware := device-description["encoded_firmware"]

    result := FakeDevice
        --broker=broker
        --alias-id=alias-id
        --hardware-id=hardware-id
        --organization-id=TEST-ORGANIZATION-UUID
        --encoded-firmware=encoded-firmware
    test-devices_.add result
    return result

  start-fake-device --identity/Map --firmware-token/ByteArray?=null -> FakeDevice:
    device-description := identity["artemis.device"]
    hardware-id/uuid.Uuid := uuid.parse device-description["hardware_id"]
    alias-id/uuid.Uuid := uuid.parse device-description["device_id"]
    organization-id/uuid.Uuid := uuid.parse device-description["organization_id"]

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
    test-devices_.add result
    return result

  create-device_ organization-id/uuid.Uuid firmware-token/ByteArray?=null -> Map:
    device-description := artemis.backdoor.create-device --organization-id=organization-id
    hardware-id/uuid.Uuid := device-description["id"]
    alias-id/uuid.Uuid := device-description["alias"]
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
    with-tmp-directory: | admin-tmp-dir |
      admin-config := cli.Config "$admin-tmp-dir/config" (deep-copy_ config.data)
      ui := TestUi
      cli.main --config=admin-config --cache=cache --ui=ui [
            "auth", "login",
            "--email", ADMIN-EMAIL,
            "--password", ADMIN-PASSWORD,
          ]
      uploader.main
          --config=admin-config
          --cache=cache
          --ui=ui
          [
            "service",
            "--sdk-version", sdk-version,
            "--service-version", artemis-version,
            "--force",
            "--local"
          ]

abstract class TestDevice:
  hardware-id/uuid.Uuid
  alias-id/uuid.Uuid
  organization-id/uuid.Uuid
  broker/TestBroker

  constructor --.broker --.hardware-id --.alias-id --.organization-id:

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
  abstract wait-for needle/string --start-at/int --not-followed-by/string?=null -> int

  wait-for-synchronized --start-at/int -> int:
    return wait-for "[artemis.synchronize] INFO: synchronized" --start-at=start-at --not-followed-by=" state"

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
      --hardware-id/uuid.Uuid
      --alias-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --encoded-firmware/string:
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
    super --broker=broker --hardware-id=hardware-id --alias-id=alias-id --organization-id=organization-id
  close:
    if network_:
      network_.close
      network_ = null

  output -> string:
    throw "UNIMPLEMENTED"

  clear-output -> none:
    throw "UNIMPLEMENTED"

  wait-for needle/string --start-at/int --not-followed-by/string?=null -> int:
    throw "UNIMPLEMENTED"

  wait-until-connected --timeout=(Duration --ms=5_000) -> none:
    return

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

class TestDevicePipe extends TestDevice:
  output_/ByteArray := #[]
  child-process_/any := null
  signal_ := monitor.Signal
  stdout-task_/Task? := null
  stderr-task_/Task? := null

  constructor.fake-host
      --broker/TestBroker
      --hardware-id/uuid.Uuid
      --alias-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --encoded-firmware/string
      --toit-run/string:

    broker-config-json := broker.server-config.to-json --der-serializer=: unreachable
    encoded-broker-config := json.stringify broker-config-json

    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id

    flags := [
      "test-device.toit",
      "--hardware-id=$hardware-id",
      "--alias-id=$alias-id",
      "--organization-id=$organization-id",
      "--encoded-firmware=$encoded-firmware",
      "--broker-config-json=$encoded-broker-config",
    ]
    fork_ toit-run flags

  constructor.serial
      --broker/TestBroker
      --hardware-id/uuid.Uuid
      --alias-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --serial-port/string
      --toit-run/string:
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id

    flags := [
      "test-device-serial.toit",
      "--port", serial-port
    ]
    fork_ toit-run flags

  constructor.qemu
        --broker/TestBroker
        --hardware-id/uuid.Uuid
        --alias-id/uuid.Uuid
        --organization-id/uuid.Uuid
        --image-path/string
        --toit-run/string
        --qemu-path/string:
    super
        --broker=broker
        --hardware-id=hardware-id
        --alias-id=alias-id
        --organization-id=organization-id

    flags := [
      "-L", (fs.dirname qemu-path),
      "-M", "esp32",
      "-nographic",
      "-drive", "file=$image-path,format=raw,if=mtd",
      "-nic", "user,model=open_eth",
    ]
    fork_ qemu-path flags

  fork_ exe flags:
    fork-data := pipe.fork
        true                // use_path
        // We create a stdin pipe, so that qemu can't interfere with
        // our terminal.
        pipe.PIPE-CREATED   // stdin.
        pipe.PIPE-CREATED   // stdout
        pipe.PIPE-CREATED   // stderr
        exe
        [exe] + flags
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
          while chunk := stdout.read:
            output_ += chunk
            print-on-stderr_ "STDOUT: '$chunk.to-string-non-throwing'"
            signal_.raise
      finally:
        stdout.close

    stderr-task_ = task --background::
      try:
        catch --trace:
          while chunk := stderr.read:
            output_ += chunk
            print-on-stderr_ "STDERR: '$chunk.to-string-non-throwing'"
            signal_.raise
      finally:
        stderr.close

  close:
    critical-do:
      if stdout-task_:
        stdout-task_.cancel
        stdout-task_ = null
      if stderr-task_:
        stderr-task_.cancel
        stderr-task_ = null
      if child-process_:
        SIGKILL ::= 9
        pipe.kill_ child-process_ SIGKILL
        child-process_ = null

  output -> string:
    return output_.to-string-non-throwing

  clear-output -> none:
    output_ = #[]

  wait-for needle/string --start-at/int --not-followed-by/string?=null -> int:
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
        return index + needle.size
    unreachable

/**
Starts the artemis server and broker.

Calls the given $block with a $TestCli instance and a $Device or null.

If the type is supabase, uses the running supabase instances. Otherwise,
  creates fresh instances of the brokers.

If the $args parameter contains a '--toit-run=...' argument, it is
  used to launch devices.
*/
with-test-cli
    --args/List
    --artemis-type=(server-type-from-args args)
    --broker-type=(broker-type-from-args args)
    --logger/log.Logger=log.default
    --gold-name/string?=null
    [block]:
  with-artemis-server --args=args --type=artemis-type: | artemis-server |
    with-test-cli
        --artemis-server=artemis-server
        broker-type
        --logger=logger
        --args=args
        --gold-name=gold-name
        block

with-test-cli
    --artemis-server/TestArtemisServer
    broker-type
    --logger/log.Logger
    --args/List
    --gold-name/string?
    [block]:
  with-broker --args=args --type=broker-type --logger=logger: | broker/TestBroker |
    with-test-cli
        --artemis-server=artemis-server
        --broker=broker
        --logger=logger
        --args=args
        --gold-name=gold-name
        block

with-test-cli
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
    config := cli.read-config-file config-file --init=: it
    cache-dir := "$tmp-dir/CACHE"
    directory.mkdir cache-dir
    cache := cli.Cache --app-name="artemis-test" --path=cache-dir

    SDK-VERSION-OPTION ::= "--sdk-version="
    SDK-PATH-OPTION ::= "--sdk-path="
    ENVELOPE-PATH-ESP32-OPTION ::= "--envelope-esp32-path="
    ENVELOPE-PATH-ESP32-QEMU-OPTION ::= "--envelope-esp32-qemu-path="

    sdk-version := "v0.0.0"
    sdk-path/string? := null
    envelope-esp32-path/string? := null
    envelope-esp32-qemu-path/string? := null
    args.do: | arg/string |
      if arg.starts-with SDK-VERSION-OPTION:
        sdk-version = arg[SDK-VERSION-OPTION.size ..]
      else if arg.starts-with SDK-PATH-OPTION:
        sdk-path = arg[SDK-PATH-OPTION.size ..]
      else if arg.starts-with ENVELOPE-PATH-ESP32-OPTION:
        envelope-esp32-path = arg[ENVELOPE-PATH-ESP32-OPTION.size ..]
      else if arg.starts-with ENVELOPE-PATH-ESP32-QEMU-OPTION:
        envelope-esp32-qemu-path = arg[ENVELOPE-PATH-ESP32-QEMU-OPTION.size ..]

    if sdk-version == "" or not sdk-path or not envelope-esp32-path or not envelope-esp32-qemu-path:
      print "Missing SDK version, SDK path or envelope path."
      exit 1
    TEST-SDK-VERSION = sdk-version

    // Prefill the cache with the Dev SDK from the Makefile.
    sdk-key := "$artemis-cache.SDK-PATH/$sdk-version"
    cache.get-directory-path sdk-key: | store/cli.DirectoryStore |
      store.copy sdk-path

    ENVELOPES-URL ::= "github.com/toitlang/envelopes/releases/download/$sdk-version"
    envelope-key := "$artemis-cache.ENVELOPE-PATH/$ENVELOPES-URL/firmware-esp32.envelope.gz/firmware.envelope"
    cache.get-file-path envelope-key: | store/cli.FileStore |
      print "Caching envelope: $envelope-esp32-path"
      store.copy envelope-esp32-path
    envelope-key = "$artemis-cache.ENVELOPE-PATH/$ENVELOPES-URL/firmware-esp32-qemu.envelope.gz/firmware.envelope"
    cache.get-file-path envelope-key: | store/cli.FileStore |
      print "Caching envelope: $envelope-esp32-qemu-path"
      store.copy envelope-esp32-qemu-path

    artemis-config := artemis-server.server-config
    broker-config := broker.server-config
    cli-server-config.add-server-to-config config artemis-config
    cli-server-config.add-server-to-config config broker-config

    artemis-task/Task? := null

    if not gold-name:
      toit-file := system.program-name
      last-separator := max (toit-file.index-of --last "/") (toit-file.index-of --last "\\")
      gold-name = toit-file[last-separator + 1 ..].trim --right ".toit"
      gold-name = gold-name.trim --right "_slow"

    test-cli := TestCli config cache artemis-server broker
        --toit-run-path=toit-run-path
        --qemu-path=qemu-path
        --gold-name=gold-name
        --sdk-version=sdk-version
        --tmp-dir=tmp-dir

    test-cli.replacements[tmp-dir] = "TMP_DIR"
    test-cli.replacements[TEST-SDK-VERSION] = "TEST_SDK_VERSION"
    test-cli.replacements[TEST-ARTEMIS-VERSION] = "TEST_ARTEMIS_VERSION"

    try:
      test-cli.run ["config", "broker", "--artemis", "default", artemis-config.name]
      test-cli.run ["config", "broker", "default", broker-config.name]
      block.call test-cli
    finally:
      test-cli.close
      if artemis-task: artemis-task.cancel
      directory.rmdir --recursive cache-dir

build-encoded-firmware -> string
    --device-id/uuid.Uuid
    --organization-id/uuid.Uuid=TEST-ORGANIZATION-UUID
    --hardware-id/uuid.Uuid=device-id
    --firmware-token/ByteArray=#[random 256, random 256, random 256, random 256]
    --sdk-version/string=TEST-SDK-VERSION
    --pod-id/uuid.Uuid=TEST-POD-UUID:
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
    --pod-id/uuid.Uuid?=null:
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

random-uuid -> uuid.Uuid:
  return uuid.uuid5 "random" "uuid $Time.now.ns-since-epoch $random"

with-fleet --args/List --count/int [block]:
  with-test-cli --args=args: | test-cli/TestCli |
    with-tmp-directory: | fleet-dir |
      os.env["ARTEMIS_FLEET"] = fleet-dir

      test-cli.replacements[fleet-dir] = "<FLEET_ROOT>"
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

      test-cli.run [
        "fleet",
        "init",
        "--organization-id", "$TEST-ORGANIZATION-UUID",
      ]

      fleet-file := read-json "$fleet-dir/fleet.json"
      test-cli.replacements[fleet-file["id"]] = pad-replacement-id "FLEET_ID"

      identity-dir := "$fleet-dir/identities"
      directory.mkdir --recursive identity-dir
      test-cli.run [
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
        content := read-base64-ubjson id-file
        fake-device := test-cli.start-fake-device --identity=content
        test-cli.replacements[id] = "-={| UUID-FOR-FAKE-DEVICE $(%05d fake-devices.size) |}=-"
        fake-devices.add fake-device

      block.call test-cli fake-devices fleet-dir

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

make-lock-file-content tests-dir/string -> string:
  // Hackish way to make the package file work with the pod file.
  // The build system already adds the .packages of the tests dir to the
  // environment variable TOIT_PACKAGE_CACHE_PATHS.
  lock-content := (file.read-content "package.lock").to-string
  lock-content = lock-content.replace --all "path: " "path: $tests-dir/"
  return lock-content

write-lock-file --target-dir/string --tests-dir/string -> none:
  lock-content := make-lock-file-content tests-dir
  file.write-content --path="$target-dir/package.lock" lock-content
