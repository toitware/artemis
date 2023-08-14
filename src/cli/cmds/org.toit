// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import net
import uuid

import .utils_
import ..config
import ..cache
import ..server-config
import ..ui
import ..organization
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import ..utils

create-org-commands config/Config cache/Cache ui/Ui -> List:
  org-cmd := cli.Command "org"
      --short-help="Manage organizations."
      --options=[
        cli.OptionString "server" --hidden --short-help="The server to use.",
      ]

  list-cmd := cli.Command "list"
      --short-help="List organizations."
      --run=:: list-orgs it config ui
  org-cmd.add list-cmd

  create-cmd := cli.Command "create"
      --short-help="Create a new organization."
      --options=[
        cli.Flag "default"
            --default=true
            --short-help="Make this organization the default.",
      ]
      --rest=[
        cli.OptionString "name"
            --short-help="Name of the organization."
            --required,
      ]
      --run=:: create-org it config ui
  org-cmd.add create-cmd

  show-cmd := cli.Command "show"
      --long-help="""
        Show details of an organization.

        If no ID is given, shows the default organization.
        """
      --rest=[
        // TODO(florian): would be nice to accept a name here as well.
        OptionUuid "organization-id"
            --short-help="ID of the organization."
      ]
      --run=:: show-org it config ui
  org-cmd.add show-cmd

  default-cmd := cli.Command "default"
      --long-help="""
        Show or set the default organization.

        If no ID is given, shows the current default organization.
        If an ID is given, sets the default organization.

        If the '--clear' flag is specified, clears the default organization.
        """
      --options=[
        cli.Flag "id-only" --short-help="Only show the ID of the default organization.",
        cli.Flag "clear"
            --short-help="Clear the default organization.",
      ]
      --rest=[
        OptionUuid "organization-id"
            --short-help="ID of the organization."
      ]
      --run=:: default-org it config cache ui
  org-cmd.add default-cmd

  update-cmd := cli.Command "update"
      --short-help="Update an organization."
      --options=[
        cli.OptionString "name"
            --short-help="Name of the organization."
      ]
      --rest=[
        OptionUuid "organization-id"
            --short-help="ID of the organization."
      ]
      --run=:: update-org it config ui
  org-cmd.add update-cmd

  member-cmd := cli.Command "members"
      --short-help="Manage organization members."
      --options=[
        OptionUuid "organization-id"
            --short-help="ID of the organization."
      ]
  org-cmd.add member-cmd

  member-list-cmd := cli.Command "list"
      --short-help="List members of an organization."
      --options=[
        cli.Flag "id-only" --short-help="Only show the IDs of the members."
      ]
      --run=:: member-list it config cache ui
  member-cmd.add member-list-cmd

  member-add-cmd := cli.Command "add"
      --long-help="""
        Add a member to an organization.

        Add the member with the given user ID to an organization. The
        user ID can be found in the user's profile: 'artemis profile show'.

        If no organization ID is given, the default organization is used.
        """
      --options=[
        cli.OptionEnum "role" ["member", "admin" ]
            --short-help="Role of the member."
            --default="member"
      ]
      --rest=[
        OptionUuid "user-id"
            --short-help="ID of the user to add."
            --required,
      ]
      --run=:: member-add it config cache ui
  member-cmd.add member-add-cmd

  member-remove-cmd := cli.Command "remove"
      --short-help="Remove a member from an organization."
      --options=[
          cli.Flag "force" --short-name="f"
            --short-help="Force removal even if the user is self.",
      ]
      --rest=[
        OptionUuid "user-id"
            --short-help="ID of the user to remove."
            --required,
      ]
      --run=:: member-remove it config cache ui
  member-cmd.add member-remove-cmd

  member-set-role := cli.Command "set-role"
      --short-help="Set the role of a member."
      --rest=[
        OptionUuid "user-id"
            --short-help="ID of the user to add."
            --required,
        cli.OptionEnum "role" ["member", "admin" ]
            --short-help="Role of the member."
            --required,
      ]
      --run=:: member-set-role it config cache ui
  member-cmd.add member-set-role

  return [org-cmd]

with-org-server parsed/cli.Parsed config/Config ui/Ui [block]:
  server-config/ServerConfig := ?
  server-config = get-server-from-config config CONFIG-ARTEMIS-DEFAULT-KEY

  with-server server-config config: | server/ArtemisServerCli |
    server.ensure-authenticated: | error-message |
      ui.abort "$error-message (artemis)."
    block.call server

with-org-server-id parsed/cli.Parsed config/Config ui/Ui [block]:
  org-id := parsed["organization-id"]
  if not org-id:
    org-id = default-organization-from-config config
    if not org-id:
      ui.abort "No default organization set."

  with-org-server parsed config ui: | server |
    block.call server org-id

list-orgs parsed/cli.Parsed config/Config ui/Ui -> none:
  with-org-server parsed config ui: | server/ArtemisServerCli |
    orgs := server.get-organizations
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          --header={"id": "ID", "name": "Name"}
          orgs.map: | org/Organization | {
            "id": "$org.id",
            "name": org.name,
          }

create-org parsed/cli.Parsed config/Config ui/Ui -> none:
  should-make-default := parsed["default"]
  with-org-server parsed config ui: | server/ArtemisServerCli |
    org := server.create-organization parsed["name"]
    ui.info "Created organization $org.id - $org.name."
    if should-make-default: make-default_ org config ui

show-org parsed/cli.Parsed config/Config ui/Ui -> none:
  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid |
    print-org org-id server ui

print-org org-id/uuid.Uuid server/ArtemisServerCli ui/Ui -> none:
  org := server.get-organization org-id
  if not org:
    ui.abort "Organization $org-id not found."
  ui.do --kind=Ui.RESULT: | printer/Printer |
    printer.emit-structured
        --json=: {
          "id": "$org.id",
          "name": org.name,
          "created": "$org.created-at",
        }
        --stdout=: | p/Printer | p.emit {
          "Id": "$org.id",
          "Name": org.name,
          "Created": "$org.created-at",
        }

default-org parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  if parsed["clear"]:
    config.remove CONFIG-ORGANIZATION-DEFAULT-KEY
    config.write
    ui.info "Default organization cleared."
    return

  org-id := parsed["organization-id"]
  if not org-id:
    id-only := parsed["id-only"]

    org-id = default-organization-from-config config
    if not org-id:
      ui.abort "No default organization set."

    if id-only:
      ui.result "$org-id"
      return

    with-org-server parsed config ui: | server/ArtemisServerCli |
      print-org org-id server ui

    return

  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid |
    org/OrganizationDetailed? := null
    exception := catch: org = server.get-organization org-id
    if exception or not org:
      ui.abort "Organization not found."

    make-default_ org config ui

make-default_ org/Organization config/Config ui/Ui -> none:
    config[CONFIG-ORGANIZATION-DEFAULT-KEY] = "$org.id"
    config.write
    ui.info "Default organization set to $org.id - $org.name."

update-org parsed/cli.Parsed config/Config ui/Ui -> none:
  name := parsed["name"]
  if not name: ui.abort "No name provided."
  if name == "": ui.abort "Name cannot be empty."

  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid |
    server.update-organization org-id --name=name
    ui.info "Updated organization $org-id."

member-list parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid |
    members := server.get-organization-members org-id
    if parsed["id-only"]:
      member-ids := members.map: "$it["id"]"
      member-ids.sort --in-place
      ui.do --kind=Ui.RESULT: | printer/Printer |
        printer.emit member-ids
      return
    profiles := members.map: server.get-profile --user-id=it["id"]
    unsorted-result := List members.size: {
      "id": "$members[it]["id"]",
      "role": members[it]["role"],
      "name": profiles[it]["name"],
      "email": profiles[it]["email"],
    }
    result := unsorted-result.sort: | a/Map b/Map |
      // "admin" is < "member", so we can use 'compare_to'.
      a["role"].compare-to b["role"] --if-equal=:
        a["email"].compare-to b["email"] --if-equal=:
          a["name"].compare-to b["name"] --if-equal=:
            a["id"].compare-to b["id"]

    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          --header={"id": "ID", "role": "Role", "name": "Name", "email": "Email"}
          result

member-add parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user-id := parsed["user-id"]
  role := parsed["role"]

  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid|
    existing-members := server.get-organization-members org-id
    if (existing-members.any: it["id"] == user-id):
      ui.abort "User $user-id is already a member of organization $org-id."
    server.organization-member-add
        --organization-id=org-id
        --user-id=user-id
        --role=role
    ui.info "Added user $user-id to organization $org-id."

member-remove parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user-id := parsed["user-id"]
  force := parsed["force"]

  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid |
    if not force:
      current-user-id := server.get-current-user-id
      if user-id == current-user-id:
        ui.abort "Use '--force' to remove yourself from an organization."
    server.organization-member-remove --organization-id=org-id --user-id=user-id
    ui.info "Removed user $user-id from organization $org-id."

member-set-role parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  user-id := parsed["user-id"]
  role := parsed["role"]

  with-org-server-id parsed config ui: | server/ArtemisServerCli org-id/uuid.Uuid|
    server.organization-member-set-role
        --organization-id=org-id
        --user-id=user-id
        --role=role
    ui.info "Set role of user $user-id to $role in organization $org-id."
