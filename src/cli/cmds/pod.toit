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

        A revision can also be specified by appending '#<revision>' to the name.

        If no revision or tag is specified, the pod with the 'latest' tag is downloaded.
        """
      --options=[
        cli.Option "output"
            --type="file"
            --short_name="o"
            --short_help="File to write the pod to."
            --required,
        cli.Option "tag" --short_help="The tag to download.",
        cli.OptionInt "revision" --short_help="The revision to download.",
      ]
      --rest=[
        cli.Option "name-or-id"
            --short_help="The name or ID of the pod to download."
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
  tags := parsed["tag"]

  if tags.is_empty:
    name := random_name
    time := Time.now.utc
    tag := "$(time.year)$(%02d time.month)$(%02d time.day)$(%02d time.h)$(%02d time.m)$(%02d time.s):$name"
    tags = [ tag ]

  tags.add "latest"

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    pod_paths.do: | pod_path/string |
      is_compiled_pod := false
      catch --unwind=(: it != "Invalid Ar File"):
        stream := file.Stream.for_read pod_path
        try:
          ar.ArReader stream
          is_compiled_pod = true
        finally:
          stream.close
      pod/Pod := ?
      if is_compiled_pod:
        pod = Pod.parse pod_path --tmp_directory=artemis.tmp_directory --ui=ui
      else:
        pod = Pod.from_specification --path=pod_path --artemis=artemis --ui=ui
      fleet.upload --pod=pod --tags=tags

download parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  name_or_id := parsed["name-or-id"]
  output := parsed["output"]
  tag := parsed["tag"]
  revision := parsed["revision"]

  id/uuid.Uuid? := null
  // If the name_or_id resembles a UUID, we assume it's an ID.
  if name_or_id.size == 36 and
      name_or_id[8] == "-" and
      name_or_id[13] == "-" and
      name_or_id[18] == "-" and
      name_or_id[23] == "-":
    catch: id = uuid.parse name_or_id
    if id and (tag or revision):
      ui.abort "Cannot specify tag or revision when downloading by ID."

  hash_index := name_or_id.index_of "#"
  if hash_index >= 0:
    if revision:
      ui.abort "Cannot specify the revision as option and in the name."
    revision_string := name_or_id[hash_index + 1..]
    revision = int.parse revision_string --on_error=(: ui.abort "Invalid revision: $revision_string")
    name_or_id = name_or_id[..hash_index]

  if tag and revision:
    ui.abort "Cannot specify both tag and revision."

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    if not id:
      if not tag and not revision: tag = "latest"
      id = fleet.get_pod_id --name=name_or_id --tag=tag --revision=revision
    pod := fleet.download --pod_id=id
    pod.write output --ui=ui
    ui.info "Downloaded pod '$name_or_id' to '$output'."

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
    ui.info_structured
        --json=:
          json_descriptions := {:}
          json_pods := []
          pods.do: | key/PodRegistryDescription pod_entries/List |
            json_descriptions[key.id] = key.to_json
            json_pods.add_all (pod_entries.map: | entry/PodRegistryEntry | entry.to_json)
        --stdout=:
          print_pods_ pods --ui=ui

print_pods_ pods/Map --ui/Ui:
  is_first := true
  pods.do: | description/PodRegistryDescription pod_entries/List |
    if is_first:
      is_first = false
    else:
      ui.info ""
    description_line := "$description.name"
    if description.description:
      description_line += " - $description.description"
    ui.info description_line
    rows := pod_entries.map: | entry/PodRegistryEntry |
      ["$entry.id", "$entry.revision", entry.tags.join ", ", "$entry.created_at"]
    ui.info_table --header=["ID", "Revision", "Tags", "Created At"] rows
