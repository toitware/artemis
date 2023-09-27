// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli
import host.file

import ..cache
import ..config
import ..auth show Authenticatable
import ..server-config
import ..ui
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import ..brokers.broker show with-broker BrokerCli


create-auth-commands config/Config cache/Cache ui/Ui -> List:
  auth-cmd := cli.Command "auth"
      --short-help="Authenticate against the Artemis server."

  sign-up-cmd := cli.Command "signup"
      --short-help="Sign up for an Artemis account with email and password."
      --long-help="""
      Sign up for an Artemis account.

      The usual way of signing up is to use oauth2. This command is only
      needed if a password-based login is required.

      If the account with the given email already exists, then the login
      options are merged, and both the password and oauth2 login methods
      are available.
      """
      --options=[
        cli.Flag "broker" --hidden --short-help="Sign up for the broker.",
        cli.OptionString "email"
            --short-help="The email address for the account."
            --required,
        cli.OptionString "password"
            --short-help="The password for the account."
            --required,
      ]
      --run=:: sign-up it config ui
  auth-cmd.add sign-up-cmd

  log-in-cmd := cli.Command "login"
      --aliases=["signin"]
      --short-help="Log in to the Artemis server."
      --options=[
        cli.Flag "broker" --hidden --short-help="Log into the broker.",
        cli.OptionString "email" --short-help="The email for a password-based login.",
        cli.OptionString "password" --short-help="The password for a password-based login.",
        cli.Flag "open-browser"
            --default=true
            --short-help="Automatically open the browser for OAuth authentication.",
      ]
      --run=:: sign-in it config ui
  auth-cmd.add log-in-cmd

  update-cmd := cli.Command "update"
      --short-help="Updates the email or password for the Artemis account."
      --options=[
        cli.Flag "broker" --hidden --short-help="Log into the broker.",
        cli.Option "email" --short-help="New email for the account.",
        cli.Option "password" --short-help="New password for the account.",
      ]
      --run=:: update it config ui
  auth-cmd.add update-cmd

  return [auth-cmd]

update parsed/cli.Parsed config/Config ui/Ui:
  email := parsed["email"]
  password := parsed["password"]
  if not email and not password:
    ui.abort "Either email or password must be provided."

  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch:
      authenticatable.update --email=email --password=password
      ui.info "Successfully updated."
      if password:
        ui.info "Check your email for a verification link. It might be in your spam folder."
    if exception:
      ui.abort exception


with-authenticatable parsed/cli.Parsed config/Config ui/Ui [block]:
  broker := parsed["broker"]
  server-config/ServerConfig := ?
  if broker:
    server-config = get-server-from-config config CONFIG-BROKER-DEFAULT-KEY
    with-broker server-config config: | broker/BrokerCli |
      block.call broker
  else:
    server-config = get-server-from-config config CONFIG-ARTEMIS-DEFAULT-KEY
    with-server server-config config: | server/ArtemisServerCli |
      block.call server

sign-in parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
    exception := catch:
      if parsed.was-provided "email" or parsed.was-provided "password":
        email := parsed["email"]
        password := parsed["password"]
        if not (email and password):
          throw "email and password must be provided together."
        if parsed.was-provided "open-browser":
          throw "'--open-browser' is not supported for password-based login"
        authenticatable.sign-in --email=email --password=password
      else:
        authenticatable.sign-in
            --provider="github"
            --ui=ui
            --open-browser=parsed["open-browser"]
      ui.info "Successfully authenticated."
    if exception:
      ui.abort exception

sign-up parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
    exception := catch:
      email := parsed["email"]
      password := parsed["password"]
      if not (email and password):
        throw "email and password must be provided together."
      authenticatable.sign-up --email=email --password=password
      ui.info "Successfully signed up. Check your email for a verification link."
    if exception:
      ui.abort exception
