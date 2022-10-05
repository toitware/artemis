// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import host.file
import http
import net
import uuid
import writer

import ..sdk
import ...shared.postgrest.supabase as supabase

import .broker_options_

create_provision_commands -> List:
  provision_cmd := cli.Command "provision"

  create_identity_cmd := cli.Command "create-identity"
      --options=(broker_options --artemis_only) + [
        cli.OptionString "device-id"
            --default="",
        cli.OptionString "fleet-id"
            --default="c6fb0602-79a6-4cc3-b1ee-08df55fb30ad",
        cli.OptionString "organization-id"
            --default="4b6d9e35-cae9-44c0-8da0-6b0e485987e2"
      ]
      --run=:: create_identity it
  create_firmware_cmd := cli.Command "create-firmware"
      --options=[
        cli.OptionString "identity"
            --type="file"
      ]
      --run=:: create_firmware it

  provision_cmd.add create_identity_cmd
  provision_cmd.add create_firmware_cmd
  return [provision_cmd]

create_identity parsed/cli.Parsed:
  fleet_id := parsed["fleet-id"]
  device_id := parsed["device-id"]
  broker := read_broker "broker.artemis" parsed

  network := net.open
  try:
    client := supabase.create_client network broker
    device := insert_device_in_fleet fleet_id device_id client broker
    // Insert an initial event mostly for testing purposes.
    device_id = device["alias"]
    hardware_id := device["id"]
    insert_created_event fleet_id hardware_id client broker
    // Finally create the assets output file.
    create_assets device_id fleet_id hardware_id broker
  finally:
    network.close

insert_device_in_fleet fleet_id/string device_id/string client/http.Client broker/Map -> Map:
  map := {
    "fleet": fleet_id,
  }
  if not device_id.is_empty: map["alias"] = device_id
  payload := json.encode map

  headers := supabase.create_headers broker
  headers.add "Prefer" "return=representation"
  table := "devices-$fleet_id"
  response := client.post payload
      --host=broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"

  if response.status_code != 201:
    throw "Unable to create device identity"
  return (json.decode_stream response.body).first

insert_created_event fleet_id/string hardware_id/string client/http.Client broker/Map -> none:
  map := {
    "device": hardware_id,
    "data": { "type": "created" }
  }
  payload := json.encode map

  headers := supabase.create_headers broker
  table := "events-$fleet_id"
  response := client.post payload
      --host=broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"
  if response.status_code != 201:
    throw "Unable to insert 'created' event"

create_assets device_id/string fleet_id/string hardware_id/string broker/Map -> none:
  path := "$(device_id).identity"

  certificates := {:}
  supabase := broker["supabase"].copy
  certificates["womps"] = supabase["certificate"]
  supabase["certificate"] = "womps"

  with_tmp_directory: | tmp/string |
    run_assets_tool ["-e", path, "create"]
    write_json "$tmp/device.json" {
      "device_id"   : device_id,
      "fleet_id"    : fleet_id,
      "hardware_id" : hardware_id,
      "supabase"    : supabase,
    }
    run_assets_tool ["-e", path, "add", "--format=tison", "artemis.device", "$tmp/device.json"]
    // Add the certificates as distinct assets, so we can load them without
    // copying them into writable memory.
    certificates.do: | name/string value |
      write_blob "$tmp/$name" value
      run_assets_tool ["-e", path, "add", name, "$tmp/$name"]

  print "Created device => $path"

create_firmware parsed/cli.Parsed -> none:
  // Inputs:
  //  - identity file
  //  - connect information
  //  - artemis version?
  sdk := get_toit_sdk
  version := (file.read_content "$sdk/VERSION").to_string_non_throwing.trim
  print "Toit SDK $version"
  // base firmware envelope -- optionally fetched and cached
  // artemis image -- fetched and cached based on version
  //
  unreachable

write_blob path/string value -> none:
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close

write_json path/string value/any -> none:
  write_blob path (json.encode value)