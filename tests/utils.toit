// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.json
import encoding.ubjson
import expect show *
import log
import host.directory
import host.pipe
import host.file
import host.os
import net
import uuid
import artemis.cli
import artemis.cli.server_config as cli_server_config
import artemis.cli.cache as cli
import artemis.cli.config as cli
import artemis.cli.cache as artemis_cache
import artemis.cli.utils show read_json write_json_to_file
import artemis.shared.server_config
import artemis.service
import artemis.service.brokers.broker show ResourceManager BrokerService
import artemis.service.device show Device
import artemis.cli.ui show ConsolePrinter ConsoleUi Ui
import artemis.cli.utils show write_blob_to_file read_base64_ubjson
import ..tools.http_servers.broker as http_servers
import ..tools.http_servers.artemis_server as http_servers
import monitor
import .artemis_server
import .broker
import .supabase_local_server

export Device

/** test@example.com is an admin of the $TEST_ORGANIZATION_UUID. */
TEST_EXAMPLE_COM_EMAIL ::= "test@example.com"
TEST_EXAMPLE_COM_PASSWORD ::= "password"
TEST_EXAMPLE_COM_UUID ::= uuid.parse "f76629c5-a070-4bbc-9918-64beaea48848"
TEST_EXAMPLE_COM_NAME ::= "Test User"

/** demo@example.com is a member of the $TEST_ORGANIZATION_UUID. */
DEMO_EXAMPLE_COM_EMAIL ::= "demo@example.com"
DEMO_EXAMPLE_COM_PASSWORD ::= "password"
DEMO_EXAMPLE_COM_UUID ::= uuid.parse "d9064bb5-1501-4ec9-bfee-21ab74d645b8"
DEMO_EXAMPLE_COM_NAME ::= "Demo User"

ADMIN_EMAIL ::= "test-admin@toit.io"
ADMIN_PASSWORD ::= "password"
ADMIN_UUID ::= uuid.parse "6ac69de5-7b56-4153-a31c-7b4e29bbcbcf"
ADMIN_NAME ::= "Admin User"

/** Preseeded "Test Organization". */
TEST_ORGANIZATION_NAME ::= "Test Organization"
TEST_ORGANIZATION_UUID ::= uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

/** Preseeded test device in $TEST_ORGANIZATION_UUID. */
TEST_DEVICE_UUID ::= uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
TEST_DEVICE_ALIAS ::= uuid.parse "191149e5-a95b-47b1-80dd-b149f953d272"

TEST_POD_UUID ::= uuid.parse "0e29c450-f802-49cc-b695-c5add71fdac3"

NON_EXISTENT_UUID ::= uuid.uuid5 "non" "existent"

UPDATE_GOLD_ENV ::= "UPDATE_GOLD"

with_tmp_directory [block]:
  tmp_dir := directory.mkdtemp "/tmp/artemis-test-"
  try:
    block.call tmp_dir
  finally:
    directory.rmdir --recursive tmp_dir

with_tmp_config [block]:
  with_tmp_directory: | directory |
    config_path := "$directory/config"
    config := cli.read_config_file config_path --init=: it

    block.call config

/**
Starts a local http broker and calls the given $block with a
  $server_config.ServerConfig as argument.
*/
with_http_broker [block]:
  broker := http_servers.HttpBroker 0
  port_latch := monitor.Latch
  broker_task := task:: broker.start port_latch

  server_config := server_config.ServerConfigHttpToit "test-broker"
      --host="localhost"
      --port=port_latch.get
  try:
    block.call server_config
  finally:
    broker.close
    broker_task.cancel

class TestExit:

// TODO(florian): Maybe it's better to use a simplified version of the
//   the UI, so it's easier to match against it. We probably want the
//   default version of the console UI to be simpler anyway.

class TestPrinter extends ConsolePrinter:
  test_ui_/TestUi
  constructor .test_ui_ prefix/string?:
    super prefix

  print_ str/string:
    if not test_ui_.quiet_: super str
    test_ui_.stdout += "$str\n"

class TestUi extends ConsoleUi:
  stdout/string := ""
  quiet_/bool

  constructor --level/int=Ui.NORMAL_LEVEL --quiet/bool=true:
    quiet_ = quiet
    super --level=level

  create_printer_ prefix/string? level/int -> TestPrinter:
    return TestPrinter this prefix

  abort:
    throw TestExit

class TestCli:
  config/cli.Config
  cache/cli.Cache
  artemis/TestArtemisServer
  broker/TestBroker
  toit_run_/string
  test_devices_/List ::= []
  /** A map of strings to be replaced in the output of $run. */
  replacements/Map ::= {:}
  gold_name/string
  sdk_version/string
  tmp_dir/string

  constructor .config .cache .artemis .broker
      --toit_run/string
      --.gold_name
      --.sdk_version
      --.tmp_dir:
    toit_run_ = toit_run

  close:
    test_devices_.do: | device/TestDevice |
      device.close
      artemis.backdoor.remove_device device.hardware_id

  run args/List --expect_exit_1/bool=false --quiet/bool=true -> string:
    ui := TestUi --quiet=quiet
    exception := null
    try:
      exception = catch --unwind=(: not expect_exit_1 or it is not TestExit):
        cli.main args --config=config --cache=cache --ui=ui
    finally: | is_exception _ |
      if is_exception:
        print ui.stdout

    if expect_exit_1 and not exception:
      throw "Expected exit 1, but got exit 0"
    result := ui.stdout
    return result

  /**
  Variant of $(run_gold test_name description args [--before_gold]).
  */
  run_gold
      test_name/string
      description/string
      args/List
      --ignore_spacing/bool=false
      --expect_exit_1/bool=false:
    run_gold test_name
        description
        args
        --expect_exit_1=expect_exit_1
        --ignore_spacing=ignore_spacing
        --before_gold=: it

  /**
  Runs the CLI with the given $args.

  The $test_name is used as filename for the gold file.
  The $description is embedded in the output of the gold file.

  If $expect_exit_1 then the test is negative and must fail.

  If $ignore_spacing is true, then all whitespace is ignored when comparing.
    Also, all table characters (like "┌────┬────────┐") are ignored.

  The $before_gold block is called with the output of the running the command.
    It must return a new output (or the same as the input). It can be used
    to update the $replacements.
  */
  run_gold
      test_name/string
      description/string
      args/List
      --ignore_spacing/bool=false
      --expect_exit_1/bool=false
      [--before_gold]:
    output := run args --expect_exit_1=expect_exit_1
    output = before_gold.call output
    output = canonicalize_gold_ output args --description=description
    gold_path := "gold/$gold_name/$(test_name).txt"
    if os.env.get UPDATE_GOLD_ENV or not file.is_file gold_path:
      directory.mkdir --recursive "gold/$gold_name"
      write_blob_to_file gold_path output
      print "Updated gold file '$gold_path'."
    gold_content := (file.read_content gold_path).to_string
    // In case we are on Windows or something else introduced \r\n.
    gold_content = gold_content.replace --all "\r\n" "\n"

    if ignore_spacing:
      [" ", "┌", "─", "┬", "┐", "│", "├",  "┼", "┤", "└", "┴", "┘"].do: | char |
        gold_content = gold_content.replace --all char ""
        output = output.replace --all char ""
    if gold_content != output:
      print "Gold file '$gold_path' does not match output."
      print "Output:"
      print output
      print "Gold:"
      print gold_content
      print "gold_content.size: $gold_content.size"
      print "output.size: $output.size"
      for i := 0; i < (min output.size gold_content.size); i++:
        if output[i] != gold_content[i]:
          print "First difference at $i $output[i] != $gold_content[i]."
          break
    expect_equals gold_content output

  canonicalize_gold_ output/string args --description/string -> string:
    result := "# $description\n# $args\n$output"
    replacements.do: | key val|
      result = result.replace --all key val
    result = result.replace --all "\r\n" "\n"
    return result

  /**
  Creates and starts new device in the given $organization_id.
  Neither the 'check-in', nor the firmware service are set up.

  The $firmware_token is used to build the encoded firmware.
  By default a random token is used.
  */
  start_device -> TestDevice
      --organization_id/uuid.Uuid=TEST_ORGANIZATION_UUID
      --firmware_token/ByteArray?=null:
    device_description := create_device_ organization_id firmware_token
    hardware_id/uuid.Uuid := device_description["id"]
    alias_id/uuid.Uuid := device_description["alias"]
    encoded_firmware := device_description["encoded_firmware"]

    result := TestDevicePipe
        --broker=broker
        --alias_id=alias_id
        --hardware_id=hardware_id
        --organization_id=TEST_ORGANIZATION_UUID
        --toit_run=toit_run_
        --encoded_firmware=encoded_firmware
    test_devices_.add result
    return result

  start_fake_device -> FakeDevice
      --organization_id/uuid.Uuid=TEST_ORGANIZATION_UUID
      --firmware_token/ByteArray?=null:
    device_description := create_device_ organization_id firmware_token
    hardware_id/uuid.Uuid := device_description["id"]
    alias_id/uuid.Uuid := device_description["alias"]
    encoded_firmware := device_description["encoded_firmware"]

    result := FakeDevice
        --broker=broker
        --alias_id=alias_id
        --hardware_id=hardware_id
        --organization_id=TEST_ORGANIZATION_UUID
        --encoded_firmware=encoded_firmware
    test_devices_.add result
    return result

  start_fake_device --identity/Map --firmware_token/ByteArray?=null -> FakeDevice:
    device_description := identity["artemis.device"]
    hardware_id/uuid.Uuid := uuid.parse device_description["hardware_id"]
    alias_id/uuid.Uuid := uuid.parse device_description["device_id"]
    organization_id/uuid.Uuid := uuid.parse device_description["organization_id"]

    encoded_firmware := build_encoded_firmware
        --firmware_token=firmware_token
        --device_id=alias_id
        --organization_id=TEST_ORGANIZATION_UUID
        --hardware_id=hardware_id

    result := FakeDevice
        --broker=broker
        --alias_id=alias_id
        --hardware_id=hardware_id
        --organization_id=organization_id
        --encoded_firmware=encoded_firmware
    test_devices_.add result
    return result

  create_device_ organization_id/uuid.Uuid firmware_token/ByteArray?=null -> Map:
    device_description := artemis.backdoor.create_device --organization_id=organization_id
    hardware_id/uuid.Uuid := device_description["id"]
    alias_id/uuid.Uuid := device_description["alias"]
    initial_state := {
      "identity": {
        "device_id": "$alias_id",
        "organization_id": "$organization_id",
        "hardware_id": "$hardware_id",
      }
    }

    broker.backdoor.create_device --device_id=alias_id --state=initial_state

    encoded_firmware := build_encoded_firmware
        --firmware_token=firmware_token
        --device_id=alias_id
        --organization_id=TEST_ORGANIZATION_UUID
        --hardware_id=hardware_id

    device_description["encoded_firmware"] = encoded_firmware

    return device_description

abstract class TestDevice:
  hardware_id/uuid.Uuid
  alias_id/uuid.Uuid
  organization_id/uuid.Uuid
  broker/TestBroker

  constructor --.broker --.hardware_id --.alias_id --.organization_id:

  /**
  Closes the test device and releases all resources.
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
  abstract clear_output -> none

  /**
  Waits for a specific $needle in the output.
  */
  abstract wait_for needle/string -> none

  /**
  Waits until the device has connected to the broker.

  Periodically queries the broker to see whether the device has
    reported its state.
  */
  wait_until_connected --timeout=(Duration --ms=5_000) -> none:
      // Wait until the device has reported its state.
      with_timeout timeout:
        while true:
          state := broker.backdoor.get_state alias_id
          // The initial state has the field "identity" in it.
          if not state.contains "identity": break
          sleep --ms=100

class FakeDevice extends TestDevice:
  device_/Device := ?
  pending_state_/Map? := null
  goal_state/Map? := null
  network_/net.Client? := ?

  constructor
      --broker/TestBroker
      --hardware_id/uuid.Uuid
      --alias_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --encoded_firmware/string:
    network_ = net.open
    firmware_state := {
      "firmware": encoded_firmware
    }
    device_ = Device
        --id=alias_id
        --hardware_id=hardware_id
        --organization_id=organization_id
        --firmware_state=firmware_state
    super --broker=broker --hardware_id=hardware_id --alias_id=alias_id --organization_id=organization_id
  close:
    if network_:
      network_.close
      network_ = null

  output -> string:
    throw "UNIMPLEMENTED"

  clear_output -> none:
    throw "UNIMPLEMENTED"

  wait_for needle/string -> none:
    throw "UNIMPLEMENTED"

  wait_until_connected --timeout=(Duration --ms=5_000) -> none:
    return

  with_resources_ [block]:
    broker.with_service: | service/BrokerService |
      resources := service.connect --device=device_ --network=network_
      try:
        block.call resources
      finally:
        resources.close

  /**
  Reports the state to the broker.

  Basically a copy of `report_state` of the synchronize library.
  */
  report_state:
    state := {
      "firmware-state": device_.firmware_state,
    }
    if device_.pending_firmware:
      state["pending-firmware"] = device_.pending_firmware
    if device_.is_current_state_modified:
      state["current-state"] = device_.current_state
    if goal_state:
      state["goal-state"] = goal_state

    with_resources_: | resources/ResourceManager |
      resources.report_state state

  /**
  Synchronizes with the broker.
  Use $flash to simulate flashing the goal.
  */
  synchronize:
    with_resources_: | resources/ResourceManager |
      goal_state = resources.fetch_goal --no-wait

  /**
  Simulates flashing the goal state.
  */
  flash:
    if not goal_state: return
    pending_state_ = goal_state
    device_.pending_firmware = pending_state_["firmware"]

  /**
  Simulates a reboot, thus making the pending state the firmware state.
  */
  reboot:
    if not pending_state_: return
    // We can't change the firmware state (final variable).
    // Replace the whole device object.
    device_ = Device
        --id=alias_id
        --hardware_id=hardware_id
        --organization_id=organization_id
        --firmware_state=pending_state_
    pending_state_ = null

class TestDevicePipe extends TestDevice:
  chunks_/List := []  // Of bytearrays.
  child_process_/any := ?
  signal_ := monitor.Signal
  stdout_task_/Task? := null
  stderr_task_/Task? := null

  constructor
      --broker/TestBroker
      --hardware_id/uuid.Uuid
      --alias_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --encoded_firmware/string
      --toit_run/string:

    broker_config_json := broker.server_config.to_json --der_serializer=: unreachable
    encoded_broker_config := json.stringify broker_config_json
    flags := [
      "test_device.toit",
      "--hardware-id=$hardware_id",
      "--alias-id=$alias_id",
      "--organization-id=$organization_id",
      "--encoded-firmware=$encoded_firmware",
      "--broker-config-json=$encoded_broker_config",
    ]
    fork_data := pipe.fork
        true                // use_path
        pipe.PIPE_INHERITED // stdin
        pipe.PIPE_CREATED   // stdout
        pipe.PIPE_CREATED   // stderr
        toit_run
        [toit_run] + flags
    stdout := fork_data[1]
    stderr := fork_data[2]
    child_process_ = fork_data[3]
    super
        --broker=broker
        --hardware_id=hardware_id
        --alias_id=alias_id
        --organization_id=organization_id

    // We are listening to both stdout and stderr.
    // We expect only one to be really used. Otherwise, looking for
    // specific strings in the output might not work, as the stdout and
    // stderr could be interleaved.

    stdout_task_ = task --background::
      catch --trace:
        while chunk := stdout.read:
          chunks_.add chunk
          print_on_stderr_ "STDOUT: $chunk.to_string_non_throwing"
          signal_.raise

    stderr_task_ = task --background::
      catch --trace:
        while chunk := stderr.read:
          chunks_.add chunk
          print_on_stderr_ "STDERR: $chunk.to_string_non_throwing"
          signal_.raise

  close:
    critical_do:
      if stdout_task_:
        stdout_task_.cancel
        stdout_task_ = null
      if stderr_task_:
        stderr_task_.cancel
        stderr_task_ = null
      if child_process_:
        SIGKILL ::= 9
        pipe.kill_ child_process_ SIGKILL
        child_process_ = null

  build_string_from_output_ --from/int -> string:
    input := chunks_[from..]
    total_size := input.reduce --initial=0: | a b/ByteArray | a + b.size
    buffer := ByteArray total_size
    offset := 0
    input.do: | chunk/ByteArray |
      buffer.replace offset chunk
      offset += chunk.size
    return buffer.to_string_non_throwing

  output -> string:
    return build_string_from_output_ --from=0

  clear_output -> none:
    chunks_ = []

  wait_for needle/string -> none:
    last_end := 0
    signal_.wait:
      start_index := chunks_.size - 1
      accumulated_size := chunks_[start_index].size

      // The string we are looking for could have been split at the
      // boundary of this and the previous chunk.
      if start_index > 0:
        start_index--
        accumulated_size += chunks_[start_index].size

      // Continue adding prefixes, if the needle is bigger than the
      // accumulated string.
      while start_index > 0 and  accumulated_size < needle.size:
        start_index--
        accumulated_size += chunks_[start_index].size

      start_index = min last_end start_index

      if accumulated_size >= needle.size:
        last_end = chunks_.size
        str := build_string_from_output_ --from=start_index
        str.contains needle
      else:
        false

/**
Starts the artemis server and broker.

Calls the given $block with a $TestCli instance and a $Device or null.

If the type is supabase, uses the running supabase instances. Otherwise,
  creates fresh instances of the brokers.

If the $args parameter contains a '--toit-run=...' argument, it is
  used to launch devices.
*/
with_test_cli
    --args/List
    --artemis_type=(server_type_from_args args)
    --broker_type=(broker_type_from_args args)
    --logger/log.Logger=log.default
    --gold_name/string?=null
    [block]:
  with_artemis_server --type=artemis_type: | artemis_server |
    with_test_cli
        --artemis_server=artemis_server
        broker_type
        --logger=logger
        --args=args
        --gold_name=gold_name
        block

with_test_cli
    --artemis_server/TestArtemisServer
    broker_type
    --logger/log.Logger
    --args/List
    --gold_name/string?
    [block]:
  with_broker --type=broker_type --logger=logger: | broker/TestBroker |
    with_test_cli
        --artemis_server=artemis_server
        --broker=broker
        --logger=logger
        --args=args
        --gold_name=gold_name
        block

with_test_cli
    --artemis_server/TestArtemisServer
    --broker/TestBroker
    --logger/log.Logger
    --args/List
    --gold_name/string?
    [block]:

  // Use 'toit.run' (or 'toit.run.exe' on Windows), unless there is an
  // argument `--toit-run=...`.
  toit_run := platform == PLATFORM_WINDOWS ? "toit.run.exe" : "toit.run"
  prefix := "--toit-run="
  for i := 0; i < args.size; i++:
    arg := args[i]
    if arg.starts_with prefix:
      toit_run = arg[prefix.size..]
      break  // Use the first occurrence.

  with_tmp_directory: | tmp_dir |
    config_file := "$tmp_dir/config"
    config := cli.read_config_file config_file --init=: it
    cache_dir := "$tmp_dir/CACHE"
    directory.mkdir cache_dir
    cache := cli.Cache --app_name="artemis-test" --path=cache_dir

    SDK_VERSION_OPTION ::= "--sdk-version="
    SDK_PATH_OPTION ::= "--sdk-path="
    ENVELOPE_PATH_OPTION ::= "--envelope-path="

    sdk_version := "v0.0.0"
    sdk_path/string? := null
    envelope_path/string? := null
    args.do: | arg/string |
      if arg.starts_with SDK_VERSION_OPTION:
        sdk_version = arg[SDK_VERSION_OPTION.size ..]
      else if arg.starts_with SDK_PATH_OPTION:
        sdk_path = arg[SDK_PATH_OPTION.size ..]
      else if arg.starts_with ENVELOPE_PATH_OPTION:
        envelope_path = arg[ENVELOPE_PATH_OPTION.size ..]

    if sdk_version == "" or sdk_path == null or envelope_path == null:
      print "Missing SDK version, SDK path or envelope path."
      exit 1

    // Prefill the cache with the Dev SDK from the Makefile.
    sdk_key := "$artemis_cache.SDK_PATH/$sdk_version"
    cache.get_directory_path sdk_key: | store/cli.DirectoryStore |
      store.copy sdk_path

    envelope_key := "$artemis_cache.ENVELOPE_PATH/$sdk_version/firmware-esp32.envelope"
    cache.get_file_path envelope_key: | store/cli.FileStore |
      store.copy envelope_path

    artemis_config := artemis_server.server_config
    broker_config := broker.server_config
    cli_server_config.add_server_to_config config artemis_config
    cli_server_config.add_server_to_config config broker_config

    artemis_task/Task? := null

    if not gold_name:
      toit_file := program_name
      last_separator := max (toit_file.index_of --last "/") (toit_file.index_of --last "\\")
      gold_name = program_name[last_separator + 1 ..].trim --right ".toit"

    test_cli := TestCli config cache artemis_server broker
        --toit_run=toit_run
        --gold_name=gold_name
        --sdk_version=sdk_version
        --tmp_dir=tmp_dir
    try:
      test_cli.run ["config", "broker", "--artemis", "default", artemis_config.name]
      test_cli.run ["config", "broker", "default", broker_config.name]
      block.call test_cli
    finally:
      test_cli.close
      if artemis_task: artemis_task.cancel
      directory.rmdir --recursive cache_dir

build_encoded_firmware -> string
    --device_id/uuid.Uuid
    --organization_id/uuid.Uuid=TEST_ORGANIZATION_UUID
    --hardware_id/uuid.Uuid=device_id
    --firmware_token/ByteArray=#[random 256, random 256, random 256, random 256]
    --sdk_version/string="v2.0.0-alpha.52"
    --pod_id/uuid.Uuid=TEST_POD_UUID:
  device_specific := ubjson.encode {
    "artemis.device": {
      "device_id": "$device_id",
      "organization_id": "$organization_id",
      "hardware_id": "$hardware_id",
    },
    "parts": ubjson.encode [{
      "from": 0,
      "to": 10,
      "hash": firmware_token,
    }],
    "sdk-version": sdk_version,
    "pod-id": pod_id.to_byte_array
  }
  return base64.encode (ubjson.encode {
    "device-specific": device_specific,
    "checksum": #[],
  })

build_encoded_firmware -> string
    --device/Device
    --sdk_version/string?=null
    --pod_id/uuid.Uuid?=null:
  return build_encoded_firmware
      --device_id=device.id
      --organization_id=device.organization_id
      --hardware_id=device.hardware_id
      --sdk_version=sdk_version
      --pod_id=pod_id

server_type_from_args args/List:
  args.do: | arg |
    if not arg.ends_with "-server": continue.do
    return arg[2..].trim --right "-server"
  return "http"

broker_type_from_args args/List:
  args.do: | arg |
    if not arg.ends_with "-broker": continue.do
    return arg[2..].trim --right "-broker"
  return "http"

random_uuid -> uuid.Uuid:
  return uuid.uuid5 "random" "uuid $Time.now.ns_since_epoch $random"

with_fleet --args/List --count/int [block]:
  with_test_cli --args=args: | test_cli/TestCli |
    with_tmp_directory: | fleet_dir |
      test_cli.replacements[fleet_dir] = "<FLEET_ROOT>"
      test_cli.run [
        "auth", "login",
        "--email", TEST_EXAMPLE_COM_EMAIL,
        "--password", TEST_EXAMPLE_COM_PASSWORD,
      ]

      test_cli.run [
        "auth", "login",
        "--broker",
        "--email", TEST_EXAMPLE_COM_EMAIL,
        "--password", TEST_EXAMPLE_COM_PASSWORD,
      ]

      test_cli.run [
        "fleet",
        "--fleet-root", fleet_dir,
        "init",
        "--organization-id", "$TEST_ORGANIZATION_UUID",
      ]

      identity_dir := "$fleet_dir/identities"
      directory.mkdir --recursive identity_dir
      test_cli.run [
        "fleet",
        "--fleet-root", fleet_dir,
        "create-identities",
        "--output-directory", identity_dir,
        "$count",
      ]

      devices := read_json "$fleet_dir/devices.json"
      // Replace the names with something deterministic.
      counter := 0
      devices.do: | _ device |
        device["name"] = "name-$(counter++)"
      write_json_to_file "$fleet_dir/devices.json" devices --pretty

      ids := devices.keys
      expect_equals count ids.size

      fake_devices := []
      ids.do: | id/string |
        id_file := "$identity_dir/$(id).identity"
        expect (file.is_file id_file)
        content := read_base64_ubjson id_file
        fake_device := test_cli.start_fake_device --identity=content
        test_cli.replacements[id] = "-={| UUID-FOR-FAKE-DEVICE $(%05d fake_devices.size) |}=-"
        fake_devices.add fake_device

      block.call test_cli fake_devices fleet_dir

expect_throws [--check_exception] [block]:
  exception := catch: block.call
  expect_not_null exception
  expect (check_exception.call exception)

expect_throws --contains/string [block]:
  expect_throws --check_exception=(: it.contains contains) block
