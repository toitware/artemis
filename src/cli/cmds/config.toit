// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.file

import ..cache
import ..config

create_config_commands config/Config cache/Cache -> List:
  config_cmd := cli.Command "config"
      --short_help="Configure Artemis tool."

  print_cmd := cli.Command "print"
      --short_help="Print the current configuration."
      --run=:: print_config config

  config_cmd.add print_cmd

  (create_broker_config_commands config).do: config_cmd.add it

  return [config_cmd]

create_broker_config_commands config/Config -> List:
  config_broker_cmd := cli.Command "broker"
      --short_help="Configure the Artemis brokers."

  add_cmd := cli.Command "add"
      --short_help="Adds a broker."

  config_broker_cmd.add add_cmd

  add_cmd.add
      cli.Command "supabase"
          --short_help="Adds a Supabase broker."
          --options=[
            cli.OptionString "certificate"
                --short_help="The certificate to use for the broker."
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
                --type="file"
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

get_certificate_ name/string -> string:
  certificate := certificate_roots.MAP.get name
  if certificate: return certificate
  print "Unknown certificate."
  print "Available certificates:"
  certificate_roots.MAP.do --keys:
    print "  $it"
  throw "Unknown certificate"

add_certificate_to_config_ config/Config name/string:
  if not config.contains "assets.certificates":
    config["assets.certificates"] = {:}
  certificate_assets := config.get "assets.certificates"
  if not certificate_assets.contains name:
    certificate := get_certificate_ name
    certificate_assets[name] = certificate

add_broker_to_config_ config/Config name/string type/string broker_config/Map:
  if not config.contains "brokers":
    config["brokers"] = {:}
  brokers := config.get "brokers"

  brokers[name] = {
    type: broker_config
  }

add_supabase parsed/cli.Parsed config/Config:
  name := parsed["name"]
  host := parsed["host"]
  anon := parsed["anon"]
  certificate_name := parsed["certificate"]

  if certificate_name:
    add_certificate_to_config_ config certificate_name

  if host.starts_with "http://" or host.starts_with "https://":
    host = host.trim --prefix "http://"
    host = host.trim --prefix "https://"

  supabase_config := {
      "host": host,
      "anon": anon,
  }
  if certificate_name:
    supabase_config["certificate"] = certificate_name

  add_broker_to_config_ config name "supabase" supabase_config
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

  if root_certificate_name:
    add_certificate_to_config_ config root_certificate_name

  mqtt_config := {
      "host": host,
      "port": port,
  }
  if root_certificate_name:
    mqtt_config["root-certificate"] = root_certificate_name
  if client_certificate:
    mqtt_config["client-certificate"] = client_certificate
  if client_private_key:
    mqtt_config["client-private-key"] = client_private_key

  add_broker_to_config_ config name "mqtt" mqtt_config
  config.write

  print "Added broker $name"

