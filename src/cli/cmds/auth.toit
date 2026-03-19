// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show *
import host.file

import ..cache
import ..config
import ..auth show Authenticatable
import ..server-config
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
      --help="Authenticate against a broker."

  sign-up-cmd := Command "signup"
      --aliases=["sign-up"]
      --help="""
        Sign up for an account with email and password.

        If a server is provided with '--server', signs up for that server.
        Otherwise, signs up for the default broker.
        See 'list' for available servers.

        The usual way of signing up is to use oauth2. This command is only
        needed if a password-based login is required.

        If the account with the given email already exists, then the login
        options are merged, and both the password and oauth2 login methods
        are available.
        """
      --options=[
        // The --broker flag is kept for backward compatibility. It's now a no-op
        // since all auth operations go through the broker.
        Flag "broker" --hidden,
        OptionString "server" --help="Sign up for a specific server.",
        OptionString "email"
            --help="The email address for the account."
            --required,
        OptionString "password"
            --help="The password for the account."
            --required,
      ]
      --examples=[
        Example "Sign up for an account with email and password:"
            --arguments="--email=test@example.com --password=secret",
      ]
      --run=:: sign-up it
  auth-cmd.add sign-up-cmd

  login-cmd := Command "login"
      --aliases=["signin", "log-in", "sign-in"]
      --help="""
          Log in to a broker.

          If a server is provided with '--server', authenticates with that server.
          Otherwise, authenticates with the default broker.
          See 'list' for available servers.
          """
      --options=[
        Flag "broker" --hidden,  // Kept for backward compatibility (now a no-op).
        OptionString "server" --help="Log into a specific server.",
      ] + SIGNIN-OPTIONS
      --examples=[
        Example "Log in to the default broker using GitHub:"
            --arguments=""
            --global-priority=10,
        Example """
            Log in to the default broker using GitHub without opening the link
            in a browser:"""
            --arguments="--no-open-browser",
        Example "Log in to the default broker using Google:"
            --arguments="--provider=google",
        Example "Log in with email and password:"
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

          If a server is provided with '--server', updates the account on
          that server.
          Otherwise, updates the account on the default broker.
          See 'list' for available servers.
          """
      --options=[
        Flag "broker" --hidden,  // Kept for backward compatibility (now a no-op).
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
        Log out of a broker.

        If a server is provided with '--server', logs out of that server.
        Otherwise, logs out of the default broker.
        See 'list' for available servers.
        """
      --options=[
        Flag "broker" --hidden,  // Kept for backward compatibility (now a no-op).
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
  server := invocation["server"]

  cli := invocation.cli

  server-config/ServerConfig := ?
  if server:
    server-config = get-server-from-config --cli=cli --name=server
  else:
    server-config = get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
  with-broker --cli=cli server-config: | broker/BrokerCli |
    block.call server-config.name broker

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
