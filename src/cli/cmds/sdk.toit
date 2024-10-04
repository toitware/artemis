// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *
import net
import semver

import ..config
import ..cache
import ..fleet
import ..server-config
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import .utils_

create-sdk-commands -> List:
  sdk-cmd := Command "sdk"
      --help="Information about supported SDKs."
      --options=[
        Option "server" --hidden --help="The server to use.",
      ]

  list-cmd := Command "list"
      --aliases=["ls"]
      --help="List supported SDKs."
      --options=[
        Option "sdk-version" --help="The SDK version to list.",
        Option "service-version" --help="The service version to list.",
      ]
      --examples=[
        Example "List all available SDKs/service versions:"
            --arguments="",
        Example "List all available service versions for a the SDK version v2.0.0-alpha.139:"
            --arguments="--sdk-version=v2.0.0-alpha.139",
        Example "List all available SDK versions for the service version v0.5.5:"
            --arguments="--service-version=v0.5.5",
      ]
      --run=:: list-sdks it
  sdk-cmd.add list-cmd

  return [sdk-cmd]

list-sdks invocation/Invocation:
  sdk-version := invocation["sdk-version"]
  service-version := invocation["service-version"]

  with-pod-fleet invocation: | fleet/Fleet |
    artemis := fleet.artemis
    versions/List := artemis.list-sdk-service-versions
        --organization-id=fleet.organization-id
        --sdk-version=sdk-version
        --service-version=service-version

    versions.sort --in-place: | a/Map b/Map |
      semver.compare a["sdk_version"] b["sdk_version"] --if-equal=:
        semver.compare a["service_version"] b["service_version"] --if-equal=:
          // As a last effort compare the strings directly.
          // This also includes the build metadata, which is ignored for semver comparisons.
          "$a["sdk_version"]-$a["service_version"]".compare-to "$b["sdk_version"]-$b["service_version"]"

    output := versions.map: {
      "sdk-version": it["sdk_version"],
      "service-version": it["service_version"],
    }

    invocation.cli.ui.emit-table --result
        --header={
          "sdk-version": "SDK Version",
          "service-version": "Service Version",
        }
        output
