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

  default_cmd := cli.Command "default"
      --long_help="""
        Show or set the default SDK.

        If no version is specified, the current default SDK is shown.
        If a version is specified, it is set as the default SDK.

        If the '--clear' flag is specified, clears the default SDK.
        """
      --options=[
        cli.Flag "clear"
            --short_help="Clear the default SDK.",
      ]
      --rest=[
        cli.Option "version"
            --short_help="The version of the SDK."
      ]
      --run=:: default_sdk it config ui
  sdk_cmd.add default_cmd

  return [sdk_cmd]

with_sdk_server parsed/cli.Parsed config/Config [block]:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY

  with_server server_config config block

list_sdks parsed/cli.Parsed config/Config ui/Ui:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]

  with_sdk_server parsed config: | server/ArtemisServerCli |
    versions := server.list_sdk_service_versions
        --sdk_version=sdk_version
        --service_version=service_version
    // TODO(florian): make a nicer output.
    table := []
    versions.do: | row |
      table.add [row["sdk_version"], row["service_version"]]
    ui.info_table --header=["SDK Version", "Service Version"] table

default_sdk parsed/cli.Parsed config/Config ui/Ui:
  config_key := CONFIG_SDK_DEFAULT_KEY

  if parsed["clear"]:
    config.remove config_key
    config.write
    ui.info "Default SDK version cleared."
    return

  version := parsed["version"]
  if not version:
    default_version := config.get config_key
    if default_version:
      ui.info default_version
    else:
      ui.error "No default SDK version set."
      ui.abort
    return

  with_sdk_server parsed config: | server/ArtemisServerCli |
    versions := server.list_sdk_service_versions
        --sdk_version=version

    if versions.is_empty:
      ui.error "Unsupported SDK version $version."
      ui.abort

    config[config_key] = version
    config.write
    ui.info "Default SDK version set to $version."
