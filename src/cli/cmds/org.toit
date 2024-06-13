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
      --help="Manage organizations."
      --options=[
        cli.OptionString "server" --hidden --help="The server to use.",
      ]

  list-cmd := cli.Command "list"
      --aliases=["ls"]
      --help="List organizations."
      --run=:: list-orgs it config ui
  org-cmd.add list-cmd

  add-cmd := cli.Command "add"
      --aliases=["create"]
      --help="Create a new organization."
      --options=[
        cli.Flag "default"
            --default=true
            --help="Make this organization the default.",
      ]
      --rest=[
        cli.OptionString "name"
            --help="Name of the organization."
            --required,
      ]
      --examples=[
        cli.Example "Create a new organization called 'in-the-sea', and make it the default:"
            --arguments="in-the-sea"
            --global-priority=9,
      ]
      --run=:: add-org it config ui
  org-cmd.add add-cmd

  show-cmd := cli.Command "show"
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
        cli.Example "Show the default organization:"
            --arguments="",
        cli.Example "Show the organization with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: show-org it config ui
  org-cmd.add show-cmd

  default-cmd := cli.Command "default"
      --help="""
        Show or set the default organization.

        If no ID is given, shows the current default organization.
        If an ID is given, sets the default organization.

        If the '--clear' flag is specified, clears the default organization.
        """
      --options=[
        cli.Flag "id-only" --help="Only show the ID of the default organization.",
        cli.Flag "clear"
            --help="Clear the default organization.",
      ]
      --rest=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
      --examples=[
        cli.Example "Show the default organization:"
            --arguments="",
        cli.Example "Set the default organization to the one with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        cli.Example "Clear the default organization:"
            --arguments="--clear",
      ]
      --run=:: default-org it config cache ui
  org-cmd.add default-cmd

  update-cmd := cli.Command "update"
      --help="""
      Update an organization.

      If no ID is given, updates the default organization.
      """
      --options=[
        cli.OptionString "name"
            --help="Name of the organization."
      ]
      --rest=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
      --examples=[
        cli.Example "Update the default organization to be called 'in-the-air':"
            --arguments="--name=in-the-air ",
        cli.Example """
            Update the organization with ID 12345678-1234-1234-1234-123456789abc to be
            called 'obsolete':"""
            --arguments="--name=obsolete 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: update-org it config ui
  org-cmd.add update-cmd

  member-cmd := cli.Command "members"
      --help="Manage organization members."
      --options=[
        OptionUuid "organization-id"
            --help="ID of the organization."
      ]
  org-cmd.add member-cmd

  member-list-cmd := cli.Command "list"
      --help="List members of an organization."
      --options=[
        cli.Flag "id-only" --help="Only show the IDs of the members."
      ]
      --examples=[
        cli.Example "List members of the default organization:"
            --arguments="",
        cli.Example "List members of the organization with ID 12345678-1234-1234-1234-123456789abc:"
            --arguments="12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: member-list it config cache ui
  member-cmd.add member-list-cmd

  member-add-cmd := cli.Command "add"
      --help="""
        Add a member to an organization.

        Add the member with the given user ID to an organization. The
        user ID can be found in the user's profile: 'artemis profile show'.

        If no organization ID is given, the default organization is used.
        """
      --options=[
        cli.OptionEnum "role" ["member", "admin" ]
            --help="Role of the member."
            --default="member"
      ]
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to add."
            --required,
      ]
      --examples=[
        cli.Example "Add user with ID 12345678-1234-1234-1234-123456789abc to the default organization:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        cli.Example """
            Add user with ID 11111111-2222-3333-444444444444 as admin to organization
            12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc --role=admin 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: member-add it config cache ui
  member-cmd.add member-add-cmd

  member-remove-cmd := cli.Command "remove"
      --help="Remove a member from an organization."
      --options=[
          cli.Flag "force" --short-name="f"
            --help="Force removal even if the user is self.",
      ]
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to remove."
            --required,
      ]
      --examples=[
        cli.Example "Remove user with ID 12345678-1234-1234-1234-123456789abc from the default organization:"
            --arguments="12345678-1234-1234-1234-123456789abc",
        cli.Example """
            Remove user with ID 11111111-2222-3333-444444444444 from organization
            12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc 11111111-2222-3333-444444444444",
      ]
      --run=:: member-remove it config cache ui
  member-cmd.add member-remove-cmd

  member-set-role := cli.Command "set-role"
      --help="Set the role of a member."
      --rest=[
        OptionUuid "user-id"
            --help="ID of the user to add."
            --required,
        cli.OptionEnum "role" ["member", "admin" ]
            --help="Role of the member."
            --required,
      ]
      --examples=[
        cli.Example """
            Set the role of user with ID 12345678-1234-1234-1234-123456789abc to admin in
            the default organization:"""
            --arguments="12345678-1234-1234-1234-123456789abc admin",
        cli.Example """
            Set the role of user with ID 11111111-2222-3333-444444444444 to member (non-admin) in
            organization 12345678-1234-1234-1234-123456789abc:"""
            --arguments="--organization-id=12345678-1234-1234-1234-123456789abc 11111111-2222-3333-444444444444 member",
      ]
      --run=:: member-set-role it config cache ui
  member-cmd.add member-set-role

  return [org-cmd]

with-org-server parsed/cli.Parsed config/Config ui/Ui [block]:
  server-config/ServerConfig := ?
  server-config = get-server-from-config config --key=CONFIG-ARTEMIS-DEFAULT-KEY
  if not server-config:
    ui.abort "Default server is not configured correctly."

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

add-org parsed/cli.Parsed config/Config ui/Ui -> none:
  should-make-default := parsed["default"]
  with-org-server parsed config ui: | server/ArtemisServerCli |
    org := server.create-organization parsed["name"]
    ui.info "Added organization $org.id - $org.name."
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
