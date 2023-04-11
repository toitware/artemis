// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.file

import ..cache
import ..config
import ..auth show Authenticatable
import ..server_config
import ..ui
import ..artemis_servers.artemis_server show with_server ArtemisServerCli
import ..brokers.broker show with_broker BrokerCli


create_auth_commands config/Config cache/Cache ui/Ui -> List:
  auth_cmd := cli.Command "auth"
      --short_help="Authenticate against the Artemis server."

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
        cli.Flag "broker" --hidden --short_help="Sign up for the broker.",
        cli.OptionString "email"
            --short_help="The email address for the account."
            --required,
        cli.OptionString "password"
            --short_help="The password for the account."
            --required,
      ]
      --run=:: sign_up it config ui
  auth_cmd.add sign_up_cmd

  log_in_cmd := cli.Command "login"
      --aliases=["signin"]
      --short_help="Log in to the Artemis server."
      --options=[
        cli.Flag "broker" --hidden --short_help="Log into the broker.",
        cli.OptionString "email" --short_help="The email for a password-based login.",
        cli.OptionString "password" --short_help="The password for a password-based login.",
        cli.Flag "open-browser"
            --default=true
            --short_help="Automatically open the browser for OAuth authentication.",
      ]
      --run=:: sign_in it config ui
  auth_cmd.add log_in_cmd

  return [auth_cmd]

with_authenticatable parsed/cli.Parsed config/Config ui/Ui [block]:
  broker := parsed["broker"]
  server_config/ServerConfig := ?
  if broker:
    server_config = get_server_from_config config CONFIG_BROKER_DEFAULT_KEY
    with_broker server_config config: | broker/BrokerCli |
      block.call broker
  else:
    server_config = get_server_from_config config CONFIG_ARTEMIS_DEFAULT_KEY
    with_server server_config config: | server/ArtemisServerCli |
      block.call server

sign_in parsed/cli.Parsed config/Config ui/Ui:
  with_authenticatable parsed config ui: | authenticatable/Authenticatable |
    if parsed.was_provided "email" or parsed.was_provided "password":
      email := parsed["email"]
      password := parsed["password"]
      if not (email and password):
        throw "email and password must be provided together."
      if parsed.was_provided "open-browser":
        throw "'--open-browser' is not supported for password-based login"
      authenticatable.sign_in --email=email --password=password
    else:
      authenticatable.sign_in
          --provider="github"
          --ui=ui
          --open_browser=parsed["open-browser"]
    ui.info "Successfully authenticated."

sign_up parsed/cli.Parsed config/Config ui/Ui:
  with_authenticatable parsed config ui: | authenticatable/Authenticatable |
    email := parsed["email"]
    password := parsed["password"]
    if not (email and password):
      throw "email and password must be provided together."
    authenticatable.sign_up --email=email --password=password
    ui.info "Successfully signed up. Check your email for a verification link."
