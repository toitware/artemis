// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show Cli
import encoding.json
import encoding.ubjson
import log show Logger
import log
import monitor
import net
import supabase
import supabase.filter show equals
import system
import uuid show Uuid

import artemis.cli.brokers.server show Server
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
  combined/bool

  constructor .server-config .backdoor --.combined:

  with-cli [block]:
    with-tmp-config-cli: | cli/Cli |
      server/Server? := null
      try:
        // The implementations operate inside a fleet's scope; attach
        // TEST-SCOPE here rather than on the bare server-config (which
        // is also reused as a global-config entry in the tests).
        scoped-config := server-config.with --scope=TEST-SCOPE
        server = Server scoped-config --cli=cli
        block.call server
      finally:
        if server: server.close

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

  For a combined broker this also writes the device into the auth-side
    devices table.
  */
  create-device --device-id/Uuid --state/Map -> none

  /** Returns the auth-side record for the given $device-id. */
  get-auth-device --device-id/Uuid -> Map?

  /**
  Removes the device with the given $device-id.
  */
  remove-device device-id/Uuid -> none

  /**
  Returns the reported state of the device.
  */
  get-state device-id/Uuid -> Map?

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
    // The Artemis Supabase project provides both the device registry and
    // broker, while the public Supabase broker only provides broker roles.
    combined := type == "supabase-local-artemis"
    // The backdoor operates inside a fleet's scope (TEST-SCOPE in
    // tests); the TestBroker's server-config stays scope-less because
    // it's also reused as a global-config entry.
    backdoor := SupabaseBackdoor
        (server-config.with --scope=TEST-SCOPE)
        service-key
        --combined=combined
    test-server := TestBroker server-config backdoor --combined=combined
    block.call test-server
  else if type == "http" or type == "http-toit":
    with-http-broker block
  else if type == "http-toit-combined":
    with-http-broker --combined block
  else:
    throw "Unknown broker type: $type"

class ToitHttpBackdoor implements BrokerBackdoor:
  server/HttpBroker
  server-config_/ServerConfigHttp
  combined_/bool

  constructor .server .server-config_ --combined/bool:
    combined_ = combined

  create-device --device-id/Uuid --state/Map:
    if combined_:
      // The combined server also owns the auth-side device record.
      server.insert-auth-device
          --device-id="$device-id"
          --organization-id=server-config_.scope.to-json
    server.create-device --device-id="$device-id" --state=state

  remove-device device-id/Uuid -> none:
    server.remove-device "$device-id"

  get-state device-id/Uuid -> Map?:
    return server.get-state --device-id="$device-id"

  clear-events -> none:
    server.clear-events

  get-auth-device --device-id/Uuid -> Map?:
    return server.get-auth-device --device-id="$device-id"

  stop -> none:
    server.stop

with-http-broker --name="test-broker" --combined/bool=false [block]:
  server := HttpBroker 0 --combined=combined
  port-latch := monitor.Latch
  server-task := task:: server.start port-latch

  host := get-lan-ip

  server-config := ServerConfigHttp name
      --host=host
      --port=port-latch.get
      --path="/"
      --poll-interval=Duration --ms=500
      --use-tls=false
      --root-certificate-ders=null
      --admin-headers={
        "X-Artemis-Header": "true",
      }
      --device-headers={
        "X-Artemis-Header": "true",
      }
  // The backdoor operates inside a fleet's scope (TEST-SCOPE in
  // tests); the TestBroker's server-config stays scope-less because
  // it's also reused as a global-config entry.
  backdoor/ToitHttpBackdoor := ToitHttpBackdoor
      server
      (server-config.with --scope=TEST-SCOPE)
      --combined=combined

  test-server := TestBroker server-config backdoor --combined=combined
  try:
    block.call test-server
  finally:
    server.close
    server-task.cancel

class SupabaseBackdoor implements BrokerBackdoor:
  server-config_/ServerConfigSupabase
  service-key_/string
  combined_/bool

  constructor .server-config_ .service-key_ --combined/bool:
    combined_ = combined

  create-device --device-id/Uuid --state/Map:
    with-backdoor-client_: | client/supabase.Client |
      if combined_:
        // The combined project also owns the auth-side devices table.
        client.rest.insert "devices" --no-return-inserted {
          "id": "$device-id",
          "alias": "$device-id",
          "organization_id": server-config_.scope.to-json,
        }
      client.rest.rpc --schema="toit_artemis" "new_provisioned" {
        "_device_id": "$device-id",
        "_state": state,
      }

  get-auth-device --device-id/Uuid -> Map?:
    with-backdoor-client_: | client/supabase.Client |
      devices := client.rest.select "devices" --filters=[
        equals "id" "$device-id",
      ]
      if devices.is-empty: return null
      return devices[0]
    unreachable

  remove-device device-id/Uuid -> none:
    with-backdoor-client_: | client/supabase.Client |
      client.rest.rpc --schema="toit_artemis" "remove_device" {
        "_device_id": "$device-id",
      }

  get-state device-id/Uuid -> Map?:
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
