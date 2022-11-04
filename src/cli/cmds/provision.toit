// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import encoding.ubjson
import encoding.base64
import host.file
import http
import net
import writer
import crypto.sha256

import ..sdk

import ..broker
import ..cache
import ..config
import ...shared.postgrest.supabase as supabase

import .broker_options_

create_provision_commands config/Config cache/Cache -> List:
  provision_cmd := cli.Command "provision"

  create_identity_cmd := cli.Command "create-identity"
      --options=broker_options + [
        cli.OptionString "device-id"
            --default="",
        // TODO(kasper): These options should be given through some
        // sort of auth-based mechanism.
        cli.OptionString "fleet-id"
            --default="c6fb0602-79a6-4cc3-b1ee-08df55fb30ad",
        cli.OptionString "organization-id"
            --default="4b6d9e35-cae9-44c0-8da0-6b0e485987e2"
      ]
      --run=:: create_identity config it

  provision_cmd.add create_identity_cmd
  return [provision_cmd]

create_identity config/Config parsed/cli.Parsed:
  fleet_id := parsed["fleet-id"]
  device_id := parsed["device-id"]
  broker := get_broker config parsed["broker"]
  artemis_broker := get_broker config parsed["broker.artemis"]

  network := net.open
  try:
    client := supabase.create_client network artemis_broker
    device := insert_device_in_fleet fleet_id device_id client artemis_broker
    // Insert an initial event mostly for testing purposes.
    device_id = device["alias"]
    hardware_id := device["id"]
    insert_created_event hardware_id client artemis_broker
    // Finally create the identity output file.
    create_identity_file device_id fleet_id hardware_id broker artemis_broker
  finally:
    network.close

insert_device_in_fleet fleet_id/string device_id/string client/http.Client artemis_broker/Map -> Map:
  map := {
    "fleet": fleet_id,
  }
  if not device_id.is_empty: map["alias"] = device_id
  payload := json.encode map

  headers := supabase.create_headers artemis_broker
  headers.add "Prefer" "return=representation"
  table := "devices"
  response := client.post payload
      --host=artemis_broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"

  if response.status_code != 201:
    throw "Unable to create device identity"
  return (json.decode_stream response.body).first

insert_created_event hardware_id/string client/http.Client artemis_broker/Map -> none:
  map := {
    "device": hardware_id,
    "data": { "type": "created" }
  }
  payload := json.encode map

  headers := supabase.create_headers artemis_broker
  table := "events"
  response := client.post payload
      --host=artemis_broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"
  if response.status_code != 201:
    throw "Unable to insert 'created' event."

create_identity_file device_id/string fleet_id/string hardware_id/string broker/Map artemis_broker/Map -> none:
  output_path := "$(device_id).identity"

  // TODO(kasper): It is pretty ugly that we have to copy
  // the supabase component to avoid messing with the
  // broker map.
  supabase := broker["supabase"].copy
  artemis_supabase := artemis_broker["supabase"].copy
  certificates := collect_certificates supabase
  (collect_certificates artemis_supabase).do: | key/string value |
    certificates[key] = value

  identity ::= {
    "artemis.device": {
      "device_id"   : device_id,
      "fleet_id"    : fleet_id,
      "hardware_id" : hardware_id,
    },
    "artemis.broker": {
      "supabase"    : artemis_supabase,
    },
    "broker": {
      "supabase"    : supabase,
    },
  }

  // Add the necessary certificates to the identity.
  certificates.do: | name/string content/ByteArray |
    identity[name] = content

  write_ubjson_to_file output_path identity
  print "Created device identity => $output_path"

collect_certificates supabase/Map -> Map:
  certificates := {:}
  sha := sha256.Sha256
  certificate := supabase.get "certificate"
  if certificate:
    sha.add supabase["certificate"]
    certificate_key := "certificate-$(base64.encode sha.get[0..8])"
    certificates[certificate_key] = supabase["certificate"]
    supabase["certificate"] = certificate_key
  return certificates

add_certificate_assets assets_path/string tmp/string certificates/Map -> none:
  // Add the certificates as distinct assets, so we can load them without
  // copying them into writable memory.
  certificates.do: | name/string value |
    write_blob_to_file "$tmp/$name" value
    run_assets_tool ["-e", assets_path, "add", name, "$tmp/$name"]

write_blob_to_file path/string value -> none:
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close

write_json_to_file path/string value/any -> none:
  write_blob_to_file path (json.encode value)

write_ubjson_to_file path/string value/any -> none:
  encoded := base64.encode (ubjson.encode value)
  write_blob_to_file path encoded
