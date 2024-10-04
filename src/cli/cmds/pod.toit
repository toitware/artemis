// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli show *
import host.file

import .utils_
import ..artemis
import ..config
import ..cache
import ..fleet
import ..pod
import ..pod-specification
import ..pod-registry
import ..utils.names
import ..utils show json-encode-pretty read-json read-yaml

create-pod-commands -> List:
  cmd := Command "pod"
      --help="Create and manage pods."

  create-cmd := Command "build"
      --aliases=["create", "compile"]
      --help="""
        Create a pod.

        The specification file contains the pod specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'doc specification-format' for more information.

        The generated pod can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'fleet add-devices' for more information.
        """
      --options=[
        Option "output"
            --type="file"
            --short-name="o"
            --help="File to write the pod to."
            --required,
      ]
      --rest=[
        Option "specification"
            --type="file"
            --help="The specification of the pod."
            --required,
      ]
      --examples=[
        Example "Build a pod file 'my-pod.pod' from a specification file 'my-pod.yaml':"
            --arguments="-o my-pod.pod my-pod.yaml",
      ]
      --run=:: create-pod it
  cmd.add create-cmd

  upload-cmd := Command "upload"
      --help="""
        Upload the given pod(s) to the broker.

        When a pod has been uploaded to the fleet, it can be used for flashing
        new devices and for diff-based over-the-air updates.
        """
      --options=[
        Option "tag"
            --short-name="t"
            --help="A tag to attach to the pod."
            --multi,
        Flag "force"
            --short-name="f"
            --help="Force tags even if they already exist."
            --default=false,
      ]
      --rest=[
        Option "pod"
            --type="file"
            --help="A pod to upload."
            --multi
            --required,
      ]
      --examples=[
        Example """
            Build a pod from specification 'my-pod.yaml' and upload it with just
            the automatic 'latest' tag:"""
            --arguments="my-pod.yaml"
            --global-priority=7,
        Example """
            Upload the pod file 'my-pod.pod' with the tag 'v1.0.0', and the automatic
            'latest' tag:"""
            --arguments="--tag=v1.0.0 my-pod.pod"
            --global-priority=4,
        Example """
            Upload the pod file 'my-pod.pod' with the tag 'v2.0.0' and reset the tag
            if it already exists:"""
            --arguments="--tag=v2.0.0 --force my-pod.pod",
      ]
      --run=:: upload it
  cmd.add upload-cmd

  download-cmd := Command "download"
      --help="""
        Download a pod from the broker.

        The pod to download is specified through a pod reference like
        name@tag or name#revision.

        If only the pod name is provided, the pod with the 'latest' tag is
        downloaded.
        """
      --options=[
        Option "output"
            --type="file"
            --short-name="o"
            --help="File to write the pod to."
            --required,
      ]
      --rest=[
        Option "reference"
            --help="A pod reference: a UUID, name@tag, or name#revision."
            --required,
      ]
      --examples=[
        Example "Download the latest version of the pod with name 'my-pod' to 'my-pod.pod':"
            --arguments="-o my-pod.pod my-pod",
        Example "Download the pod with UUID '12345678-1234-5678-1234-567812345678' to 'my-pod.pod':"
            --arguments="-o my-pod.pod 12345678-1234-5678-1234-567812345678",
        Example "Download the pod with name 'my-pod' and tag 'v1.0.0' to 'my-pod.pod':"
            --arguments="-o my-pod.pod my-pod@v1.0.0",
        Example "Download the pod with name 'my-pod' and revision '1' to 'my-pod.pod':"
            --arguments="-o my-pod.pod my-pod#1",
      ]
      --run=:: download it
  cmd.add download-cmd

  list-cmd := Command "list"
      --help="""
        List all pods available on the broker.

        If no names are given, all pods for this fleet are listed.
        """
      --options=[
        Option "name"
            --help="List pods with this name."
            --multi,
      ]
      --examples=[
        Example "List all pods available on the broker:"
            --arguments="",
        Example "List all pods with the name 'my-pod':"
            --arguments="--name=my-pod",
        Example "List all pods with name 'my-pod' or 'my-other-pod':"
            --arguments="--name=my-pod --name=my-other-pod",
      ]
      --run=:: list it
  cmd.add list-cmd

  print-cmd := Command "print"
      --help="""
        Print the given pod specification.

        If the '--flat' option is given, the pod specification is printed
        after merging all extended specifications into a single specification.

        This command is useful for debugging pod specifications.
        """
      --options=[
        Flag "flat"
            --help="Print the merged pod specification.",
      ]
      --rest=[
        Option "specification"
            --type="file"
            --help="The specification of the pod."
            --required,
      ]
      --examples=[
        Example "Print the merged pod specification from a file 'my-pod.yaml':"
            --arguments="--flat my-pod.yaml",
        Example "Print the non-merged pod specification from a file 'my-pod.yaml':"
            --arguments="my-pod.yaml",
      ]
      --run=:: print it
  cmd.add print-cmd

  delete-cmd := Command "delete"
      --help="""
        Delete the given pod(s) from the broker.

        The pod to delete is specified through a pod reference like
        name@tag or name#revision.

        If the '--all' flag is provided, the arguments should be names
        (without revision or tag) and all pods with that name are deleted.
        """
      --options=[
        Flag "all"
            --help="Delete all pods with the given name.",
      ]
      --rest=[
        Option "name-or-reference"
            --help="A pod name or reference (a UUID, name@tag, or name#revision)."
            --multi
            --required,
      ]
      --examples=[
        Example "Delete the pod with name 'my-pod':"
            --arguments="my-pod",
        Example "Delete the pod with UUID '12345678-1234-5678-1234-567812345678':"
            --arguments="12345678-1234-5678-1234-567812345678",
      ]
      --run=:: delete it
  cmd.add delete-cmd

  return [cmd]

create-pod invocation/Invocation:
  cli := invocation.cli

  specification-path := invocation["specification"]
  output := invocation["output"]

  with-pod-fleet invocation: | fleet/Fleet |
    artemis := fleet.artemis
    broker := fleet.broker
    pod := Pod.from-specification
        --organization-id=fleet.organization-id
        --recovery-urls=fleet.recovery-urls
        --path=specification-path
        --artemis=artemis
        --broker=broker
        --cli=cli
    pod.write output --cli=cli

upload invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  pod-paths := invocation["pod"]
  tags/List := invocation["tag"]
  force/bool := invocation["force"]

  if tags.is-empty:
    name := random-name
    time := Time.now.utc
    tag := "$(time.year)$(%02d time.month)$(%02d time.day)$(%02d time.h)$(%02d time.m)$(%02d time.s)-$name"
    tags = [ tag ]

  if tags.contains "latest":
    ui.emit --warning "The latest tag is automatically added."
  else:
    tags.add "latest"

  with-pod-fleet invocation: | fleet/Fleet |
    artemis := fleet.artemis
    broker := fleet.broker
    pod-paths.do: | pod-path/string |
      pod := Pod.from-file pod-path
          --organization-id=fleet.organization-id
          --recovery-urls=fleet.recovery-urls
          --artemis=artemis
          --broker=broker
          --cli=cli
      upload-result := fleet.upload --pod=pod --tags=tags --force-tags=force
      if ui.wants-structured --kind=Ui.RESULT:
        // Note that we don't print the error-tags as error messages in this case.
        ui.emit --kind=Ui.RESULT
            --structured=: upload-result.to-json
      else:
        prefix := upload-result.tag-errors.is-empty ? "Successfully uploaded" : "Uploaded"
        ui.emit --info "$prefix $pod.name#$upload-result.revision to fleet $fleet.id."
        ui.emit --info "  id: $pod.id"
        ui.emit --info "  references:"
        upload-result.tags.do: ui.emit --info "    - $pod.name@$it"

        if not upload-result.tag-errors.is-empty:
          upload-result.tag-errors.do: ui.emit --error it

      if not upload-result.tag-errors.is-empty: ui.abort

download invocation/Invocation:
  cli := invocation.cli

  reference-string := invocation["reference"]
  output := invocation["output"]

  reference := PodReference.parse reference-string --allow-name-only --cli=cli

  with-pod-fleet invocation: | fleet/Fleet |
    pod := fleet.download reference
    pod.write output --cli=cli
    cli.ui.emit --info "Downloaded pod '$reference-string' to '$output'."

list invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  names := invocation["name"]

  with-pod-fleet invocation: | fleet/Fleet |
    pods := fleet.list-pods --names=names
    // TODO(florian):
    // we want to have 'created_at' in the registry entry.
    // we want to have a second way of listing: one where we only list the ones that
    // have tags. One, where we list all of them.
    // we probably also want to list only entries for a specific name.

    if ui.wants-structured --kind=Ui.RESULT:
      ui.emit
        --kind=Ui.RESULT
        --structured=:
            json-pods := []
            pods.do: | key/PodRegistryDescription pod-entries/List |
              name := key.name
              json-entries := pod-entries.map: | entry/PodRegistryEntry |
                json-entry := entry.to-json
                json-entry["name"] = name
                json-entry
              json-pods.add-all json-entries
            json-pods
    else:
      print-pods_ pods --cli=cli

print-pods_ pods/Map --cli/Cli -> none:
  ui := cli.ui
  is-first := true
  pods.do: | description/PodRegistryDescription pod-entries/List |
    if is-first:
      is-first = false
    else:
      ui.emit --result ""
    description-line := "$description.name"
    if description.description:
      description-line += " - $description.description"
    ui.emit --result description-line
    rows := pod-entries.map: | entry/PodRegistryEntry |
      {
        "id": "$entry.id",
        "revision": entry.revision,
        "tags": entry.tags,
        "joined_tags": entry.tags.join ",",
        "created_at": "$entry.created-at",
      }
    ui.emit-table --result
        --header={
          "id": "ID",
          "revision": "Revision",
          // Note that we don't print the actual tag list.
          // However, a structured output will receive them.
          "joined_tags": "Tags",
          "created_at": "Created At",
        }
        rows

print invocation/Invocation:
  ui := invocation.cli.ui

  flat := invocation["flat"]
  specification-path := invocation["specification"]

  exception := catch --unwind=(: it is not PodSpecificationException):
    // We always parse the specification, even if we don't need the flat version.
    // This way we report errors in extended specifications.
    json := PodSpecification.parse-json-hierarchy specification-path
    if not flat:
      // If we only want the non-flattened version read the json/yaml again by hand.
      json = read-pod-spec-file specification-path

    ui.emit --kind=Ui.RESULT
        --structured=: json
        --text=: (json-encode-pretty json).to-string

  if exception:
    ui.abort (exception as PodSpecificationException).message

delete invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  reference-strings := invocation["name-or-reference"]
  all := invocation["all"]

  with-pod-fleet invocation: | fleet/Fleet |
    if all:
      fleet.delete --description-names=reference-strings
    else:
      refs := reference-strings.map: | string | PodReference.parse string --cli=cli
      fleet.delete --pod-references=refs
  if reference-strings.size == 1:
    ui.emit --info "Deleted pod '$(reference-strings.first)'."
  else:
    ui.emit --info "Deleted pods '$(reference-strings.join ", ")'."
