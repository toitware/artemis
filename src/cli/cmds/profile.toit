// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net

import ..config
import ..cache
import ..server-config
import ..ui
import ..artemis-servers.artemis-server show with-server ArtemisServerCli

create-profile-commands config/Config cache/Cache ui/Ui -> List:
  profile-cmd := cli.Command "profile"
      --help="Manage the user profile."
      --options=[
        cli.OptionString "server" --hidden --help="The server to use.",
      ]

  show-cmd := cli.Command "show"
      --help="Show the profile."
      --run=:: show-profile it config ui
  profile-cmd.add show-cmd

  update-cmd := cli.Command "update"
      --help="Update the profile."
      --options=[
        cli.OptionString "name",
        // TODO(florian): support changing the email.
      ]
      --examples=[
        cli.Example "Update the name"
            --arguments="--name=John Doe"
      ]
      --run=:: update-profile it config ui
  profile-cmd.add update-cmd

  return [profile-cmd]

with-profile-server parsed/cli.Parsed config/Config ui/Ui [block]:
  server-config := get-server-from-config config --key=CONFIG-ARTEMIS-DEFAULT-KEY

  with-server server-config config: | server/ArtemisServerCli |
    server.ensure-authenticated: | error-message |
      ui.abort "$error-message (artemis)."
    block.call server

show-profile parsed/cli.Parsed config/Config ui/Ui:
  with-profile-server parsed config ui: | server/ArtemisServerCli |
    profile := server.get-profile
    // We recreate the map, so we don't show unnecessary entries.
    ui.result {
      "id": profile["id"],
      "name": profile["name"],
      "email": profile["email"],
    }

update-profile parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  if not name:
    ui.abort "No name specified."

  with-profile-server parsed config ui: | server/ArtemisServerCli |
    server.update-profile --name=name
    ui.info "Profile updated."
