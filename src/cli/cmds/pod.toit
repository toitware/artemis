// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli
import host.file
import uuid

import .utils_
import ..artemis
import ..config
import ..cache
import ..fleet
import ..pod
import ..pod_specification
import ..pod_registry
import ..ui
import ..utils.names

create_pod_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "pod"
      --short_help="Create and manage pods."

  create_cmd := cli.Command "build"
      --aliases=["create", "compile"]
      --long_help="""
        Create a pod.

        The specification file contains the pod specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'doc specification-format' for more information.

        The generated pod can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'fleet create-identities' for more information.
        """
      --options=[
        cli.Option "output"
            --type="file"
            --short_name="o"
            --short_help="File to write the pod to."
            --required,
      ]
      --rest=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the pod."
            --required,
      ]
      --run=:: create_pod it config cache ui
  cmd.add create_cmd

  upload_cmd := cli.Command "upload"
      --long_help="""
        Upload the given pod(s) to the broker.

        When a pod has been uploaded to the fleet, it can be used for flashing
        new devices and for diff-based over-the-air updates.
        """
      --options=[
        cli.Option "tag"
            --short_help="A tag to attach to the pod."
            --multi,
      ]
      --rest=[
        cli.Option "pod"
            --type="file"
            --short_help="A pod to upload."
            --multi
            --required,
      ]
      --run=:: upload it config cache ui
  cmd.add upload_cmd

  download_cmd := cli.Command "download"
      --long_help="""
        Download a pod from the broker.

        The pod to download is specified through a remote pod reference like
        name@tag or name#revision.

        If only the pod name is provided, the pod with the 'latest' tag is
        downloaded.
        """
      --options=[
        cli.Option "output"
            --type="file"
            --short_name="o"
            --short_help="File to write the pod to."
            --required,
      ]
      --rest=[
        cli.Option "remote"
            --short_help="A remote pod reference; a UUID, name@tag, or name#revision."
            --required,
      ]
      --run=:: download it config cache ui
  cmd.add download_cmd

  list_cmd := cli.Command "list"
      --long_help="""
        List all pods available on the broker.

        If no names are given, all pods for this fleet are listed.
        """
      --options=[
        cli.Option "name"
            --short_help="List pods with this name."
            --multi,
      ]
      --run=:: list it config cache ui
  cmd.add list_cmd

  return [cmd]

create_pod parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  specification_path := parsed["specification"]
  output := parsed["output"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    pod := Pod.from_specification --path=specification_path --ui=ui --artemis=artemis
    pod.write output --ui=ui

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  pod_paths := parsed["pod"]
  tags/List := parsed["tag"]

  if tags.is_empty:
    name := random_name
    time := Time.now.utc
    tag := "$(time.year)$(%02d time.month)$(%02d time.day)$(%02d time.h)$(%02d time.m)$(%02d time.s)-$name"
    tags = [ tag ]

  if tags.contains "latest":
    ui.warning "The latest tag is automatically added."
  else:
    tags.add "latest"

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    pod_paths.do: | pod_path/string |
      pod := Pod.from_file pod_path --artemis=artemis --ui=ui
      fleet.upload --pod=pod --tags=tags

download parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  remote := parsed["remote"]
  output := parsed["output"]

  reference := PodReference.parse remote --allow_name_only --ui=ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    pod := fleet.download reference
    pod.write output --ui=ui
    ui.info "Downloaded pod '$remote' to '$output'."

list parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  names := parsed["name"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    pods := fleet.list_pods --names=names
    // TODO(florian):
    // we want to have 'created_at' in the registry entry.
    // we want to have a second way of listing: one where we only list the ones that
    // have tags. One, where we list all of them.
    // we probably also want to list only entries for a specific name.
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit_structured
          --json=:
            json_descriptions := {:}
            json_pods := []
            pods.do: | key/PodRegistryDescription pod_entries/List |
              json_descriptions[key.id] = key.to_json
              json_pods.add_all (pod_entries.map: | entry/PodRegistryEntry | entry.to_json)
            json_pods
          --stdout=:
            print_pods_ pods --printer=printer

print_pods_ pods/Map --printer/Printer:
  is_first := true
  pods.do: | description/PodRegistryDescription pod_entries/List |
    if is_first:
      is_first = false
    else:
      printer.emit ""
    description_line := "$description.name"
    if description.description:
      description_line += " - $description.description"
    printer.emit description_line
    rows := pod_entries.map: | entry/PodRegistryEntry |
      {
        "id": "$entry.id",
        "revision": entry.revision,
        "tags": entry.tags,
        "joined_tags": entry.tags.join ",",
        "created_at": "$entry.created_at",
      }
    printer.emit
        --header={
          "id": "ID",
          "revision": "Revision",
          // Note that we don't print the actual tag list.
          // However, a structured output will receive them.
          "joined_tags": "Tags",
          "created_at": "Created At",
        }
        rows
