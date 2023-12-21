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
import ..pod-specification
import ..pod-registry
import ..ui
import ..utils.names
import ..utils show json-encode-pretty read-json

create-pod-commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "pod"
      --help="Create and manage pods."

  create-cmd := cli.Command "build"
      --aliases=["create", "compile"]
      --help="""
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
            --short-name="o"
            --help="File to write the pod to."
            --required,
      ]
      --rest=[
        cli.Option "specification"
            --type="file"
            --help="The specification of the pod."
            --required,
      ]
      --run=:: create-pod it config cache ui
  cmd.add create-cmd

  upload-cmd := cli.Command "upload"
      --help="""
        Upload the given pod(s) to the broker.

        When a pod has been uploaded to the fleet, it can be used for flashing
        new devices and for diff-based over-the-air updates.
        """
      --options=[
        cli.Option "tag"
            --short-name="t"
            --help="A tag to attach to the pod."
            --multi,
        cli.Flag "force"
            --short-name="f"
            --help="Force tags even if they already exist."
            --default=false,
      ]
      --rest=[
        cli.Option "pod"
            --type="file"
            --help="A pod to upload."
            --multi
            --required,
      ]
      --run=:: upload it config cache ui
  cmd.add upload-cmd

  download-cmd := cli.Command "download"
      --help="""
        Download a pod from the broker.

        The pod to download is specified through a pod reference like
        name@tag or name#revision.

        If only the pod name is provided, the pod with the 'latest' tag is
        downloaded.
        """
      --options=[
        cli.Option "output"
            --type="file"
            --short-name="o"
            --help="File to write the pod to."
            --required,
      ]
      --rest=[
        cli.Option "reference"
            --help="A pod reference: a UUID, name@tag, or name#revision."
            --required,
      ]
      --run=:: download it config cache ui
  cmd.add download-cmd

  list-cmd := cli.Command "list"
      --help="""
        List all pods available on the broker.

        If no names are given, all pods for this fleet are listed.
        """
      --options=[
        cli.Option "name"
            --help="List pods with this name."
            --multi,
      ]
      --run=:: list it config cache ui
  cmd.add list-cmd

  print-cmd := cli.Command "print"
      --help="""
        Print the given pod specification.

        If the '--flat' option is given, the pod specification is printed
        after merging all extended specifications into a single specification.

        This command is useful for debugging pod specifications.
        """
      --options=[
        cli.Flag "flat"
            --help="Print the merged pod specification.",
      ]
      --rest=[
        cli.Option "specification"
            --type="file"
            --help="The specification of the pod."
            --required,
      ]
      --run=:: print it config cache ui
  cmd.add print-cmd

  delete-cmd := cli.Command "delete"
      --help="""
        Delete the given pod(s) from the broker.

        The pod to delete is specified through a pod reference like
        name@tag or name#revision.

        If the '--all' flag is provided, the arguments should be names
        (without revision or tag) and all pods with that name are deleted.
        """
      --options=[
        cli.Flag "all"
            --help="Delete all pods with the given name.",
      ]
      --rest=[
        cli.Option "name-or-reference"
            --help="A pod name or reference (a UUID, name@tag, or name#revision)."
            --multi
            --required,
      ]
      --run=:: delete it config cache ui
  cmd.add delete-cmd

  return [cmd]

create-pod parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  specification-path := parsed["specification"]
  output := parsed["output"]

  with-fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    pod := Pod.from-specification
        --organization-id=fleet.organization-id
        --path=specification-path
        --ui=ui
        --artemis=artemis
    pod.write output --ui=ui

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  pod-paths := parsed["pod"]
  tags/List := parsed["tag"]
  force/bool := parsed["force"]

  if tags.is-empty:
    name := random-name
    time := Time.now.utc
    tag := "$(time.year)$(%02d time.month)$(%02d time.day)$(%02d time.h)$(%02d time.m)$(%02d time.s)-$name"
    tags = [ tag ]

  if tags.contains "latest":
    ui.warning "The latest tag is automatically added."
  else:
    tags.add "latest"

  with-fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    pod-paths.do: | pod-path/string |
      pod := Pod.from-file pod-path
          --organization-id=fleet.organization-id
          --artemis=artemis
          --ui=ui
      fleet.upload --pod=pod --tags=tags --force-tags=force

download parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  reference-string := parsed["reference"]
  output := parsed["output"]

  reference := PodReference.parse reference-string --allow-name-only --ui=ui

  with-fleet parsed config cache ui: | fleet/Fleet |
    pod := fleet.download reference
    pod.write output --ui=ui
    ui.info "Downloaded pod '$reference-string' to '$output'."

list parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  names := parsed["name"]

  with-fleet parsed config cache ui: | fleet/Fleet |
    pods := fleet.list-pods --names=names
    // TODO(florian):
    // we want to have 'created_at' in the registry entry.
    // we want to have a second way of listing: one where we only list the ones that
    // have tags. One, where we list all of them.
    // we probably also want to list only entries for a specific name.
    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit-structured
          --json=:
            json-pods := []
            pods.do: | key/PodRegistryDescription pod-entries/List |
              name := key.name
              json-entries := pod-entries.map: | entry/PodRegistryEntry |
                json-entry := entry.to-json
                json-entry["name"] = name
                json-entry
              json-pods.add-all json-entries
            json-pods
          --stdout=:
            print-pods_ pods --printer=printer

print-pods_ pods/Map --printer/Printer:
  is-first := true
  pods.do: | description/PodRegistryDescription pod-entries/List |
    if is-first:
      is-first = false
    else:
      printer.emit ""
    description-line := "$description.name"
    if description.description:
      description-line += " - $description.description"
    printer.emit description-line
    rows := pod-entries.map: | entry/PodRegistryEntry |
      {
        "id": "$entry.id",
        "revision": entry.revision,
        "tags": entry.tags,
        "joined_tags": entry.tags.join ",",
        "created_at": "$entry.created-at",
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
  specification-path := parsed["specification"]

  exception := catch --unwind=(: it is not PodSpecificationException):
    // We always parse the specification, even if we don't need the flat version.
    // This way we report errors in extended specifications.
    json := PodSpecification.parse-json-hierarchy specification-path
    if not flat:
      // If we only want the non-flattened version read the json by hand.
      json = read-json specification-path

    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit-structured
          --json=: printer.emit json
          --stdout=:
            str := (json-encode-pretty json).to-string
            printer.emit str
  if exception:
    ui.abort (exception as PodSpecificationException).message

delete parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  reference-strings := parsed["name-or-reference"]
  all := parsed["all"]

  with-fleet parsed config cache ui: | fleet/Fleet |
    if all:
      fleet.delete --description-names=reference-strings
    else:
      refs := reference-strings.map: | string | PodReference.parse string --ui=ui
      fleet.delete --pod-references=refs
  if reference-strings.size == 1:
    ui.info "Deleted pod '$(reference-strings.first)'."
  else:
    ui.info "Deleted pods '$(reference-strings.join ", ")'."
