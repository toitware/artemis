// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net

import ..config
import ..cache
import ..server_config
import ..ui
import ..artemis_servers.artemis_server show with_server ArtemisServerCli

create_profile_commands config/Config cache/Cache ui/Ui -> List:
  profile_cmd := cli.Command "profile"
      --short_help="Manage the user profile."
      --options=[
        cli.OptionString "server" --hidden --short_help="The server to use.",
      ]

  show_cmd := cli.Command "show"
      --short_help="Shows the profile."
      --run=:: show_profile it config ui
  profile_cmd.add show_cmd

  update_cmd := cli.Command "update"
      --short_help="Updates the profile."
      --options=[
        cli.OptionString "name",
        // TODO(florian): support changing the email.
      ]
      --run=:: update_profile it config ui
  profile_cmd.add update_cmd

  return [profile_cmd]

with_profile_server parsed/cli.Parsed config/Config ui/Ui [block]:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config: | server/ArtemisServerCli |
    server.ensure_authenticated:
      ui.error "Not logged in."
      ui.abort
    block.call server

show_profile parsed/cli.Parsed config/Config ui/Ui:
  with_profile_server parsed config ui: | server/ArtemisServerCli |
    profile := server.get_profile
    // We recreate the map, so we don't show unnecessary entries.
    ui.info_map {
      "id": profile["id"],
      "name": profile["name"],
      "email": profile["email"],
    }

update_profile parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  if not name:
    ui.error "No name specified."
    ui.abort

  with_profile_server parsed config ui: | server/ArtemisServerCli |
    server.update_profile --name=name
    ui.info "Profile updated."
