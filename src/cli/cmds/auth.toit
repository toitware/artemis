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
      --help="Authenticate against the Artemis server or a broker."

  sign-up-cmd := cli.Command "signup"
      --aliases=["sign-up"]
      --help="""
        Sign up for an Artemis account with email and password.

        If '--broker' is provided, signs up for the default broker.
        If a server is provided with '--server', signs up for that server.
        If neither is provided, signs up for the Artemis server.
        See 'list' for available servers.

        The usual way of signing up is to use oauth2. This command is only
        needed if a password-based login is required.

        If the account with the given email already exists, then the login
        options are merged, and both the password and oauth2 login methods
        are available.
        """
      --options=[
        cli.Flag "broker" --help="Sign up for the broker.",
        cli.OptionString "server" --help="Sign up for a specific server.",
        cli.OptionString "email"
            --help="The email address for the account."
            --required,
        cli.OptionString "password"
            --help="The password for the account."
            --required,
      ]
      --examples=[
        cli.Example "Sign up for an Artemis account with email and password:"
            --arguments="--email=test@example.com --password=secret",
      ]
      --run=:: sign-up it config ui
  auth-cmd.add sign-up-cmd

  login-cmd := cli.Command "login"
      --aliases=["signin"]
      --help="""
          Log in to the Artemis server or a broker.

          If '--broker' is provided, authenticates with the default broker.
          If a server is provided with '--server', authenticates with that server.
          If neither is provided, authenticates with the Artemis server.
          See 'list' for available servers.
          """
      --options=[
        cli.Flag "broker" --help="Log into the default broker.",
        cli.OptionString "server" --help="Log into a specific server.",
        cli.OptionEnum "provider" ["github", "google"]
            --help="The OAuth2 provider to use."
            --default="github",
        cli.OptionString "email" --help="The email for a password-based login.",
        cli.OptionString "password" --help="The password for a password-based login.",
        cli.Flag "open-browser"
            --default=true
            --help="Automatically open the browser for OAuth authentication.",
      ]
      --examples=[
        cli.Example "Log in to the Artemis server using GitHub:"
            --arguments=""
            --global-priority=10,
        cli.Example """
            Log in to the Artemis server using GitHub without opening the link
            in a browser:"""
            --arguments="--no-open-browser",
        cli.Example "Log in to the Artemis server using Google:"
            --arguments="--provider=google",
        cli.Example "Log in to the Artemis server with email and password:"
            --arguments="--email=test@example.com --password=secret",
      ]
      --run=:: sign-in it config ui
  auth-cmd.add login-cmd

  list-cmd := cli.Command "list"
      --aliases=["ls"]
      --help="""
          List the available servers.

          Servers are added through the 'config' command.
          """
      --run=:: list-servers it config ui
  auth-cmd.add list-cmd

  update-cmd := cli.Command "update"
      --help="""
          Updates the email or password for an account.

          If '--broker' is provided, updates the account on the default broker.
          If a server is provided with '--server', updates the account on
          that server.
          If neither is provided, updates the account on the Artemis server.
          See 'list' for available servers.
          """
      --options=[
        cli.Flag "broker" --help="Update the account on a broker.",
        cli.OptionString "server" --help="Update the account on a specific server.",
        cli.Option "email" --help="New email for the account.",
        cli.Option "password" --help="New password for the account.",
      ]
      --examples=[
        cli.Example "Update the password for the currently logged in account:"
            --arguments="--password=new-secret",
      ]
      --run=:: update it config ui
  auth-cmd.add update-cmd

  logout-cmd := cli.Command "logout"
      --aliases=["signout", "log-out", "sign-out"]
      --help="""
        Log out of the Artemis server or a broker.

        If '--broker' is provided, logs out of the default broker.
        If a server is provided with '--server', logs out of that server.
        If neither is provided, logs out of the Artemis server.
        See 'list' for available servers.
        """
      --options=[
        cli.Flag "broker" --help="Log out of the the broker.",
        cli.OptionString "server" --help="Log out of a specific server.",
      ]
      --run=:: logout it config ui
  auth-cmd.add logout-cmd

  return [auth-cmd]

update parsed/cli.Parsed config/Config ui/Ui:
  email := parsed["email"]
  password := parsed["password"]
  if not email and not password:
    ui.abort "Either email or password must be provided."

  with-authenticatable parsed config ui: | name/string authenticatable/Authenticatable |
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch:
      authenticatable.update --email=email --password=password
      ui.info "Successfully updated authentication for $name."
      if password:
        ui.info "Check your email for a verification link. It might be in your spam folder."
    if exception: ui.abort exception


with-authenticatable parsed/cli.Parsed config/Config ui/Ui [block]:
  broker := parsed["broker"]
  server := parsed["server"]

  if broker and server:
    ui.abort "Cannot specify both '--broker' and '--server'."

  server-config/ServerConfig := ?
  if broker or server:
    server-config = broker
        ? get-server-from-config config ui --key=CONFIG-BROKER-DEFAULT-KEY
        : get-server-from-config config ui --name=server
    with-broker server-config config: | broker/BrokerCli |
      block.call server-config.name broker
  else:
    server-config = get-server-from-config config ui --key=CONFIG-ARTEMIS-DEFAULT-KEY
    with-server server-config config: | server/ArtemisServerCli |
      block.call server-config.name server

sign-in parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | name/string authenticatable/Authenticatable |
      if parsed.was-provided "email" or parsed.was-provided "password":
        email := parsed["email"]
        password := parsed["password"]
        if not (email and password):
          ui.abort "Email and password must be provided together."
        if parsed.was-provided "provider":
          ui.abort "The '--provider' option is not supported for password-based login."
        if parsed.was-provided "open-browser":
          ui.abort "The '--open-browser' is not supported for password-based login."
        exception := catch:
          authenticatable.sign-in --email=email --password=password
        if exception: ui.abort exception
      else:
        exception := catch:
          authenticatable.sign-in
              --provider=parsed["provider"]
              --ui=ui
              --open-browser=parsed["open-browser"]
        if exception: ui.abort exception
      ui.info "Successfully authenticated with $name."

list-servers parsed/cli.Parsed config/Config ui/Ui:
  servers := get-servers-from-config config
  ui.do --kind=Ui.RESULT: | printer/Printer |
    printer.emit servers --title="Available servers"

sign-up parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | name/string authenticatable/Authenticatable |
      email := parsed["email"]
      password := parsed["password"]
      exception := catch:
        authenticatable.sign-up --email=email --password=password
      if exception: ui.abort exception
      ui.info "Successfully signed up for $name. Check your email for a verification link."

logout parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | name/string authenticatable/Authenticatable |
    // A bit of a weird situation: we require to be authenticated to log out.
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch: authenticatable.logout
    if exception: ui.abort exception
    ui.info "Successfully logged out of $name."
