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
            cli.Option "path"
                --short_help="The path of the broker."
                --default="/",
            cli.Option "root-certificate"
                --short_help="The root certificate name of the broker."
                --multi,
            cli.Option "device-header"
                --short_help="The HTTP header the device needs to add to the request. Of the form KEY=VALUE."
                --multi,
            cli.Option "admin-header"
                --short_help="The HTTP header the CLI needs to add to the request. Of the form KEY=VALUE."
                --multi,
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
      ui.result default_server
    else:
      ui.abort "No default broker."
    return

  if not has_server_in_config config name:
    ui.abort "Unknown broker $name."

  config[config_key] = name
  config.write

check_certificate_ name/string ui/Ui -> none:
  certificate := certificate_roots.MAP.get name
  if certificate: return
  ui.error "Unknown certificate."
  ui.do: | printer/Printer |
    printer.emit --title="Available certificates:"
      certificate_roots.MAP.keys
  ui.abort

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

  ui.info "Added broker $name."

add_http parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  port := parsed["port"]
  path := parsed["path"]
  root_certificate_names := parsed["root-certificate"]
  device_headers_list := parsed["device-header"]
  admin_headers_list := parsed["admin-header"]

  root_certificate_names.do: check_certificate_ it ui
  if root_certificate_names.is_empty:
    root_certificate_names = null

  header_list_to_map := : | header_list/List |
    headers_map := null
    if not header_list.is_empty:
      headers_map = {:}
      header_list.do: | header/string |
        equal_index := header.index_of "="
        if equal_index == -1:
          ui.abort "Invalid header: $header"
        key := header[..equal_index]
        value := header[equal_index + 1..]
        if headers_map.contains key:
          ui.abort "Duplicate headers not implemented: $key"
        headers_map[key] = value

  device_headers := header_list_to_map.call device_headers_list
  admin_headers := header_list_to_map.call admin_headers_list

  http_config := ServerConfigHttp name
      --host=host
      --port=port
      --path=path
      --root_certificate_names=root_certificate_names
      --root_certificate_ders=null
      --device_headers=device_headers
      --admin_headers=admin_headers

  add_server_to_config config http_config
  if parsed["default"]:
    config[CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

  ui.info "Added broker $name."
