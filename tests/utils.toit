// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.json
import encoding.ubjson
import expect show *
import log
import host.directory
import host.pipe
import uuid
import artemis.cli
import artemis.cli.server_config as cli_server_config
import artemis.cli.cache as cli
import artemis.cli.config as cli
import artemis.shared.server_config
import artemis.service
import artemis.service.device show Device
import artemis.cli.ui show ConsoleUi
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
TEST_EXAMPLE_COM_UUID ::= "f76629c5-a070-4bbc-9918-64beaea48848"
TEST_EXAMPLE_COM_NAME ::= "Test User"

/** demo@example.com is a member of the $TEST_ORGANIZATION_UUID. */
DEMO_EXAMPLE_COM_EMAIL ::= "demo@example.com"
DEMO_EXAMPLE_COM_PASSWORD ::= "password"
DEMO_EXAMPLE_COM_UUID ::= "d9064bb5-1501-4ec9-bfee-21ab74d645b8"
DEMO_EXAMPLE_COM_NAME ::= "Demo User"

ADMIN_EMAIL ::= "test-admin@toit.io"
ADMIN_PASSWORD ::= "password"
ADMIN_UUID ::= "6ac69de5-7b56-4153-a31c-7b4e29bbcbcf"
ADMIN_NAME ::= "Admin User"

/** Preseeded "Test Organization". */
TEST_ORGANIZATION_NAME ::= "Test Organization"
TEST_ORGANIZATION_UUID ::= "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

/** Preseeded test device in $TEST_ORGANIZATION_UUID. */
TEST_DEVICE_UUID ::= "eb45c662-356c-4bea-ad8c-ede37688fddf"
TEST_DEVICE_ALIAS ::= "191149e5-a95b-47b1-80dd-b149f953d272"

NON_EXISTENT_UUID ::= (uuid.uuid5 "non" "existent").stringify

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
class TestUi extends ConsoleUi:
  stdout/string := ""

  print_ str/string:
    stdout += "$str\n"

  abort:
    throw TestExit

class TestCli:
  config/cli.Config
  cache/cli.Cache
  artemis/TestArtemisServer
  broker/TestBroker
  toit_run_/string
  test_devices_/List ::= []

  constructor .config .cache .artemis .broker --toit_run/string:
    toit_run_ = toit_run

  close:
    test_devices_.do: | device/TestDevice |
      device.close
      artemis.backdoor.remove_device device.hardware_id

  run args --expect_exit_1/bool=false -> string:
    ui := TestUi
    exception := catch --unwind=(: not expect_exit_1 or it is not TestExit):
      cli.main args --config=config --cache=cache --ui=ui
    if expect_exit_1 and not exception:
      throw "Expected exit 1, but got exit 0"
    return ui.stdout

  /**
  Creates and starts new device in the given $organization_id.
  Neither the 'check-in', nor the firmware service are set up.
  */
  start_device --organization_id/string=TEST_ORGANIZATION_UUID -> TestDevice:
    device_description := artemis.backdoor.create_device --organization_id=organization_id
    hardware_id := device_description["id"]
    alias_id := device_description["alias"]
    initial_state := {
      "identity": {
        "device_id": alias_id,
        "organization_id": organization_id,
        "hardware_id": hardware_id,
      }
    }

    broker.backdoor.create_device --device_id=alias_id --state=initial_state

    encoded_firmware := build_encoded_firmware
        --device_id=alias_id
        --organization_id=TEST_ORGANIZATION_UUID
        --hardware_id=hardware_id

    result := TestDevicePipe
        --broker=broker
        --alias_id=alias_id
        --hardware_id=hardware_id
        --organization_id=TEST_ORGANIZATION_UUID
        --toit_run=toit_run_
        --encoded_firmware=encoded_firmware
    test_devices_.add result
    return result

abstract class TestDevice:
  hardware_id/string
  alias_id/string
  organization_id/string
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

class TestDevicePipe extends TestDevice:
  chunks_/List := []  // Of bytearrays.
  pid_/int? := ?
  signal_ := monitor.Signal
  stdout_task_/Task? := null
  stderr_task_/Task? := null

  constructor
      --broker/TestBroker
      --hardware_id/string
      --alias_id/string
      --organization_id/string
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
    pid_ = fork_data[3]
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
      if pid_:
        SIGKILL ::= 9
        pipe.kill_ pid_ SIGKILL
        pid_ = null

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
    [block]:
  with_artemis_server --type=artemis_type: | artemis_server |
    with_test_cli
        --artemis_server=artemis_server
        broker_type
        --logger=logger
        --args=args
        block

with_test_cli
    --artemis_server/TestArtemisServer
    broker_type
    --logger/log.Logger
    --args/List
    [block]:
  with_broker --type=broker_type --logger=logger: | broker/TestBroker |
    with_test_cli
        --artemis_server=artemis_server
        --broker=broker
        --logger=logger
        --args=args
        block

with_test_cli
    --artemis_server/TestArtemisServer
    --broker/TestBroker
    --logger/log.Logger
    --args/List
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

    artemis_config := artemis_server.server_config
    broker_config := broker.server_config
    cli_server_config.add_server_to_config config artemis_config
    cli_server_config.add_server_to_config config broker_config

    artemis_task/Task? := null

    test_cli := TestCli config cache artemis_server broker --toit_run=toit_run
    try:
      test_cli.run ["config", "broker", "--artemis", "default", artemis_config.name]
      test_cli.run ["config", "broker", "default", broker_config.name]
      block.call test_cli
    finally:
      test_cli.close
      if artemis_task: artemis_task.cancel
      directory.rmdir --recursive cache_dir

build_encoded_firmware
    --device_id/string
    --organization_id/string=TEST_ORGANIZATION_UUID
    --hardware_id/string=device_id:
  device_specific := ubjson.encode {
    "artemis.device": {
      "device_id": device_id,
      "organization_id": organization_id,
      "hardware_id": hardware_id,
    },
    "parts": ubjson.encode [],
    "sdk-version": "v2.0.0-alpha.52",
  }
  return base64.encode (ubjson.encode {
    "device-specific": device_specific,
    "checksum": #[],
  })

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

random_uuid_string -> string:
  return (uuid.uuid5 "random" "uuid $Time.now.ns_since_epoch $random").stringify
