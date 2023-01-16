// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net

import ..config
import ..cache
import ..server_config
import ..ui
import ..organization
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
      --long_help="""
        Show details of an organization.

        If no ID is given, shows the default organization.
        """
      --options=[
        // TODO(florian): would be nice to accept a name here as well.
        cli.OptionString "org-id"
            --short_help="ID of the organization."
      ]
      --run=:: show_org it config ui
  org_cmd.add show_cmd

  use_cmd := cli.Command "use"
      --long_help="""
        Set the default organization.

        If no ID is given, clears the default organization.
        """
      --rest=[
        cli.OptionString "org-id"
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

  member_cmd := cli.Command "members"
      --short_help="Manage organization members."
      --options=[
        cli.OptionString "org-id"
            --short_help="ID of the organization."
      ]
  org_cmd.add member_cmd

  member_list_cmd := cli.Command "list"
      --short_help="List members of an organization."
      --options=[
        cli.Flag "id-only" --short_help="Only show the IDs of the members."
      ]
      --run=:: member_list it config cache ui
  member_cmd.add member_list_cmd

  member_add_cmd := cli.Command "add"
      --short_help="Add a member to an organization."
      --options=[
        cli.OptionEnum "role" ["member", "admin" ]
            --short_help="Role of the member."
            --default="member"
      ]
      --rest=[
        cli.OptionString "user-id"
            --short_help="ID of the user to add."
            --required,
      ]
      --run=:: member_add it config cache ui
  member_cmd.add member_add_cmd

  member_remove_cmd := cli.Command "remove"
      --short_help="Remove a member from an organization."
      --rest=[
        cli.OptionString "user-id"
            --short_help="ID of the user to remove."
            --required,
        cli.Flag "force" --short_name="f"
            --short_help="Force removal even if the user is self."
      ]
      --run=:: member_remove it config cache ui
  member_cmd.add member_remove_cmd

  member_set_role := cli.Command "set-role"
      --short_help="Set the role of a member."
      --rest=[
        cli.OptionString "user-id"
            --short_help="ID of the user to add."
            --required,
        cli.OptionEnum "role" ["member", "admin" ]
            --short_help="Role of the member."
            --required,
      ]
      --run=:: member_set_role it config cache ui
  member_cmd.add member_set_role

  return [org_cmd]

with_org_server parsed/cli.Parsed config/Config ui/Ui [block]:
  server_config/ServerConfig := ?
  server_config = get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config: | server/ArtemisServerCli |
    server.ensure_authenticated:
      ui.error "Not logged in."
      // TODO(florian): another PR is already out that changes this to 'ui.abort'
      exit 1
    block.call server

with_org_server_id parsed/cli.Parsed config/Config ui/Ui [block]:
  org_id := parsed["org-id"]
  if not org_id:
    org_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not org_id:
      ui.error "No default organization set."
      ui.abort

  with_org_server parsed config ui: | server |
    block.call server org_id

list_orgs parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config ui: | server/ArtemisServerCli |
    orgs := server.get_organizations
    ui.info_table --header=["ID", "Name"]
        orgs.map: [ it.id, it.name ]

create_org parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config ui: | server/ArtemisServerCli |
    org := server.create_organization parsed["name"]
    ui.info "Created organization $org.id - $org.name"

show_org parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string |
    print_org org_id server ui

print_org org_id/string server/ArtemisServerCli ui/Ui -> none:
  org := server.get_organization org_id
  ui.info_map {
    "ID": org.id,
    "Name": org.name,
    "Created": org.created_at,
  }

use_org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string |
    org/DetailedOrganization? := null
    exception := catch: org = server.get_organization org_id
    if exception or not org:
      ui.error "Organization not found."
      ui.abort

    config[CONFIG_ORGANIZATION_DEFAULT] = org.id
    config.write
    ui.info "Default organization set to $org.id - $org.name"

default_org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  id_only := parsed["id-only"]

  org_id := config.get CONFIG_ORGANIZATION_DEFAULT
  if not org_id:
    ui.error "No default organization set."
    ui.abort

  if id_only:
    ui.info "$org_id"
    return

  with_org_server parsed config ui: | server/ArtemisServerCli |
    print_org org_id server ui

member_list parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string |
    members := server.get_organization_members org_id
    if parsed["id-only"]:
      ui.info_table --header=["ID"]
          members.map: [ it["id"] ]
      return
    profiles := members.map: server.get_profile --user_id=it["id"]
    ui.info_table --header=["ID", "Role", "Name", "Email"]
        List members.size:
          id := members[it]["id"]
          role := members[it]["role"]
          name := profiles[it]["name"]
          email := profiles[it]["email"]
          [ id, role, name, email ]

member_add parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  role := parsed["role"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string|
    server.organization_member_add
        --organization_id=org_id
        --user_id=user_id
        --role=role
    ui.info "Added user $user_id to organization $org_id."

member_remove parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  force := parsed["force"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string |
    if not force:
      current_user_id := server.get_current_user_id
      if user_id == current_user_id:
        ui.error "Use '--force' to remove yourself from an organization."
        ui.abort
    server.organization_member_remove --organization_id=org_id --user_id=user_id
    ui.info "Removed user $user_id from organization $org_id."

member_set_role parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  role := parsed["role"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/string|
    server.organization_member_set_role
        --organization_id=org_id
        --user_id=user_id
        --role=role
    ui.info "Set role of user $user_id to $role in organization $org_id."
