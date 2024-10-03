// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import log show Logger
import log
import monitor
import net
import supabase
import system
import uuid

import artemis.cli.brokers.broker show BrokerCli
import artemis.service.brokers.broker show BrokerService

import .supabase-local-server
import ..tools.http-servers.public.broker show HttpBroker
import ..tools.lan-ip.lan-ip
import artemis.shared.server-config
  show
    ServerConfig
    ServerConfigHttp
    ServerConfigSupabase
import .utils

class TestBroker:
  server-config/ServerConfig
  backdoor/BrokerBackdoor

  constructor .server-config .backdoor:

  with-cli [block]:
    with-tmp-config: | config |
      broker-cli/BrokerCli? := null
      try:
        broker-cli = BrokerCli server-config config
        block.call broker-cli
      finally:
        if broker-cli: broker-cli.close

  with-service [block]:
    logger := log.default.with-name "testing-service"
    service-config := ServerConfig.from-json
        server-config.name
        server-config.to-service-json --der-serializer=: unreachable
        --der-deserializer=: unreachable
    broker-service := BrokerService logger service-config
    block.call broker-service

interface BrokerBackdoor:
  /**
  Creates a new device with the given $device-id and initial $state.
  */
  create-device --device-id/uuid.Uuid --state/Map -> none

  /**
  Removes the device with the given $device-id.
  */
  remove-device device-id/uuid.Uuid -> none

  /**
  Returns the reported state of the device.
  */
  get-state device-id/uuid.Uuid -> Map?

  /**
  Clears all events.
  */
  clear-events -> none

with-broker
    --type/string
    --args/List
    --logger/Logger=(log.default.with-name "testing-$type")
    [block]:
  if type == "supabase-local" or type == "supabase-local-artemis":
    // Make sure we are running with the correct resource lock.
    if type == "supabase-local-artemis":
      check-resource-lock "artemis_broker" --args=args
    else if type == "supabase-local":
      check-resource-lock "broker" --args=args
    else:
      unreachable
    sub-dir := type == "supabase-local" ? SUPABASE-BROKER : SUPABASE-ARTEMIS
    server-config := get-supabase-config --sub-directory=sub-dir
    service-key := get-supabase-service-key --sub-directory=sub-dir
    server-config.poll-interval = Duration --ms=500
    backdoor := SupabaseBackdoor server-config service-key
    test-server := TestBroker server-config backdoor
    block.call test-server
  else if type == "http" or type == "http-toit":
    with-http-broker block
  else:
    throw "Unknown broker type: $type"

class ToitHttpBackdoor implements BrokerBackdoor:
  server/HttpBroker

  constructor .server:

  create-device --device-id/uuid.Uuid --state/Map:
    server.create-device --device-id="$device-id" --state=state

  remove-device device-id/uuid.Uuid -> none:
    server.remove-device "$device-id"

  get-state device-id/uuid.Uuid -> Map?:
    return server.get-state --device-id="$device-id"

  clear-events -> none:
    server.clear-events

  stop -> none:
    server.stop

with-http-broker --name="test-broker" [block]:
  server := HttpBroker 0
  port-latch := monitor.Latch
  server-task := task:: server.start port-latch

  host := get-lan-ip

  server-config := ServerConfigHttp name
      --host=host
      --port=port-latch.get
      --path="/"
      --poll-interval=Duration --ms=500
      --root-certificate-names=null
      --root-certificate-ders=null
      --admin-headers={
        "X-Artemis-Header": "true",
      }
      --device-headers={
        "X-Artemis-Header": "true",
      }

  backdoor/ToitHttpBackdoor := ToitHttpBackdoor server

  test-server := TestBroker server-config backdoor
  try:
    block.call test-server
  finally:
    server.close
    server-task.cancel

class SupabaseBackdoor implements BrokerBackdoor:
  server-config_/ServerConfigSupabase
  service-key_/string

  constructor .server-config_ .service-key_:

  create-device --device-id/uuid.Uuid --state/Map:
    with-backdoor-client_: | client/supabase.Client |
      client.rest.rpc --schema="toit_artemis" "new_provisioned" {
        "_device_id": "$device-id",
        "_state": state,
      }

  remove-device device-id/uuid.Uuid -> none:
    with-backdoor-client_: | client/supabase.Client |
      client.rest.rpc --schema="toit_artemis" "remove_device" {
        "_device_id": "$device-id",
      }

  get-state device-id/uuid.Uuid -> Map?:
    with-backdoor-client_: | client/supabase.Client |
      return client.rest.rpc --schema="toit_artemis" "get_state" {
        "_device_id": "$device-id",
      }
    unreachable

  clear-events -> none:
    with-backdoor-client_: | client/supabase.Client |
      client.rest.rpc --schema="toit_artemis" "clear_events" {:}

  with-backdoor-client_ [block]:
    network := net.open
    supabase-client/supabase.Client? := null
    try:
      supabase-client = supabase.Client
          --uri=server-config_.uri
          --anon=service-key_
      block.call supabase-client
    finally:
      if supabase-client: supabase-client.close
      network.close
