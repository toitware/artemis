// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.file

import ..cache
import ..config
import ..auth as auth
import ..server_config

create_auth_commands config/Config cache/Cache -> List:
  auth_cmd := cli.Command "auth"
      --short_help="Authenticate against the Artemis server or the broker."

  broker_cmd := cli.Command "broker"
      --short_help="Authenticate against the broker."
  auth_cmd.add broker_cmd

  broker_log_in_cmd := cli.Command "login"
      --short_help="Log in to the broker."
      --options=[
        cli.OptionString "broker" --short_help="The broker to log in to."
      ]
      --run=:: sign_in --broker it config
  broker_cmd.add broker_log_in_cmd

  broker_refresh_cmd := cli.Command "refresh"
      --short_help="Refresh the authentication token."
      --hidden
      --options=[
        cli.OptionString "broker" --short_help="The broker to use."
      ]
      --run=:: refresh --broker it config
  broker_cmd.add broker_refresh_cmd

  artemis_cmd := cli.Command "artemis"
      --short_help="Authenticate against the Artemis server."
  auth_cmd.add artemis_cmd

  log_in_cmd := cli.Command "login"
      --short_help="Log in to the Artemis server."
      --options=[
        cli.OptionString "server" --hidden --short_help="The server to log in to."
      ]
      --run=:: sign_in --no-broker it config
  artemis_cmd.add log_in_cmd

  refresh_cmd := cli.Command "refresh"
      --short_help="Refresh the authentication token."
      --hidden
      --options=[
        cli.OptionString "server" --short_help="The server to use."
      ]
      --run=:: refresh --no-broker it config
  artemis_cmd.add refresh_cmd

  return [auth_cmd]

sign_in --broker/bool parsed/cli.Parsed config/Config:
  server_config/ServerConfig := ?
  if broker:
    server_config = get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  else:
    server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  auth.sign_in server_config config
  print "Successfully authenticated."

refresh --broker/bool parsed/cli.Parsed config/Config:
  server_config/ServerConfig := ?
  if broker:
    server_config = get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  else:
    server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  auth.refresh_token server_config config
  print "Successfully refreshed."
