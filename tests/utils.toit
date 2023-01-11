// Copyright (C) 2022 Toitware ApS. All rights reserved.

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
import .brokers
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

with_http_artemis_server [block]:
  server := http_servers.HttpArtemisServer 0
  port_latch := monitor.Latch
  server_task := task:: server.start port_latch

  server_config := server_config.ServerConfigHttpToit "test-artemis-server"
      --host="localhost"
      --port=port_latch.get

  try:
    block.call server server_config
  finally:
    server.close
    server_task.cancel

// TODO(florian): Maybe it's better to use a simplified version of the
//   the UI, so it's easier to match against it. We probably want the
//   default version of the console UI to be simpler anyway.
class TestUi extends ConsoleUi:
  stdout := ""

  print_ str/string:
    stdout += "$str\n"

class TestCli:
  config/cli.Config
  cache/cli.Cache
  constructor .config .cache:

  run args -> string:
    ui := TestUi
    cli.main args --config=config --cache=cache --ui=ui
    return ui.stdout

/**
Starts the artemis server and broker.

If $start_device_artemis is true also starts a service-task running Artemis with
  $device_id as device ID.
Neither the 'check_in', nor the firmware service are set up.

Calls the given $block with a $TestCli instance and a $Device/null.

If the type is supabase, uses the running supabase instances. Otherwise,
  creates fresh instances of the brokers.
*/
with_test_cli
    --artemis_type/string="http"
    --broker_type/string="http"
    --logger/log.Logger=log.default
    --start_device_artemis/bool=true
    --device_id=TEST_DEVICE_UUID
    [block]:
  if artemis_type == "supabase":
    server_config := get_supabase_config --sub_directory=SUPABASE_ARTEMIS
    with_test_cli
        --artemis_config=server_config
        broker_type
        --logger=logger
        --start_device_artemis=start_device_artemis
        --device_id=device_id
        block
  else if artemis_type == "http":
    with_http_artemis_server: | server server_config |
      with_test_cli
          --artemis_config=server_config
          broker_type
          --logger=logger
          --start_device_artemis=start_device_artemis
          --device_id=device_id
          block
  else:
    throw "Unknown artemis_type $artemis_type"

with_test_cli
    --artemis_config/server_config.ServerConfig
    broker_type
    --logger/log.Logger
    --start_device_artemis/bool=true
    --device_id=TEST_DEVICE_UUID
    [block]:
  if broker_type == "supabase":
    server_config := get_supabase_config --sub_directory=SUPABASE_CUSTOMER
    with_test_cli
        --artemis_config=artemis_config
        --broker_config=server_config
        --logger=logger
        --start_device_artemis=start_device_artemis
        --device_id=device_id
        block
  else if broker_type == "http":
    with_http_broker: | server_config |
      with_test_cli
          --artemis_config=artemis_config
          --broker_config=server_config
          --logger=logger
          --start_device_artemis=start_device_artemis
          --device_id=device_id
          block
  else if broker_type == "mosquitto":
    with_mosquitto --logger=logger: | host/string port/int |
      server_config := server_config.ServerConfigMqtt "mosquitto" --host=host --port=port
  else:
    throw "Unknown broker_type $broker_type"

with_test_cli
    --artemis_config/server_config.ServerConfig
    --broker_config/server_config.ServerConfig
    --logger/log.Logger
    --start_device_artemis/bool=true
    --device_id=TEST_DEVICE_UUID
    [block]:

  with_tmp_directory: | tmp_dir |
    config_file := "$tmp_dir/config"
    config := cli.read_config_file config_file --init=: it
    cache_dir := "$tmp_dir/CACHE"
    directory.mkdir cache_dir
    cache := cli.Cache --app_name="artemis-test" --path=cache_dir

    cli_server_config.add_server_to_config config artemis_config
    cli_server_config.add_server_to_config config broker_config

    artemis_task/Task? := null
    device/Device? := null

    if start_device_artemis:
      device = Device --id=device_id --firmware="foo"

      artemis_task = task::
        service.run_artemis device broker_config --no-start_ntp

    try:
      test_cli := TestCli config cache
      test_cli.run ["config", "broker", "--artemis", "use", artemis_config.name]
      test_cli.run ["config", "broker", "use", broker_config.name]
      block.call test_cli device
    finally:
      if artemis_task: artemis_task.cancel
      directory.rmdir --recursive cache_dir
