// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import certificate_roots
import cli
import host.file

import ..server_config
import ..cache
import ..config
import ..ui
import ...shared.server_config

create_config_commands config/Config cache/Cache ui/Ui -> List:
  config_cmd := cli.Command "config"
      --short_help="Configure Artemis tool."

  show_cmd := cli.Command "show"
      --short_help="Show the current configuration."
      --run=:: show_config config ui

  config_cmd.add show_cmd

  (create_server_config_commands config ui).do: config_cmd.add it

  return [config_cmd]

create_server_config_commands config/Config ui/Ui -> List:
  config_broker_cmd := cli.Command "broker"
      --short_help="Configure the Artemis brokers."
      --options=[
        cli.Flag "artemis"
            --short_help="Manipulate the config of the Artemis server."
            --hidden
      ]

  config_broker_cmd.add
      cli.Command "default"
          --long_help="""
            Show or set the default broker.

            If no broker is specified, the current default broker is shown.
            If a broker is specified, it is set as the default broker.

            If the '--clear' flag is specified, clears the default broker.
            """
          --options=[
            cli.Flag "clear"
                --short_help="Clear the default broker.",
          ]
          --rest=[
            cli.OptionString "name"
                --short_help="The name of the broker."
          ]
          --run=:: default_server it config ui

  add_cmd := cli.Command "add"
      --short_help="Add a broker."
      --options=[
        cli.Flag "default"
            --default=true
            --short_help="Set the broker as the default broker.",
      ]

  config_broker_cmd.add add_cmd

  add_cmd.add
      cli.Command "supabase"
          --short_help="Add a Supabase broker."
          --options=[
            cli.OptionString "certificate"
                --short_help="The certificate to use for the broker.",
          ]
          --rest=[
            cli.OptionString "name"
                --short_help="The name of the broker."
                --required,
            cli.OptionString "host"
                --short_help="The host of the broker."
                --required,
            cli.OptionString "anon"
                --short_help="The key for anonymous access."
                --required,
          ]
          --run=:: add_supabase it config ui

  add_cmd.add
      cli.Command "mqtt"
          --short_help="Add an MQTT broker."
          --options=[
            cli.OptionString "root-certificate"
                --short_help="The name of the root certificate to use for the broker.",
            cli.OptionString "client-certificate"
                --short_help="The client certificate to use for the broker."
                --type="file",
            cli.OptionString "client-private-key"
                --short_help="The private key of the client."
                --type="file",
          ]
          --rest=[
            cli.OptionString "name"
                --short_help="The name of the broker."
                --required,
            cli.OptionString "host"
                --short_help="The host of the broker."
                --required,
            cli.OptionInt "port"
                --short_help="The port of the broker."
                --required,
          ]
          --run=:: add_mqtt it config ui

  add_cmd.add
      cli.Command "http"
          --hidden
          --short_help="Add an HTTP broker."
          --options=[
            cli.OptionInt "port"
                --short_help="The port of the broker."
                --short_name="p"
                --required,
            cli.Option "host"
                --short_help="The host of the broker."
                --short_name="h"
                --default="localhost",
          ]
          --rest=[
            cli.OptionString "name"
                --short_help="The name of the broker."
                --required,
          ]
          --run=:: add_http it config ui

  return [config_broker_cmd]

show_config config/Config ui/Ui:
  throw "UNIMPLEMENTED"

default_server parsed/cli.Parsed config/Config ui/Ui:
  config_key := parsed["artemis"] ? CONFIG_ARTEMIS_DEFAULT_KEY : CONFIG_BROKER_DEFAULT_KEY

  if parsed["clear"]:
    config.remove config_key
    config.write
    return

  name := parsed["name"]
  if not name:
    default_server := config.get config_key
    if default_server:
      ui.info default_server
    else:
      ui.error "No default broker."
      ui.abort
    return

  if not has_server_in_config config name:
    ui.error "Unknown broker $name."
    ui.abort

  config[config_key] = name
  config.write

get_certificate_ name/string ui/Ui -> string:
  certificate := certificate_roots.MAP.get name
  if certificate: return certificate
  ui.error "Unknown certificate."
  ui.info_list --title="Available certificates:"
      certificate_roots.MAP.keys
  throw "Unknown certificate"

add_supabase parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  anon := parsed["anon"]
  certificate_name := parsed["certificate"]

  if host.starts_with "http://" or host.starts_with "https://":
    host = host.trim --prefix "http://"
    host = host.trim --prefix "https://"

  supabase_config := ServerConfigSupabase name
      --host=host
      --anon=anon
      --root_certificate_name=certificate_name

  add_server_to_config config supabase_config
  if parsed["default"]:
    config[CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

  ui.info "Added broker $name"

/**
Reads a certificate from a file or from the certificate store.

Converts it to binary DER format.
*/
read_der_file_ path/string -> ByteArray:
  text := (file.read_content path).to_string.trim
  text = text.replace --all "\r" ""
  lines := text.split "\n"
  lines.filter --in_place: not it.starts_with "---"
  combined := lines.join ""
  return base64.decode combined

add_mqtt parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  port := parsed["port"]
  root_certificate_name := parsed["root-certificate"]
  client_certificate_path := parsed["client-certificate"]
  client_private_key_path := parsed["client-private-key"]

  client_certificate_der/ByteArray? := null
  if client_certificate_path:
    client_certificate_der = read_der_file_ client_certificate_path

  client_private_key_der/ByteArray? := null
  if client_private_key_path:
    client_private_key_der = read_der_file_ client_private_key_path

  mqtt_config := ServerConfigMqtt name
      --host=host
      --port=port
      --root_certificate_name=root_certificate_name
      --client_certificate_der=client_certificate_der
      --client_private_key_der=client_private_key_der

  add_server_to_config config mqtt_config
  if parsed["default"]:
    config[CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

  ui.info "Added broker $name"

add_http parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  port := parsed["port"]

  http_config := ServerConfigHttpToit name
      --host=host
      --port=port

  add_server_to_config config http_config
  if parsed["default"]:
    config[CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

  ui.info "Added broker $name"
