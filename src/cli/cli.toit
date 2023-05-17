// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .cache
import .config
import .ui

import .cmds.auth
import .cmds.config
import .cmds.device
import .cmds.doc
import .cmds.fleet
import .cmds.org
import .cmds.pod
import .cmds.profile
import .cmds.sdk
import .cmds.serial

import ..shared.version

create_ui_from_args args:
  verbose_level/string? := null
  output_format/string? := null

  // We don't keep track of whether an argument was already provided.
  // The last one wins.
  // The real parsing later will catch any errors.
  // The output might still be affected since we use the created Ui class
  // for the output of parsing.
  // Also we might parse the flags in the wrong way here. For example,
  //   `--output "--verbose-level"` would be parsed differently if we knew
  // that `--output` is an option that takes an argument. We completely ignore
  // this here.
  for i := 0; i < args.size; i++:
    arg := args[i]
    if arg == "--": break
    if arg == "--verbose":
      verbose_level = "verbose"
    else if arg == "--verbose-level" or arg == "--verbose_level":
      if i + 1 >= args.size:
        // We will get an error during the real parsing of the args.
        break
      verbose_level = args[++i]
    else if arg.starts_with "--verbose-level=" or arg.starts_with "--verbose_level=":
      verbose_level = arg["--verbose-level=".size..]
    else if arg == "--output-format" or arg == "--output_format":
      if i + 1 >= args.size:
        // We will get an error during the real parsing of the args.
        break
      output_format = args[++i]
    else if arg.starts_with "--output-format=" or arg.starts_with "--output_format=":
      output_format = arg["--output-format=".size..]

  if verbose_level == null: verbose_level = "info"
  if output_format == null: output_format = "text"

  level/int := ?
  if verbose_level == "debug": level = Ui.DEBUG_LEVEL
  else if verbose_level == "info": level = Ui.NORMAL_LEVEL
  else if verbose_level == "verbose": level = Ui.VERBOSE_LEVEL
  else if verbose_level == "quiet": level = Ui.QUIET_LEVEL
  else if verbose_level == "silent": level = Ui.SILENT_LEVEL
  else: level = Ui.NORMAL_LEVEL

  if output_format == "json":
    return JsonUi --level=level
  else:
    return ConsoleUi --level=Ui.NORMAL_LEVEL

main args:
  config := read_config
  cache := Cache --app_name="artemis"
  ui := create_ui_from_args args
  main args --config=config --cache=cache --ui=ui

main args --config/Config --cache/Cache --ui/Ui:
  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    ui.result ARTEMIS_VERSION
    return

  root_cmd := cli.Command "root"
      --long_help="""
      A fleet management system for Toit devices.
      """
      --subcommands=[
        cli.Command "version"
            --long_help="Show the version of the Artemis tool."
            --run=:: ui.result ARTEMIS_VERSION,
      ]
      --options=[
        cli.Option "fleet-root"
            --type="directory"
            --short_help="Specify the fleet root."
            --default=".",
        cli.OptionEnum "output-format"
            ["text", "json"]
            --short_help="Specify the format used when printing to the console."
            --default="text",
        cli.Flag "verbose"
            --short_help="Enable verbose output. Shorthand for --verbose-level=verbose."
            --default=false,
        cli.OptionEnum "verbose-level"
            ["debug", "info", "verbose", "quiet", "silent"]
            --short_help="Specify the verbosity level."
            --default="info",
      ]

  // TODO(florian): the ui should be configurable by flags.
  // This might be easier, once the UI is integrated with the cli
  // package, as the package could then pass it to the commands after
  // it has parsed the UI flags.
  (create_config_commands config cache ui).do: root_cmd.add it
  (create_auth_commands config cache ui).do: root_cmd.add it
  (create_org_commands config cache ui).do: root_cmd.add it
  (create_profile_commands config cache ui).do: root_cmd.add it
  (create_sdk_commands config cache ui).do: root_cmd.add it
  (create_device_commands config cache ui).do: root_cmd.add it
  (create_fleet_commands config cache ui).do: root_cmd.add it
  (create_pod_commands config cache ui).do: root_cmd.add it
  (create_serial_commands config cache ui).do: root_cmd.add it
  (create_doc_commands config cache ui).do: root_cmd.add it

  root_cmd.run args
