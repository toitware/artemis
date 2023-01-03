// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.file

import ..cache
import ..config
import ..auth as auth
import ..server_config
import ..ui

create_auth_commands config/Config cache/Cache ui/Ui -> List:
  auth_cmd := cli.Command "auth"
      --short_help="Authenticate against the Artemis server or the broker."

  broker_cmd := cli.Command "broker"
      --short_help="Authenticate against the broker."
  auth_cmd.add broker_cmd

  broker_log_in_cmd := cli.Command "login"
      --short_help="Log in to the broker."
      --options=[
        cli.OptionString "broker" --short_help="The broker to log in to.",
        cli.OptionString "username" --short_help="The username for a password-based login.",
        cli.OptionString "password" --short_help="The password for a password-based login.",
      ]
      --run=:: sign_in --broker it config ui
  broker_cmd.add broker_log_in_cmd

  broker_refresh_cmd := cli.Command "refresh"
      --short_help="Refresh the authentication token."
      --hidden
      --options=[
        cli.OptionString "broker" --short_help="The broker to use."
      ]
      --run=:: refresh --broker it config ui
  broker_cmd.add broker_refresh_cmd

  artemis_cmd := cli.Command "artemis"
      --short_help="Authenticate against the Artemis server."
  auth_cmd.add artemis_cmd

  sign_up_cmd := cli.Command "signup"
      --short_help="Sign up for an Artemis account with email and password."
      --long_help="""
      Sign up for an Artemis account.

      The usual way of signing up is to use oauth2. This command is only
      needed if a password-based login is required.

      If the account with the given email already exists, then the login
      options are merged, and both the password and oauth2 login methods
      are available.
      """
      --options=[
        cli.OptionString "server" --hidden --short_help="The server to sign up for.",
        cli.OptionString "email"
            --short_help="The email address for the account."
            --required,
        cli.OptionString "password"
            --short_help="The password for the account."
            --required,
      ]
      --run=:: sign_up it config ui
  artemis_cmd.add sign_up_cmd

  log_in_cmd := cli.Command "login"
      --short_help="Log in to the Artemis server."
      --options=[
        cli.OptionString "server" --hidden --short_help="The server to log in to.",
        cli.OptionString "email" --short_help="The email for a password-based login.",
        cli.OptionString "password" --short_help="The password for a password-based login.",
      ]
      --run=:: sign_in --no-broker it config ui
  artemis_cmd.add log_in_cmd

  refresh_cmd := cli.Command "refresh"
      --short_help="Refresh the authentication token."
      --hidden
      --options=[
        cli.OptionString "server" --short_help="The server to use."
      ]
      --run=:: refresh --no-broker it config ui
  artemis_cmd.add refresh_cmd

  return [auth_cmd]

sign_in --broker/bool parsed/cli.Parsed config/Config ui/Ui:
  server_config/ServerConfig := ?
  if broker:
    server_config = get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  else:
    server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  if parsed.was_provided "email" or parsed.was_provided "password":
    email := parsed["email"]
    password := parsed["password"]
    if not (email and password):
      throw "email and password must be provided together."
    auth.sign_in server_config config --email=email --password=password
  else:
    auth.sign_in server_config config --ui=ui
  ui.info "Successfully authenticated."

sign_up parsed/cli.Parsed config/Config ui/Ui:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  email := parsed["email"]
  password := parsed["password"]

  auth.sign_up server_config --email=email --password=password
  ui.info "Successfully signed up. Check your email for a verification link."

refresh --broker/bool parsed/cli.Parsed config/Config ui/Ui:
  server_config/ServerConfig := ?
  if broker:
    server_config = get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  else:
    server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  auth.refresh_token server_config config
  ui.info "Successfully refreshed."
