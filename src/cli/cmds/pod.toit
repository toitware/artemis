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
import ..utils show json_encode_pretty read_json

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
            --short_name="t"
            --short_help="A tag to attach to the pod."
            --multi,
        cli.Flag "force"
            --short_name="f"
            --short_help="Force tags even if they already exist."
            --default=false,
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

        The pod to download is specified through a pod reference like
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
        cli.Option "reference"
            --short_help="A pod reference: a UUID, name@tag, or name#revision."
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

  print_cmd := cli.Command "print"
      --long_help="""
        Print the given pod specification.

        If the '--flat' option is given, the pod specification is printed
        after merging all extended specifications into a single specification.

        This command is useful for debugging pod specifications.
        """
      --options=[
        cli.Flag "flat"
            --short_help="Print the merged pod specification.",
      ]
      --rest=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the pod."
            --required,
      ]
      --run=:: print it config cache ui
  cmd.add print_cmd

  delete_cmd := cli.Command "delete"
      --long_help="""
        Delete the given pod(s) from the broker.

        The pod to delete is specified through a pod reference like
        name@tag or name#revision.

        If the '--all' flag is provided, the arguments should be names
        (without revision or tag) and all pods with that name are deleted.
        """
      --options=[
        cli.Flag "all"
            --short_help="Delete all pods with the given name.",
      ]
      --rest=[
        cli.Option "name-or-reference"
            --short_help="A pod name or reference (a UUID, name@tag, or name#revision)."
            --multi
            --required,
      ]
      --run=:: delete it config cache ui
  cmd.add delete_cmd

  return [cmd]

create_pod parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  specification_path := parsed["specification"]
  output := parsed["output"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    pod := Pod.from_specification
        --organization_id=fleet.organization_id
        --path=specification_path
        --ui=ui
        --artemis=artemis
    pod.write output --ui=ui

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  pod_paths := parsed["pod"]
  tags/List := parsed["tag"]
  force/bool := parsed["force"]

  if tags.is_empty:
    name := random_name
    time := Time.now.utc
    tag := "$(time.year)$(%02d time.month)$(%02d time.day)$(%02d time.h)$(%02d time.m)$(%02d time.s)-$name"
    tags = [ tag ]

  if tags.contains "latest":
    ui.warning "The latest tag is automatically added."
  else:
    tags.add "latest"

  with_fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    pod_paths.do: | pod_path/string |
      pod := Pod.from_file pod_path
          --organization_id=fleet.organization_id
          --artemis=artemis
          --ui=ui
      fleet.upload --pod=pod --tags=tags --force_tags=force

download parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  reference_string := parsed["reference"]
  output := parsed["output"]

  reference := PodReference.parse reference_string --allow_name_only --ui=ui

  with_fleet parsed config cache ui: | fleet/Fleet |
    pod := fleet.download reference
    pod.write output --ui=ui
    ui.info "Downloaded pod '$reference_string' to '$output'."

list parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  names := parsed["name"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    pods := fleet.list_pods --names=names
    // TODO(florian):
    // we want to have 'created_at' in the registry entry.
    // we want to have a second way of listing: one where we only list the ones that
    // have tags. One, where we list all of them.
    // we probably also want to list only entries for a specific name.
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit_structured
          --json=:
            json_pods := []
            pods.do: | key/PodRegistryDescription pod_entries/List |
              name := key.name
              json_entries := pod_entries.map: | entry/PodRegistryEntry |
                json_entry := entry.to_json
                json_entry["name"] = name
                json_entry
              json_pods.add_all json_entries
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

print parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  flat := parsed["flat"]
  specification_path := parsed["specification"]

  exception := catch --unwind=(: it is not PodSpecificationException):
    // We always parse the specification, even if we don't need the flat version.
    // This way we report errors in extended specifications.
    json := PodSpecification.parse_json_hierarchy specification_path
    if not flat:
      // If we only want the non-flattened version read the json by hand.
      json = read_json specification_path

    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit_structured
          --json=: printer.emit json
          --stdout=:
            str := (json_encode_pretty json).to_string
            printer.emit str
  if exception:
    ui.abort (exception as PodSpecificationException).message

delete parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  reference_strings := parsed["name-or-reference"]
  all := parsed["all"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    if all:
      fleet.delete --description_names=reference_strings
    else:
      refs := reference_strings.map: | string | PodReference.parse string --ui=ui
      fleet.delete --pod_references=refs
  if reference_strings.size == 1:
    ui.info "Deleted pod '$(reference_strings.first)'."
  else:
    ui.info "Deleted pods '$(reference_strings.join ", ")'."
