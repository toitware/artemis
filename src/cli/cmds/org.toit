// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net
import uuid

import .utils_
import ..config
import ..cache
import ..server_config
import ..ui
import ..organization
import ..artemis_servers.artemis_server show with_server ArtemisServerCli
import ..utils

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
      --options=[
        cli.Flag "default"
            --default=true
            --short_help="Make this organization the default.",
      ]
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
        OptionUuid "organization-id"
            --short_help="ID of the organization."
      ]
      --run=:: show_org it config ui
  org_cmd.add show_cmd

  default_cmd := cli.Command "default"
      --long_help="""
        Show or set the default organization.

        If no ID is given, shows the current default organization.
        If an ID is given, sets the default organization.

        If the '--clear' flag is specified, clears the default organization.
        """
      --options=[
        cli.Flag "id-only" --short_help="Only show the ID of the default organization.",
        cli.Flag "clear"
            --short_help="Clear the default organization.",
      ]
      --rest=[
        OptionUuid "organization-id"
            --short_help="ID of the organization."
      ]
      --run=:: default_org it config cache ui
  org_cmd.add default_cmd

  member_cmd := cli.Command "members"
      --short_help="Manage organization members."
      --options=[
        OptionUuid "organization-id"
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
      --long_help="""
        Add a member to an organization.

        Add the member with the given user ID to an organization. The
        user ID can be found in the user's profile: 'artemis profile show'.

        If no organization ID is given, the default organization is used.
        """
      --options=[
        cli.OptionEnum "role" ["member", "admin" ]
            --short_help="Role of the member."
            --default="member"
      ]
      --rest=[
        OptionUuid "user-id"
            --short_help="ID of the user to add."
            --required,
      ]
      --run=:: member_add it config cache ui
  member_cmd.add member_add_cmd

  member_remove_cmd := cli.Command "remove"
      --short_help="Remove a member from an organization."
      --options=[
          cli.Flag "force" --short_name="f"
            --short_help="Force removal even if the user is self.",
      ]
      --rest=[
        OptionUuid "user-id"
            --short_help="ID of the user to remove."
            --required,
      ]
      --run=:: member_remove it config cache ui
  member_cmd.add member_remove_cmd

  member_set_role := cli.Command "set-role"
      --short_help="Set the role of a member."
      --rest=[
        OptionUuid "user-id"
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
  server_config = get_server_from_config config CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config: | server/ArtemisServerCli |
    server.ensure_authenticated: | error_message |
      ui.abort "$error_message (artemis)."
    block.call server

with_org_server_id parsed/cli.Parsed config/Config ui/Ui [block]:
  org_id := parsed["organization-id"]
  if not org_id:
    org_id = default_organization_from_config config
    if not org_id:
      ui.abort "No default organization set."

  with_org_server parsed config ui: | server |
    block.call server org_id

list_orgs parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server parsed config ui: | server/ArtemisServerCli |
    orgs := server.get_organizations
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          --header={"id": "ID", "name": "Name"}
          orgs.map: | org/Organization | {
            "id": "$org.id",
            "name": org.name,
          }

create_org parsed/cli.Parsed config/Config ui/Ui -> none:
  should_make_default := parsed["default"]
  with_org_server parsed config ui: | server/ArtemisServerCli |
    org := server.create_organization parsed["name"]
    ui.info "Created organization $org.id - $org.name."
    if should_make_default: make_default_ org config ui

show_org parsed/cli.Parsed config/Config ui/Ui -> none:
  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid |
    print_org org_id server ui

print_org org_id/uuid.Uuid server/ArtemisServerCli ui/Ui -> none:
  org := server.get_organization org_id
  if not org:
    ui.abort "Organization $org_id not found."
  ui.result {
    "ID": "$org.id",
    "Name": org.name,
    "Created": org.created_at,
  }

default_org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  if parsed["clear"]:
    config.remove CONFIG_ORGANIZATION_DEFAULT_KEY
    config.write
    ui.info "Default organization cleared."
    return

  org_id := parsed["organization-id"]
  if not org_id:
    id_only := parsed["id-only"]

    org_id = default_organization_from_config config
    if not org_id:
      ui.abort "No default organization set."

    if id_only:
      ui.result "$org_id"
      return

    with_org_server parsed config ui: | server/ArtemisServerCli |
      print_org org_id server ui

    return

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid |
    org/OrganizationDetailed? := null
    exception := catch: org = server.get_organization org_id
    if exception or not org:
      ui.abort "Organization not found."

    make_default_ org config ui

make_default_ org/Organization config/Config ui/Ui -> none:
    config[CONFIG_ORGANIZATION_DEFAULT_KEY] = "$org.id"
    config.write
    ui.info "Default organization set to $org.id - $org.name."

member_list parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid |
    members := server.get_organization_members org_id
    if parsed["id-only"]:
      ui.do --kind=Ui.RESULT: | printer/Printer |
        printer.emit
            --header={"id": "ID"}
            members
      return
    profiles := members.map: server.get_profile --user_id=it["id"]
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          --header={"id": "ID", "role": "Role", "name": "Name", "email": "Email"}
          List members.size: {
            "id": "$members[it]["id"]",
            "role": members[it]["role"],
            "name": profiles[it]["name"],
            "email": profiles[it]["email"],
          }

member_add parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  role := parsed["role"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid|
    server.organization_member_add
        --organization_id=org_id
        --user_id=user_id
        --role=role
    ui.info "Added user $user_id to organization $org_id."

member_remove parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  force := parsed["force"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid |
    if not force:
      current_user_id := server.get_current_user_id
      if user_id == current_user_id:
        ui.abort "Use '--force' to remove yourself from an organization."
    server.organization_member_remove --organization_id=org_id --user_id=user_id
    ui.info "Removed user $user_id from organization $org_id."

member_set_role parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user_id := parsed["user-id"]
  role := parsed["role"]

  with_org_server_id parsed config ui: | server/ArtemisServerCli org_id/uuid.Uuid|
    server.organization_member_set_role
        --organization_id=org_id
        --user_id=user_id
        --role=role
    ui.info "Set role of user $user_id to $role in organization $org_id."
