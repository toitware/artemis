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

create-ui-from-args args:
  verbose-level/string? := null
  output-format/string? := null

  // We don't keep track of whether an argument was already provided.
  // The last one wins.
  // The real parsing later will catch any errors.
  // The output might still be affected since we use the created Ui class
  // for the output of parsing.
  // Also we might parse the flags in the wrong way here. For example,
  //   `--output "--verbosity-level"` would be parsed differently if we knew
  // that `--output` is an option that takes an argument. We completely ignore
  // this here.
  for i := 0; i < args.size; i++:
    arg := args[i]
    if arg == "--": break
    if arg == "--verbose":
      verbose-level = "verbose"
    else if arg == "--verbosity-level" or arg == "--verbose_level":
      if i + 1 >= args.size:
        // We will get an error during the real parsing of the args.
        break
      verbose-level = args[++i]
    else if arg.starts-with "--verbosity-level=" or arg.starts-with "--verbose_level=":
      verbose-level = arg["--verbosity-level=".size..]
    else if arg == "--output-format" or arg == "--output_format":
      if i + 1 >= args.size:
        // We will get an error during the real parsing of the args.
        break
      output-format = args[++i]
    else if arg.starts-with "--output-format=" or arg.starts-with "--output_format=":
      output-format = arg["--output-format=".size..]

  if verbose-level == null: verbose-level = "info"
  if output-format == null: output-format = "text"

  level/int := ?
  if verbose-level == "debug": level = Ui.DEBUG-LEVEL
  else if verbose-level == "info": level = Ui.NORMAL-LEVEL
  else if verbose-level == "verbose": level = Ui.VERBOSE-LEVEL
  else if verbose-level == "quiet": level = Ui.QUIET-LEVEL
  else if verbose-level == "silent": level = Ui.SILENT-LEVEL
  else: level = Ui.NORMAL-LEVEL

  if output-format == "json":
    return JsonUi --level=level
  else:
    return ConsoleUi --level=Ui.NORMAL-LEVEL

main args:
  config := read-config
  cache := Cache --app-name="artemis"
  ui := create-ui-from-args args
  main args --config=config --cache=cache --ui=ui

main args --config/Config --cache/Cache --ui/Ui:
  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    ui.result ARTEMIS-VERSION
    return

  root-cmd := cli.Command "root"
      --long-help="""
      A fleet management system for Toit devices.
      """
      --subcommands=[
        cli.Command "version"
            --long-help="Show the version of the Artemis tool."
            --run=:: ui.result ARTEMIS-VERSION,
      ]
      --options=[
        cli.Option "fleet-root"
            --type="directory"
            --short-help="Specify the fleet root. Can also be set with the ARTEMIS_FLEET_ROOT environment variable.",
        cli.OptionEnum "output-format"
            ["text", "json"]
            --short-help="Specify the format used when printing to the console."
            --default="text",
        cli.Flag "verbose"
            --short-help="Enable verbose output. Shorthand for --verbosity-level=verbose."
            --default=false,
        cli.OptionEnum "verbosity-level"
            ["debug", "info", "verbose", "quiet", "silent"]
            --short-help="Specify the verbosity level."
            --default="info",
      ]

  // TODO(florian): the ui should be configurable by flags.
  // This might be easier, once the UI is integrated with the cli
  // package, as the package could then pass it to the commands after
  // it has parsed the UI flags.
  (create-config-commands config cache ui).do: root-cmd.add it
  (create-auth-commands config cache ui).do: root-cmd.add it
  (create-org-commands config cache ui).do: root-cmd.add it
  (create-profile-commands config cache ui).do: root-cmd.add it
  (create-sdk-commands config cache ui).do: root-cmd.add it
  (create-device-commands config cache ui).do: root-cmd.add it
  (create-fleet-commands config cache ui).do: root-cmd.add it
  (create-pod-commands config cache ui).do: root-cmd.add it
  (create-serial-commands config cache ui).do: root-cmd.add it
  (create-doc-commands config cache ui).do: root-cmd.add it

  try:
    root-cmd.run args
  finally: | is-exception exception |
    if is-exception:
      str := "$exception"
      if str.size > 80:
        ui.error "Full exception: $str"
