// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import log show Logger
import log
import monitor
import net
import supabase
import uuid

import artemis.cli.brokers.broker show BrokerCli
import artemis.service.brokers.broker show BrokerService

import .supabase_local_server
import ..tools.http_servers.broker show HttpBroker
import ..tools.http_servers.broker as http_servers
import ..tools.lan_ip.lan_ip
import artemis.shared.server_config
  show
    ServerConfig
    ServerConfigHttpToit
    ServerConfigSupabase
import .utils

class TestBroker:
  server_config/ServerConfig
  backdoor/BrokerBackdoor

  constructor .server_config .backdoor:

  with_cli [block]:
    with_tmp_config: | config |
      broker_cli/BrokerCli? := null
      try:
        broker_cli = BrokerCli server_config config
        block.call broker_cli
      finally:
        if broker_cli: broker_cli.close

  with_service [block]:
    logger := log.default.with_name "testing-service"
    broker_service := BrokerService logger server_config
    block.call broker_service

interface BrokerBackdoor:
  /**
  Creates a new device with the given $device_id and initial $state.
  */
  create_device --device_id/uuid.Uuid --state/Map -> none

  /**
  Removes the device with the given $device_id.
  */
  remove_device device_id/uuid.Uuid -> none

  /**
  Returns the reported state of the device.
  */
  get_state device_id/uuid.Uuid -> Map?

  /**
  Clears all events.
  */
  clear_events -> none

with_broker --type/string --logger/Logger=(log.default.with_name "testing-$type") [block]:
  if type == "supabase-local" or type == "supabase-local-artemis":
    sub_dir := type == "supabase-local" ? SUPABASE_BROKER : SUPABASE_ARTEMIS
    server_config := get_supabase_config --sub_directory=sub_dir
    service_key := get_supabase_service_key --sub_directory=sub_dir
    server_config.poll_interval = Duration --ms=1
    backdoor := SupabaseBackdoor server_config service_key
    test_server := TestBroker server_config backdoor
    block.call test_server
  else if type == "http" or type == "http-toit":
    with_http_broker block
  else:
    throw "Unknown broker type: $type"

class ToitHttpBackdoor implements BrokerBackdoor:
  server/HttpBroker

  constructor .server:

  create_device --device_id/uuid.Uuid --state/Map:
    server.create_device --device_id="$device_id" --state=state

  remove_device device_id/uuid.Uuid -> none:
    server.remove_device "$device_id"

  get_state device_id/uuid.Uuid -> Map?:
    return server.get_state --device_id="$device_id"

  clear_events -> none:
    server.clear_events

with_http_broker [block]:
  server := http_servers.HttpBroker 0
  port_latch := monitor.Latch
  server_task := task:: server.start port_latch

  host := "localhost"
  if platform != PLATFORM_WINDOWS:
    lan_ip := get_lan_ip
    host = host.replace "localhost" lan_ip

  server_config := ServerConfigHttpToit "test-broker"
      --host=host
      --port=port_latch.get
      --poll_interval=Duration --ms=1

  backdoor/ToitHttpBackdoor := ToitHttpBackdoor server

  test_server := TestBroker server_config backdoor
  try:
    block.call test_server
  finally:
    server.close
    server_task.cancel

class SupabaseBackdoor implements BrokerBackdoor:
  server_config_/ServerConfigSupabase
  service_key_/string

  constructor .server_config_ .service_key_:

  create_device --device_id/uuid.Uuid --state/Map:
    with_backdoor_client_: | client/supabase.Client |
      client.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": "$device_id",
        "_state": state,
      }

  remove_device device_id/uuid.Uuid -> none:
    with_backdoor_client_: | client/supabase.Client |
      client.rest.rpc "toit_artemis.remove_device" {
        "_device_id": "$device_id",
      }

  get_state device_id/uuid.Uuid -> Map?:
    with_backdoor_client_: | client/supabase.Client |
      return client.rest.rpc "toit_artemis.get_state" {
        "_device_id": "$device_id",
      }
    unreachable

  clear_events -> none:
    with_backdoor_client_: | client/supabase.Client |
      client.rest.rpc "toit_artemis.clear_events" {:}

  with_backdoor_client_ [block]:
    network := net.open
    supabase_client/supabase.Client? := null
    try:
      supabase_client = supabase.Client
          --host=server_config_.host
          --anon=service_key_
      block.call supabase_client
    finally:
      if supabase_client: supabase_client.close
      network.close
