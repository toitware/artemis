// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import uuid
import host.file
import encoding.json
import writer
import net

import ..sdk
import ...shared.postgrest.supabase as supabase

import certificate_roots

create_provision_commands -> List:
  provision_cmd := cli.Command "provision"

  create_identity_cmd := cli.Command "create-identity"
      --options=[
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

  network := net.open
  client := supabase.supabase_create_client network

  map := {
    "fleet": fleet_id,
  }
  if not device_id.is_empty: map["alias"] = device_id
  payload := json.encode map

  headers := supabase.supabase_create_headers
  headers.add "Prefer" "return=representation"
  table := "devices-$fleet_id"
  response := client.post payload
      --host=supabase.SUPABASE_HOST
      --headers=headers
      --path="/rest/v1/$table"

  if response.status_code != 201:
    throw "Unable to create device identity"
  new_entry := (json.decode_stream response.body).first

  device_id = new_entry["alias"]
  hardware_id := new_entry["id"]
  path := "$(device_id).identity"

  map = {
    "device": hardware_id,
    "data": { "type": "created" }
  }
  payload = json.encode map

  headers = supabase.supabase_create_headers
  table = "events-$fleet_id"
  response = client.post payload
      --host=supabase.SUPABASE_HOST
      --headers=headers
      --path="/rest/v1/$table"
  if response.status_code != 201:
    throw "Unable to insert 'created' event"

  with_tmp_directory: | tmp/string |
    certificates := {:}
    run_assets_tool ["-e", path, "create"]
    // Add the cloud connection.
    certificates["certificate.baltimore"] = certificate_roots.BALTIMORE_CYBERTRUST_ROOT_TEXT_
    write_json "$tmp/device.json" {
      "device_id"     : device_id,
      "fleet_id"      : fleet_id,
      "hardware_id"   : hardware_id,
      "supabase" : {
        "anon"        : supabase.ANON_,
        "host"        : supabase.SUPABASE_HOST,
        "certificate" : "certificate.baltimore",
      }
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