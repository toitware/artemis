// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show *
import core as core
import host.pipe show stderr
import io

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

import .utils show is-dev-setup

import ..shared.version

main args:
  main args --cli=null

main args --cli/Cli?:
  certificate-roots.install-all-trusted-roots

  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    if cli:
      cli.ui.emit --result ARTEMIS-VERSION
    else:
      core.print ARTEMIS-VERSION
    return

  root-cmd := Command (is-dev-setup ? "artemis-dev" : "artemis")
      --help="""
      A fleet management system for Toit devices.
      """
      --subcommands=[
        Command "version"
            --help="Show the version of the Artemis tool."
            --run=:: | invocation/Invocation |
              invocation.cli.ui.emit --result ARTEMIS-VERSION,
      ]
      --options=[
        Option "fleet-root"
            --type="directory"
            --help="Specify the fleet root. Can also be set with the ARTEMIS_FLEET_ROOT environment variable."
            --hidden,
        Option "fleet"
            --type="directory|reference"
            --help="Specify the fleet. Can also be set with the ARTEMIS_FLEET environment variable.",
      ]

  create-config-commands.do: root-cmd.add it
  create-auth-commands.do: root-cmd.add it
  create-org-commands.do: root-cmd.add it
  create-profile-commands.do: root-cmd.add it
  create-sdk-commands.do: root-cmd.add it
  create-device-commands.do: root-cmd.add it
  create-fleet-commands.do: root-cmd.add it
  create-pod-commands.do: root-cmd.add it
  create-serial-commands.do: root-cmd.add it
  create-doc-commands.do: root-cmd.add it

  assert:
    // Check that the root command is correctly set up.
    root-cmd.check
    true

  try:
    root-cmd.run args --cli=cli
  finally: | is-exception exception |
    if is-exception:
      // Exception traces only contain the first 80 characters
      // of the exception value. We want all of it!
      str := "$exception.value"
      if str.size > 80:
        if cli:
          cli.ui.emit --error "Full exception: $str"
        else:
          (stderr.out as io.Writer).write "Full exception: $str\n"
