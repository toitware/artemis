// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show *
import host.file

import ..cache
import ..config
import ..auth show Authenticatable
import ..server-config
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import ..brokers.broker show with-broker BrokerCli

SIGNIN-OPTIONS ::= [
  OptionEnum "provider" ["github", "google"]
      --help="The OAuth2 provider to use."
      --default="github",
  OptionString "email" --help="The email for a password-based login.",
  OptionString "password" --help="The password for a password-based login.",
  Flag "open-browser"
      --default=true
      --help="Automatically open the browser for OAuth authentication.",
]

create-auth-commands -> List:
  auth-cmd := Command "auth"
      --help="Authenticate against the Artemis server or a broker."

  sign-up-cmd := Command "signup"
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
        Flag "broker" --help="Sign up for the broker.",
        OptionString "server" --help="Sign up for a specific server.",
        OptionString "email"
            --help="The email address for the account."
            --required,
        OptionString "password"
            --help="The password for the account."
            --required,
      ]
      --examples=[
        Example "Sign up for an Artemis account with email and password:"
            --arguments="--email=test@example.com --password=secret",
      ]
      --run=:: sign-up it
  auth-cmd.add sign-up-cmd

  login-cmd := Command "login"
      --aliases=["signin", "log-in", "sign-in"]
      --help="""
          Log in to the Artemis server or a broker.

          If '--broker' is provided, authenticates with the default broker.
          If a server is provided with '--server', authenticates with that server.
          If neither is provided, authenticates with the Artemis server.
          See 'list' for available servers.
          """
      --options=[
        Flag "broker" --help="Log into the default broker.",
        OptionString "server" --help="Log into a specific server.",
      ] + SIGNIN-OPTIONS
      --examples=[
        Example "Log in to the Artemis server using GitHub:"
            --arguments=""
            --global-priority=10,
        Example """
            Log in to the Artemis server using GitHub without opening the link
            in a browser:"""
            --arguments="--no-open-browser",
        Example "Log in to the Artemis server using Google:"
            --arguments="--provider=google",
        Example "Log in to the Artemis server with email and password:"
            --arguments="--email=test@example.com --password=secret",
      ]
      --run=:: sign-in it
  auth-cmd.add login-cmd

  list-cmd := Command "list"
      --aliases=["ls"]
      --help="""
          List the available servers.

          Servers are added through the 'config' command.
          """
      --run=:: list-servers it
  auth-cmd.add list-cmd

  update-cmd := Command "update"
      --help="""
          Updates the email or password for an account.

          If '--broker' is provided, updates the account on the default broker.
          If a server is provided with '--server', updates the account on
          that server.
          If neither is provided, updates the account on the Artemis server.
          See 'list' for available servers.
          """
      --options=[
        Flag "broker" --help="Update the account on a broker.",
        OptionString "server" --help="Update the account on a specific server.",
        Option "email" --help="New email for the account.",
        Option "password" --help="New password for the account.",
      ]
      --examples=[
        Example "Update the password for the currently logged in account:"
            --arguments="--password=new-secret",
      ]
      --run=:: update it
  auth-cmd.add update-cmd

  logout-cmd := Command "logout"
      --aliases=["signout", "log-out", "sign-out"]
      --help="""
        Log out of the Artemis server or a broker.

        If '--broker' is provided, logs out of the default broker.
        If a server is provided with '--server', logs out of that server.
        If neither is provided, logs out of the Artemis server.
        See 'list' for available servers.
        """
      --options=[
        Flag "broker" --help="Log out of the the broker.",
        OptionString "server" --help="Log out of a specific server.",
      ]
      --run=:: logout it
  auth-cmd.add logout-cmd

  return [auth-cmd]

update invocation/Invocation:
  email := invocation["email"]
  password := invocation["password"]

  ui := invocation.cli.ui

  if not email and not password:
    ui.abort "Either email or password must be provided."

  with-authenticatable invocation: | name/string authenticatable/Authenticatable |
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch:
      authenticatable.update --email=email --password=password
      ui.emit --info "Successfully updated account on server '$name'."
      if password:
        ui.emit --info "Check your email for a verification link. It might be in your spam folder."
    if exception: ui.abort exception


with-authenticatable invocation/Invocation [block]:
  broker := invocation["broker"]
  server := invocation["server"]

  cli := invocation.cli
  ui := cli.ui

  if broker and server:
    ui.abort "Cannot specify both '--broker' and '--server'."

  server-config/ServerConfig := ?
  if broker or server:
    server-config = broker
        ? get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
        : get-server-from-config --cli=cli --name=server
    with-broker --cli=cli server-config: | broker/BrokerCli |
      block.call server-config.name broker
  else:
    server-config = get-server-from-config --cli=cli --key=CONFIG-ARTEMIS-DEFAULT-KEY
    with-server server-config --cli=cli: | server/ArtemisServerCli |
      block.call server-config.name server

sign-in invocation/Invocation:
  with-authenticatable invocation: | name/string authenticatable/Authenticatable |
    sign-in invocation --name=name --authenticatable=authenticatable

sign-in invocation/Invocation --name/string --authenticatable/Authenticatable:
  cli := invocation.cli
  ui := cli.ui
  params := invocation.parameters
  if params.was-provided "email" or params.was-provided "password":
    email := params["email"]
    password := params["password"]
    if not (email and password):
      ui.abort "Email and password must be provided together."
    if params.was-provided "provider":
      ui.abort "The '--provider' option is not supported for password-based login."
    if params.was-provided "open-browser":
      ui.abort "The '--open-browser' is not supported for password-based login."
    exception := catch:
      authenticatable.sign-in --email=email --password=password
    if exception: ui.abort exception
  else:
    exception := catch:
      authenticatable.sign-in
          --cli=cli
          --provider=params["provider"]
          --open-browser=params["open-browser"]
    if exception: ui.abort exception
  ui.emit --info "Successfully authenticated on server '$name'."

list-servers invocation/Invocation:
  cli := invocation.cli
  servers := get-servers-from-config --cli=cli
  cli.ui.emit-list
      --kind=Ui.RESULT
      --title="Available servers"
      servers

sign-up invocation/Invocation:
  ui := invocation.cli.ui
  with-authenticatable invocation: | name/string authenticatable/Authenticatable |
      email := invocation["email"]
      password := invocation["password"]
      exception := catch:
        authenticatable.sign-up --email=email --password=password
      if exception: ui.abort exception
      ui.emit --info "Successfully signed up on server '$name'. Check your email for a verification link."

logout invocation/Invocation:
  ui := invocation.cli.ui
  with-authenticatable invocation: | name/string authenticatable/Authenticatable |
    // A bit of a weird situation: we require to be authenticated to log out.
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch: authenticatable.logout
    if exception: ui.abort exception
    ui.emit --info "Successfully logged out of server '$name'."
