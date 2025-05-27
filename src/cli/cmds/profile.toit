// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show *
import net

import ..config
import ..cache
import ..server-config
import ..artemis-servers.artemis-server show with-server ArtemisServerCli

create-profile-commands -> List:
  profile-cmd := Command "profile"
      --help="Manage the user profile."
      --options=[
        OptionString "server" --hidden --help="The server to use.",
      ]

  show-cmd := Command "show"
      --help="Show the profile."
      --run=:: show-profile it
  profile-cmd.add show-cmd

  update-cmd := Command "update"
      --help="Update the profile."
      --options=[
        OptionString "name",
        // TODO(florian): support changing the email.
      ]
      --examples=[
        Example "Update the name"
            --arguments="--name=\"John Doe\""
      ]
      --run=:: update-profile it
  profile-cmd.add update-cmd

  return [profile-cmd]

with-profile-server invocation/Invocation [block]:
  cli := invocation.cli

  server-config := get-server-from-config --key=CONFIG-ARTEMIS-DEFAULT-KEY --cli=cli

  with-server server-config --cli=cli: | server/ArtemisServerCli |
    server.ensure-authenticated: | error-message |
      cli.ui.abort "$error-message (artemis)."
    block.call server

show-profile invocation/Invocation:
  ui := invocation.cli.ui
  with-profile-server invocation: | server/ArtemisServerCli |
    profile := server.get-profile
    if ui.wants-structured --kind=Ui.RESULT:
      // We recreate the map, so we don't show unnecessary entries.
      ui.emit
          --result
          --structured=: {
            "id": "$profile["id"]",
            "name": profile["name"],
            "email": profile["email"],
          }
    else:
      ui.emit-map --result {
        "ID": "$profile["id"]",
        "Name": profile["name"],
        "Email": profile["email"],
      }


update-profile invocation/Invocation:
  ui := invocation.cli.ui

  name := invocation["name"]
  if not name:
    ui.abort "No name specified."

  with-profile-server invocation: | server/ArtemisServerCli |
    server.update-profile --name=name
    ui.emit --info "Profile updated."
