// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli

import ..config

create_config_commands config/Config -> List:
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
      --subcommands=[
        cli.Command "add"
          --short_help="Adds a broker."
          --subcommands=[
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
          ]
      ]

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

add_supabase parsed/cli.Parsed config/Config:
  name := parsed["name"]
  host := parsed["host"]
  anon := parsed["anon"]
  certificate_name := parsed["certificate"]

  if certificate_name:
    if not config.contains "assets.certificates":
      config["assets.certificates"] = {:}
    print config.data
    certificate_assets := config.get "assets.certificates"
    if not certificate_assets.contains certificate_name:
      certificate := get_certificate_ certificate_name
      certificate_assets[name] = certificate

  if host.starts_with "http://" or host.starts_with "https://":
    host = host.trim --prefix "http://"
    host = host.trim --prefix "https://"

  if not config.contains "brokers":
    config["brokers"] = {:}
  brokers := config.get "brokers"
  brokers[name] = {
    "supabase": {
      "host": host,
      "anon": anon,
      "certificate": certificate_name,
    }
  }
  config.write
  print "Added broker $name"
