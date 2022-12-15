// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.file

import ..server_config
import ..cache
import ..config
import ...shared.server_config

create_config_commands config/Config cache/Cache -> List:
  config_cmd := cli.Command "config"
      --short_help="Configure Artemis tool."

  print_cmd := cli.Command "print"
      --short_help="Print the current configuration."
      --run=:: print_config config

  config_cmd.add print_cmd

  (create_server_config_commands config).do: config_cmd.add it

  return [config_cmd]

create_server_config_commands config/Config -> List:
  config_broker_cmd := cli.Command "broker"
      --short_help="Configure the Artemis brokers."
      --options=[
        cli.Flag "artemis"
            --short_help="Manipulate the config of the Artemis server."
            --hidden
      ]

  config_broker_cmd.add
      cli.Command "use"
          --short_help="Set the default broker."
          --rest=[
            cli.OptionString "name"
                --short_help="The name of the broker."
                --required,
          ]
          --run=:: use_server it config

  config_broker_cmd.add
      cli.Command "default"
          --short_help="Print the default broker."
          --run=:: print_default_broker it config

  add_cmd := cli.Command "add"
      --short_help="Adds a broker."
      --options=[
        cli.Flag "default"
            --default=true
            --short_help="Set the broker as the default broker.",
      ]

  config_broker_cmd.add add_cmd

  add_cmd.add
      cli.Command "supabase"
          --short_help="Adds a Supabase broker."
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
          --run=:: add_supabase it config

  add_cmd.add
      cli.Command "mqtt"
          --short_help="Adds an MQTT broker."
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
          --run=:: add_mqtt it config

  return [config_broker_cmd]

print_config config/Config:
  throw "UNIMPLEMENTED"

use_server parsed/cli.Parsed config/Config:
  name := parsed["name"]
  if not has_server_in_config config name:
    throw "Unknown broker $name."
  config[parsed["artemis"] ? CONFIG_ARTEMIS_DEFAULT_KEY : CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

print_default_broker parsed/cli.Parsed config/Config:
  key := parsed["artemis"] ? CONFIG_ARTEMIS_DEFAULT_KEY : CONFIG_BROKER_DEFAULT_KEY
  default_server := config.get key
  if default_server: print default_server
  else: print "No default broker."

get_certificate_ name/string -> string:
  certificate := certificate_roots.MAP.get name
  if certificate: return certificate
  print "Unknown certificate."
  print "Available certificates:"
  certificate_roots.MAP.do --keys:
    print "  $it"
  throw "Unknown certificate"

add_supabase parsed/cli.Parsed config/Config:
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

  print "Added broker $name"


add_mqtt parsed/cli.Parsed config/Config:
  name := parsed["name"]
  host := parsed["host"]
  port := parsed["port"]
  root_certificate_name := parsed["root-certificate"]
  client_certificate_path := parsed["client-certificate"]
  client_private_key_path := parsed["client-private-key"]

  client_certificate/string? := null
  if client_certificate_path:
    client_certificate = (file.read_content client_certificate_path).to_string

  client_private_key/string? := null
  if client_private_key_path:
    client_private_key = (file.read_content client_private_key_path).to_string

  mqtt_config := ServerConfigMqtt name
      --host=host
      --port=port
      --root_certificate_name=root_certificate_name
      --client_certificate=client_certificate
      --client_private_key=client_private_key

  add_server_to_config config mqtt_config
  if parsed["default"]:
    config[CONFIG_BROKER_DEFAULT_KEY] = name
  config.write

  print "Added broker $name"

