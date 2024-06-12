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
      --help="Authenticate against the Artemis server."

  sign-up-cmd := cli.Command "signup"
      --aliases=["sign-up"]
      --help="""
        Sign up for an Artemis account with email and password.

        The usual way of signing up is to use oauth2. This command is only
        needed if a password-based login is required.

        If the account with the given email already exists, then the login
        options are merged, and both the password and oauth2 login methods
        are available.
        """
      --options=[
        cli.Flag "broker" --hidden --help="Sign up for the broker.",
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

  log-in-cmd := cli.Command "login"
      --aliases=["signin"]
      --help="Log in to the Artemis server."
      --options=[
        cli.Flag "broker" --hidden --help="Log into the broker.",
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
  auth-cmd.add log-in-cmd

  update-cmd := cli.Command "update"
      --help="Updates the email or password for the Artemis account."
      --options=[
        cli.Flag "broker" --hidden --help="Update the broker.",
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
      --help="Log out of the Artemis server."
      --options=[
        cli.Flag "broker" --hidden --help="Log out of the the broker.",
      ]
      --run=:: logout it config ui
  auth-cmd.add logout-cmd

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
    if exception: ui.abort exception


with-authenticatable parsed/cli.Parsed config/Config ui/Ui [block]:
  broker := parsed["broker"]
  server-config/ServerConfig := ?
  if broker:
    server-config = get-server-from-config config --key=CONFIG-BROKER-DEFAULT-KEY
    with-broker server-config config: | broker/BrokerCli |
      block.call broker
  else:
    server-config = get-server-from-config config --key=CONFIG-ARTEMIS-DEFAULT-KEY
    with-server server-config config: | server/ArtemisServerCli |
      block.call server

sign-in parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
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
      ui.info "Successfully authenticated."

sign-up parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
      email := parsed["email"]
      password := parsed["password"]
      exception := catch:
        authenticatable.sign-up --email=email --password=password
      if exception: ui.abort exception
      ui.info "Successfully signed up. Check your email for a verification link."

logout parsed/cli.Parsed config/Config ui/Ui:
  with-authenticatable parsed config ui: | authenticatable/Authenticatable |
    // A bit of a weird situation: we require to be authenticated to log out.
    authenticatable.ensure-authenticated: | error-message |
      ui.abort error-message
    exception := catch: authenticatable.logout
    if exception: ui.abort exception
    ui.info "Successfully logged out."
