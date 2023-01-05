// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net

import ..config
import ..cache
import ..server_config
import ..ui
import ..artemis_servers.artemis_server show with_server ArtemisServerCli

create_org_commands config/Config cache/Cache ui/Ui -> List:
  org_cmd := cli.Command "org"
      --short_help="Manage organizations."
      --options=[
        cli.OptionString "server" --hidden --short_help="The server to use.",
      ]

  list_cmd := cli.Command "list"
      --short_help="List organizations."
      --run=:: list_orgs it config ui
  org_cmd.add list_cmd

  create_cmd := cli.Command "create"
      --short_help="Create a new organization."
      --rest=[
        cli.OptionString "name"
            --short_help="Name of the organization."
            --required,
      ]
      --run=:: create_org it config ui
  org_cmd.add create_cmd

  // TODO(florian): add 'show', 'use', 'default', 'delete', and member commands.

  return [org_cmd]

list_orgs parsed/cli.Parsed config/Config ui/Ui -> none:
  server_config/ServerConfig := ?
  server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config: | server/ArtemisServerCli |
    orgs := server.get_organizations
    ui.info_table --header=["ID", "Name"]
        orgs.map: [ it.id, it.name ]

create_org parsed/cli.Parsed config/Config ui/Ui -> none:
  server_config/ServerConfig := ?
  server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config: | server/ArtemisServerCli |
    org := server.create_organization parsed["name"]
    ui.info "Created organization $org.id - $org.name"
