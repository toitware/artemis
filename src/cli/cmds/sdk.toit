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
      --help="List supported SDKs. REMOVED."
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
  print "Artemis now compiles the service locally, and services are not downloaded from the server anymore."
  invocation.cli.ui.abort "UNSUPPORTED"
