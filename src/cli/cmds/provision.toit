// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import encoding.ubjson
import encoding.base64
import host.file
import http
import net
import uuid
import writer
import crypto.sha256

import ..sdk

import ...shared.config
import ...shared.postgrest.supabase as supabase

import .broker_options_

create_provision_commands -> List:
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
      --run=:: create_identity it
  create_firmware_cmd := cli.Command "create-firmware"
      // TODO(kasper): Should this only be your own broker? I think so.
      --options=broker_options + [
        cli.OptionString "output"
            --short_name="o"
            --type="file"
            --required,
      ]
      --run=:: create_firmware it

  provision_cmd.add create_identity_cmd
  provision_cmd.add create_firmware_cmd
  return [provision_cmd]

create_identity parsed/cli.Parsed:
  fleet_id := parsed["fleet-id"]
  device_id := parsed["device-id"]
  broker := read_broker_from_files parsed["broker"]
  artemis_broker := read_broker_from_files parsed["broker.artemis"]

  network := net.open
  try:
    client := supabase.create_client network artemis_broker
    device := insert_device_in_fleet fleet_id device_id client artemis_broker
    // Insert an initial event mostly for testing purposes.
    device_id = device["alias"]
    hardware_id := device["id"]
    insert_created_event fleet_id hardware_id client artemis_broker
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
  table := "devices-$fleet_id"
  response := client.post payload
      --host=artemis_broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"

  if response.status_code != 201:
    throw "Unable to create device identity"
  return (json.decode_stream response.body).first

insert_created_event fleet_id/string hardware_id/string client/http.Client artemis_broker/Map -> none:
  map := {
    "device": hardware_id,
    "data": { "type": "created" }
  }
  payload := json.encode map

  headers := supabase.create_headers artemis_broker
  table := "events-$fleet_id"
  response := client.post payload
      --host=artemis_broker["supabase"]["host"]
      --headers=headers
      --path="/rest/v1/$table"
  if response.status_code != 201:
    throw "Unable to insert 'created' event"

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
  print "Created device => $output_path"

create_firmware parsed/cli.Parsed -> none:
  output_path := parsed["output"]
  broker := read_broker_from_files parsed["broker"]
  artemis_broker := read_broker_from_files parsed["broker.artemis"]

  // TODO(kasper): It is pretty ugly that we have to copy
  // the supabase component to avoid messing with the
  // broker map.
  supabase := broker["supabase"].copy
  artemis_supabase := artemis_broker["supabase"].copy
  certificates := collect_certificates supabase
  (collect_certificates artemis_supabase).do: | key/string value |
    certificates[key] = value

  with_tmp_directory: | tmp/string |
    write_json_to_file "$tmp/broker.json" { "supabase" : supabase }
    write_json_to_file "$tmp/artemis.broker.json" { "supabase" : artemis_supabase }

    assets_path := "$tmp/artemis.assets"
    run_assets_tool ["-e", assets_path, "create"]
    run_assets_tool ["-e", assets_path, "add", "--format=tison", "broker", "$tmp/broker.json"]
    run_assets_tool ["-e", assets_path, "add", "--format=tison", "artemis.broker", "$tmp/artemis.broker.json"]
    add_certificate_assets assets_path tmp certificates

    snapshot_path := "$tmp/artemis.snapshot"
    run_toit_compile ["-w", snapshot_path, "src/service/run/device.toit"]

    // We compile the snapshot to a binary image, unless we're doing
    // source builds. This way, we do not leak the source code of the
    // artemis service.
    program_path := snapshot_path
    if IS_SOURCE_BUILD:
      cache_snapshot snapshot_path
    else:
      program_path = "$tmp/artemis.image"
      run_snapshot_to_image_tool ["-m32", "--binary", "-o", program_path, snapshot_path]

    // We have got the assets and the artemis code compiled. Now we
    // just need to generate the firmware envelope.
    run_firmware_tool [
        "-e", PATH_FIRMWARE_ENVELOPE_ESP32,
        "container", "install",
        "-o", output_path,
        "--assets", assets_path,
        "artemis", program_path,
    ]

    // TODO(kasper): Base the uuid on the actual firmware bits and the Toit SDK version used
    // to compile it. Maybe this can happen automatically somehow in tools/firmware?

    // Finally, make it unique. The system uuid will have to be used when compiling
    // code for the device in the future. This will prove that you know which versions
    // went into the firmware image.
    system_uuid ::= uuid.uuid5 "system.uuid" "$(random 1_000_000)-$Time.now-$Time.monotonic_us"
    run_firmware_tool ["-e", output_path, "property", "set", "uuid", system_uuid.stringify]

collect_certificates supabase/Map -> Map:
  certificates := {:}
  sha := sha256.Sha256
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
