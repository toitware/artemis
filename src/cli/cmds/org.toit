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

  show_cmd := cli.Command "show"
      --short_help="Show details of an organization."
      --rest=[
        // TODO(florian): would be nice to accept a name here as well.
        cli.OptionString "id"
            --short_help="ID of the organization."
            --required,
      ]
      --run=:: show_org it config ui
  org_cmd.add show_cmd

  use_cmd := cli.Command "use"
      --long_help="""
        Set the default organization.

        If no ID is given, clears the default organization.
        """
      --rest=[
        cli.OptionString "id"
            --short_help="ID of the organization."
      ]
      --run=:: use_org it config cache ui
  org_cmd.add use_cmd

  default_cmd := cli.Command "default"
      --short_help="Show the default organization."
      --options=[
        cli.Flag "id-only" --short_help="Only show the ID of the default organization."
      ]
      --run=:: default_org it config cache ui
  org_cmd.add default_cmd

  // TODO(florian): add 'delete', and member commands.
  return [org_cmd]

with_org_server parsed/cli.Parsed config/Config [block]:
  server_config/ServerConfig := ?
  server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config block

list_orgs parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config: | server/ArtemisServerCli |
    orgs := server.get_organizations
    ui.info_table --header=["ID", "Name"]
        orgs.map: [ it.id, it.name ]

create_org parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config: | server/ArtemisServerCli |
    org := server.create_organization parsed["name"]
    ui.info "Created organization $org.id - $org.name"

show_org parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config: | server/ArtemisServerCli |
    print_org parsed["id"] server ui

print_org id/string server/ArtemisServerCli ui/Ui -> none:
  org := server.get_organization id
  ui.info_map {
    "ID": org.id,
    "Name": org.name,
    "Created": org.created_at,
  }

use_org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  id := parsed["id"]
  if not id:
    config.remove CONFIG_ORGANIZATION_DEFAULT
    config.write
    ui.info "Default organization cleared."
    return

  with_org_server parsed config: | server/ArtemisServerCli |
    org := server.get_organization id
    if not org:
      ui.error "Organization not found."
      exit 1

    config[CONFIG_ORGANIZATION_DEFAULT] = org.id
    config.write
    ui.info "Default organization set to $org.id - $org.name"

default_org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  id_only := parsed["id-only"]

  organization_id := config.get CONFIG_ORGANIZATION_DEFAULT
  if not organization_id:
    ui.error "No default organization set."
    exit 1

  if id_only:
    ui.info "$organization_id"
    return

  with_org_server parsed config: | server/ArtemisServerCli |
    print_org organization_id server ui
