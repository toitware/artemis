// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import encoding.base64
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
import .mqtt_broker_mosquitto

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
  artemis_backdoor/ArtemisServerBackdoor

  constructor .config .cache .artemis_backdoor:

  run args --expect_exit_1/bool=false -> string:
    ui := TestUi
    exception := catch --unwind=(: not expect_exit_1 or it is not TestExit):
      cli.main args --config=config --cache=cache --ui=ui
    if expect_exit_1 and not exception:
      throw "Expected exit 1, but got exit 0"
    return ui.stdout

/**
Starts the artemis server and broker.

If $start_device_artemis is true creates a new device in the default
  test organization and starts a service_task running Artemis.
Neither the 'check_in', nor the firmware service are set up.
If $wait_for_device is true, waits for the device to report its state.

Calls the given $block with a $TestCli instance and a $Device or null.

If the type is supabase, uses the running supabase instances. Otherwise,
  creates fresh instances of the brokers.
*/
with_test_cli
    --artemis_type/string="http"
    --broker_type/string="http"
    --logger/log.Logger=log.default
    --start_device_artemis/bool=true
    --wait_for_device/bool=true
    [block]:
  with_artemis_server --type=artemis_type: | artemis_server |
    with_test_cli
        --artemis_server=artemis_server
        broker_type
        --logger=logger
        --start_device_artemis=start_device_artemis
        block

with_test_cli
    --artemis_server/TestArtemisServer
    broker_type
    --logger/log.Logger
    --start_device_artemis/bool=true
    --wait_for_device/bool=true
    [block]:
  with_broker --type=broker_type --logger=logger: | broker/TestBroker |
    with_test_cli
        --artemis_server=artemis_server
        --broker=broker
        --logger=logger
        --start_device_artemis=start_device_artemis
        block

with_test_cli
    --artemis_server/TestArtemisServer
    --broker/TestBroker
    --logger/log.Logger
    --start_device_artemis/bool=true
    --wait_for_device/bool=true
    [block]:

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
    device/Device? := null

    device_description := artemis_server.backdoor.create_device
        --organization_id=TEST_ORGANIZATION_UUID
    hardware_id := device_description["id"]
    alias_id := device_description["alias"]
    initial_state := {
      "identity": {
        "device_id": alias_id,
        "organization_id": TEST_ORGANIZATION_UUID,
        "hardware_id": hardware_id,
      }
    }

    broker.backdoor.create_device --device_id=alias_id --state=initial_state

    if start_device_artemis:
      device = Device
          --id=alias_id
          --organization_id=TEST_ORGANIZATION_UUID
          --firmware_state={
            "firmware": encoded_firmware --device_id=alias_id
          }

      artemis_task = task::
        service.run_artemis device broker_config --no-start_ntp

      // Wait until the device has reported its state.
      if wait_for_device:
        with_timeout --ms=2_000:
          while not broker.backdoor.get_state alias_id:
            sleep --ms=100

    try:
      test_cli := TestCli config cache artemis_server.backdoor
      test_cli.run ["config", "broker", "--artemis", "default", artemis_config.name]
      test_cli.run ["config", "broker", "default", broker_config.name]
      block.call test_cli device
    finally:
      if artemis_task: artemis_task.cancel
      if device: artemis_server.backdoor.remove_device device.id
      directory.rmdir --recursive cache_dir

encoded_firmware
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
