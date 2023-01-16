// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import encoding.ubjson
import encoding.base64
import host.file
import http
import net
import writer

import ..sdk

import ..server_config
import ..cache
import ..config
import ..device
import ..ui
import ..artemis_servers.artemis_server show ArtemisServerCli

import .broker_options_

import ...shared.server_config

create_provision_commands config/Config cache/Cache ui/Ui -> List:
  provision_cmd := cli.Command "provision"

  create_identity_cmd := cli.Command "create-identity"
      --options=broker_options + [
        cli.OptionString "device-id"
            --default="",
        cli.OptionString "output-directory"
            --short_name="d"
            --short_help="Directory to write the identity file to.",
        cli.OptionString "output"
            --short_name="o"
            --short_help="File to write the identity to.",
        cli.OptionString "organization-id"
            --short_help="The organization to use."
      ]
      --run=:: create_identity it config ui

  provision_cmd.add create_identity_cmd
  return [provision_cmd]

create_identity parsed/cli.Parsed config/Config ui/Ui:
  output_file := parsed["output"]
  output_dir := parsed["output-directory"]
  if output_file and output_dir:
    throw "Cannot specify both --output-file and --output-directory"

  organization_id := parsed["organization-id"]
  if not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No default organization set."
      ui.abort

  device_id := parsed["device-id"]
  broker_generic := get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  artemis_broker_generic := get_server_from_config config parsed["broker.artemis"] CONFIG_ARTEMIS_DEFAULT_KEY

  if broker_generic is not ServerConfigSupabase: throw "unsupported broker"
  if artemis_broker_generic is not ServerConfigSupabase: throw "unsupported artemis broker"

  broker := broker_generic as ServerConfigSupabase
  artemis_broker := artemis_broker_generic as ServerConfigSupabase

  network := net.open
  try:
    server := ArtemisServerCli network artemis_broker config
    server.ensure_authenticated:
      ui.error "Not logged in"
      // TODO(florian): another PR is already out that changes this to 'ui.abort'
      exit 1

    device := server.create_device_in_organization --organization_id=organization_id --device_id=device_id

    // If the device id was not specified, use the one returned by the server.
    device_id = device.id
    hardware_id := device.hardware_id

    // Insert an initial event mostly for testing purposes.
    server.notify_created --hardware_id=hardware_id

    output_path := ?
    if output_file:
      output_path = output_file
    else if output_dir:
      output_path = "$output_dir/$(device_id).identity"
    else:
      output_path = "$(device_id).identity"

    // Finally create the identity output file.
    create_identity_file
        --device_id=device_id
        --organization_id=organization_id
        --hardware_id=hardware_id
        --server_config=broker
        --artemis_server_config=artemis_broker
        --output_path=output_path
        --ui=ui
  finally:
    network.close

create_identity_file -> none
    --device_id/string
    --organization_id/string
    --hardware_id/string
    --server_config/ServerConfigSupabase
    --artemis_server_config/ServerConfigSupabase
    --output_path/string
    --ui/Ui:

  // A map from id to deduplicated certificate.
  deduplicated_certificates := {:}

  broker_json := server_config_to_service_json server_config deduplicated_certificates
  artemis_broker_json := server_config_to_service_json artemis_server_config deduplicated_certificates

  identity ::= {
    "artemis.device": {
      "device_id"       : device_id,
      "organization_id" : organization_id,
      "hardware_id"     : hardware_id,
    },
    "artemis.broker": artemis_broker_json,
    "broker": broker_json,
  }

  // Add the necessary certificates to the identity.
  deduplicated_certificates.do: | name/string content/ByteArray |
    identity[name] = content

  write_ubjson_to_file output_path identity
  ui.info "Created device identity => $output_path"

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
