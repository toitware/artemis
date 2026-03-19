// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *

create-sdk-commands -> List:
  sdk-cmd := Command "sdk"
      --help="Information about supported SDKs."

  list-cmd := Command "list"
      --aliases=["ls"]
      --help="List supported SDKs."
      --run=:: list-sdks it
  sdk-cmd.add list-cmd

  return [sdk-cmd]

list-sdks invocation/Invocation:
  invocation.cli.ui.abort "The 'sdk list' command is no longer supported."
