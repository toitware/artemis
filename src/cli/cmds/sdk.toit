// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import net
import semver

import ..config
import ..cache
import ..fleet
import ..server_config
import ..ui
import ..artemis_servers.artemis_server show with_server ArtemisServerCli
import .utils_

create_sdk_commands config/Config cache/Cache ui/Ui -> List:
  sdk_cmd := cli.Command "sdk"
      --short_help="Information about supported SDKs."
      --options=[
        cli.Option "server" --hidden --short_help="The server to use.",
      ]

  list_cmd := cli.Command "list"
      --short_help="List supported SDKs."
      --options=[
        cli.Option "sdk-version" --short_help="The SDK version to list.",
        cli.Option "service-version" --short_help="The service version to list.",
      ]
      --run=:: list_sdks it config cache ui
  sdk_cmd.add list_cmd

  return [sdk_cmd]

list_sdks parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_
    versions/List := artemis.connected_artemis_server.list_sdk_service_versions
        --organization_id=fleet.organization_id
        --sdk_version=sdk_version
        --service_version=service_version

    versions.sort --in_place: | a/Map b/Map |
      semver.compare a["sdk_version"] b["sdk_version"] --if_equal=:
        semver.compare a["service_version"] b["service_version"] --if_equal=:
          // As a last effort compare the strings directly.
          // This also includes the build metadata, which is ignored for semver comparisons.
          "$a["sdk_version"]-$a["service_version"]".compare_to "$b["sdk_version"]-$b["service_version"]"

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
