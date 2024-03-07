// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import net
import semver

import ..config
import ..cache
import ..fleet
import ..server-config
import ..ui
import ..artemis-servers.artemis-server show with-server ArtemisServerCli
import .utils_

create-sdk-commands config/Config cache/Cache ui/Ui -> List:
  sdk-cmd := cli.Command "sdk"
      --help="Information about supported SDKs."
      --options=[
        cli.Option "server" --hidden --help="The server to use.",
      ]

  list-cmd := cli.Command "list"
      --help="List supported SDKs."
      --options=[
        cli.Option "sdk-version" --help="The SDK version to list.",
        cli.Option "service-version" --help="The service version to list.",
      ]
      --run=:: list-sdks it config cache ui
  sdk-cmd.add list-cmd

  return [sdk-cmd]

list-sdks parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  sdk-version := parsed["sdk-version"]
  service-version := parsed["service-version"]

  with-pod-fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    versions/List := artemis.connected-artemis-server.list-sdk-service-versions
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

    ui.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          --header={
            "sdk-version": "SDK Version",
            "service-version": "Service Version",
          }
          output
