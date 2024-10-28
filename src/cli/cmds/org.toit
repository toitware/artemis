// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show *
import net
import uuid show Uuid

import .utils_
import ..config
import ..cache
import ..server-config
import ..organization
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import ..utils

create-org-commands -> List:
  org-cmd := Command "org"
      --help="Manage organizations."
      --options=[
        OptionString "server" --hidden --help="The server to use.",
      ]

  list-cmd := Command "list"
      --aliases=["ls"]
      --help="List organizations."
      --run=:: list-orgs it
  org-cmd.add list-cmd

  add-cmd := Command "add"
      --aliases=["create"]
      --help="Create a new organization."
      --options=[
        Flag "default"
            --default=true
            --help="Make this organization the default.",
      ]
      --rest=[
        OptionString "name"
            --help="Name of the organization."
            --required,
      ]
      --examples=[
        Example "Create a new organization called 'in-the-sea', and make it the default:"
            --arguments="in-the-sea"
            --global-priority=9,
      ]
      --run=:: add-org it
  org-cmd.add add-cmd

  show-cmd := Command "show"
      --help="""
        Show details of an organization.

        If no ID is given, shows the default organization.
        """
      --rest=[
        // TODO(florian): would be nice to accept a name here as well.
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
      --examples=[
        Example "Show the default organization:"
            --arguments="",
        Example "Show the organization with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: show-org it
  org-cmd.add show-cmd

  default-cmd := Command "default"
      --help="""
        Show or set the default organization.

        If no ID is given, shows the current default organization.
        If an ID is given, sets the default organization.

        If the '--clear' flag is specified, clears the default organization.
        """
      --options=[
        Flag "id-only" --help="Only show the ID of the default organization.",
        Flag "clear"
            --help="Clear the default organization.",
      ]
      --rest=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
      --examples=[
        Example "Show the default organization:"
            --arguments="",
        Example "Set the default organization to the one with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        Example "Clear the default organization:"
            --arguments="--clear",
      ]
      --run=:: default-org it
  org-cmd.add default-cmd

  update-cmd := Command "update"
      --help="""
      Update an organization.

      If no ID is given, updates the default organization.
      """
      --options=[
        OptionString "name"
            --help="Name of the organization."
      ]
      --rest=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
      --examples=[
        Example "Update the default organization to be called 'in-the-air':"
            --arguments="--name=in-the-air ",
        Example """
            Update the organization with ID 12345678-1234-1234-1234-123456789abc to be
            called 'obsolete':"""
            --arguments="--name=obsolete 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: update-org it
  org-cmd.add update-cmd

  member-cmd := Command "members"
      --help="Manage organization members."
      --options=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
  org-cmd.add member-cmd

  member-list-cmd := Command "list"
      --help="List members of an organization."
      --options=[
        Flag "id-only" --help="Only show the IDs of the members."
      ]
      --examples=[
        Example "List members of the default organization:"
            --arguments="",
        Example "List members of the organization with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="--organization-id 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: member-list it
  member-cmd.add member-list-cmd

  member-add-cmd := Command "add"
      --help="""
        Add a member to an organization.

        Add the member with the given user ID to an organization. The
        user ID can be found in the user's profile: 'artemis profile show'.

        If no organization ID is given, the default organization is used.
        """
      --options=[
        OptionEnum "role" ["member", "admin" ]
            --help="Role of the member."
            --default="member"
      ]
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to add."
            --required,
      ]
      --examples=[
        Example "Add user with ID 12345678-1234-1234-1234-123456789abc to the default organization:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        Example """
            Add user with ID 11111111-2222-3333-444444444444 as admin to organization
            12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc --role=admin 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: member-add it
  member-cmd.add member-add-cmd

  member-remove-cmd := Command "remove"
      --help="Remove a member from an organization."
      --options=[
          Flag "force" --short-name="f"
            --help="Force removal even if the user is self.",
      ]
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to remove."
            --required,
      ]
      --examples=[
        Example "Remove user with ID 12345678-1234-1234-1234-123456789abc from the default organization:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        Example """
            Remove user with ID 11111111-2222-3333-444444444444 from organization
            12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc 11111111-2222-3333-444444444444",
      ]
      --run=:: member-remove it
  member-cmd.add member-remove-cmd

  member-set-role := Command "set-role"
      --help="Set the role of a member."
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to add."
            --required,
        OptionEnum "role" ["member", "admin" ]
            --help="Role of the member."
            --required,
      ]
      --examples=[
        Example """
            Set the role of user with ID 12345678-1234-1234-1234-123456789abc to admin in
            the default organization:"""
            --arguments="12345678-1234-1234-1234-123456789abc admin",
        Example """
            Set the role of user with ID 11111111-2222-3333-444444444444 to member (non-admin) in
            organization 12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc 11111111-2222-3333-444444444444 member",
      ]
      --run=:: member-set-role it
  member-cmd.add member-set-role

  return [org-cmd]

with-org-server invocation/Invocation [block]:
  cli := invocation.cli
  ui := cli.ui

  server-config/ServerConfig := ?
  server-config = get-server-from-config --key=CONFIG-ARTEMIS-DEFAULT-KEY --cli=cli

  with-server server-config --cli=cli: | server/ArtemisServerCli |
    server.ensure-authenticated: | error-message |
      ui.abort "$error-message (artemis)."
    block.call server

with-org-server-id invocation/Invocation [block]:
  org-id := invocation["organization-id"]

  cli := invocation.cli
  ui := cli.ui

  if not org-id:
    org-id = default-organization-from-config --cli=cli
    if not org-id:
      ui.abort "No default organization set."

  with-org-server invocation: | server |
    block.call server org-id

list-orgs invocation/Invocation -> none:
  with-org-server invocation: | server/ArtemisServerCli |
    orgs := server.get-organizations
    invocation.cli.ui.emit-table --result
          --header={"id": "ID", "name": "Name"}
          orgs.map: | org/Organization | {
            "id": "$org.id",
            "name": org.name,
          }

add-org invocation/Invocation -> none:
  should-make-default := invocation["default"]
  with-org-server invocation: | server/ArtemisServerCli |
    org := server.create-organization invocation["name"]
    invocation.cli.ui.emit --info "Added organization $org.id - $org.name."
    if should-make-default: make-default_ org --cli=invocation.cli

show-org invocation/Invocation -> none:
  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid |
    print-org org-id server --cli=invocation.cli

print-org org-id/Uuid server/ArtemisServerCli --cli/Cli -> none:
  ui := cli.ui
  org := server.get-organization org-id
  if not org:
    ui.abort "Organization $org-id not found."
  if ui.wants-structured --kind=Ui.RESULT:
    ui.emit
        --kind=Ui.RESULT
        --structured=: {
          "id": "$org.id",
          "name": org.name,
          "created": "$org.created-at",
        }
        --text=: unreachable
  else:
    ui.emit-map --result {
      "Id": "$org.id",
      "Name": org.name,
      "Created": "$org.created-at",
    }

default-org invocation/Invocation -> none:
  cli := invocation.cli
  config := cli.config
  ui := cli.ui

  if invocation["clear"]:
    config.remove CONFIG-ORGANIZATION-DEFAULT-KEY
    config.write
    ui.emit --info "Default organization cleared."
    return

  org-id := invocation["organization-id"]
  if not org-id:
    id-only := invocation["id-only"]

    org-id = default-organization-from-config --cli=cli
    if not org-id:
      ui.abort "No default organization set."

    if id-only:
      ui.emit --result "$org-id"
      return

    with-org-server invocation: | server/ArtemisServerCli |
      print-org org-id server --cli=cli

    return

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid |
    org/OrganizationDetailed? := null
    exception := catch: org = server.get-organization org-id
    if exception or not org:
      ui.abort "Organization not found."

    make-default_ org --cli=cli

make-default_ org/Organization --cli/Cli -> none:
  config := cli.config
  ui := cli.ui

  config[CONFIG-ORGANIZATION-DEFAULT-KEY] = "$org.id"
  config.write
  ui.emit --info "Default organization set to $org.id - $org.name."

update-org invocation/Invocation -> none:
  ui := invocation.cli.ui

  name := invocation["name"]
  if not name: ui.abort "No name provided."
  if name == "": ui.abort "Name cannot be empty."

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid |
    server.update-organization org-id --name=name
    ui.emit --info "Updated organization $org-id."

member-list invocation/Invocation -> none:
  ui := invocation.cli.ui

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid |
    members := server.get-organization-members org-id
    if invocation["id-only"]:
      member-ids := members.map: "$it["id"]"
      member-ids.sort --in-place
      ui.emit-list member-ids --kind=Ui.RESULT
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

    ui.emit-table --result
        --header={"id": "ID", "role": "Role", "name": "Name", "email": "Email"}
        result

member-add invocation/Invocation -> none:
  ui := invocation.cli.ui

  user-id := invocation["user-id"]
  role := invocation["role"]

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid|
    existing-members := server.get-organization-members org-id
    if (existing-members.any: it["id"] == user-id):
      ui.abort "User $user-id is already a member of organization $org-id."
    server.organization-member-add
        --organization-id=org-id
        --user-id=user-id
        --role=role
    ui.emit --info "Added user $user-id to organization $org-id."

member-remove invocation/Invocation -> none:
  ui := invocation.cli.ui

  user-id := invocation["user-id"]
  force := invocation["force"]

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid |
    if not force:
      current-user-id := server.get-current-user-id
      if user-id == current-user-id:
        ui.abort "Use '--force' to remove yourself from an organization."
    server.organization-member-remove --organization-id=org-id --user-id=user-id
    ui.emit --info "Removed user $user-id from organization $org-id."

member-set-role invocation/Invocation -> none:
  ui := invocation.cli.ui

  user-id := invocation["user-id"]
  role := invocation["role"]

  with-org-server-id invocation: | server/ArtemisServerCli org-id/Uuid|
    server.organization-member-set-role
        --organization-id=org-id
        --user-id=user-id
        --role=role
    ui.emit --info "Set role of user $user-id to $role in organization $org-id."
