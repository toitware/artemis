// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import net

import ..config
import ..cache
import ..server_config
import ..ui
import ..artemis_servers.artemis_server show with_server ArtemisServerCli

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
      --run=:: list_sdks it config ui
  sdk_cmd.add list_cmd

  return [sdk_cmd]

with_sdk_server parsed/cli.Parsed config/Config [block]:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config block

list_sdks parsed/cli.Parsed config/Config ui/Ui:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]

  with_sdk_server parsed config: | server/ArtemisServerCli |
    server.ensure_authenticated: | error_message |
      ui.error "$error_message (artemis)."
      ui.abort
    versions/List := server.list_sdk_service_versions
        --sdk_version=sdk_version
        --service_version=service_version
    // TODO(florian): make a nicer output.
    table := []
    versions.do: | row |
      table.add [row["sdk_version"], row["service_version"]]
    ui.info_table --header=["SDK Version", "Service Version"] table
