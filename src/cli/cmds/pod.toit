// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .utils_
import ..artemis
import ..config
import ..cache
import ..device_specification
import ..fleet
import ..pod
import ..ui

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

        Unless '--upload' is set to false (--no-upload), automatically uploads
        the pod's data to the broker in the fleet's organization, so that
        it can be used for updates.
        """
      --options=[
        cli.Option "output"
            --type="file"
            --short_name="o"
            --short_help="File to write the pod to."
            --required,
        cli.Flag "upload"
            --short_help="Upload the pod's data to the cloud."
            --default=true,
      ]
      --rest=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the pod.",
      ]
      --run=:: create_pod it config cache ui
  cmd.add create_cmd

  upload_cmd := cli.Command "upload"
      --long_help="""
        Upload the given pod to the broker.

        After this action the pod is available to the fleet.
        Uploaded pods can be used for diff-based over-the-air updates.
        """
      --rest= [
        cli.Option "pod"
            --type="file"
            --short_help="The pod to upload."
            --required,
      ]
      --run=:: upload it config cache ui
  cmd.add upload_cmd

  return [cmd]

create_pod parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  specification_path := parsed["specification"]
  output := parsed["output"]
  should_upload := parsed["upload"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    pod := Pod.from_specification --path=specification_path --ui=ui --artemis=artemis
    pod.write output --ui=ui
    if should_upload:
      fleet_root := parsed["fleet-root"]
      fleet := Fleet fleet_root artemis --ui=ui --cache=cache
      fleet.upload --pod=pod

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  pod_path := parsed["pod"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    pod := Pod.parse pod_path --artemis=artemis --ui=ui
    fleet.upload --pod=pod
