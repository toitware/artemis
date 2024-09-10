// Copyright (C) 2024 Toitware ApS. All rights reserved.

import cli show Cli
import supabase

/**
A simple wrapper that forwards the info messages to the cli.
*/
class SupabaseUi implements supabase.Ui:
  cli_/Cli

  constructor .cli_:

  info msg/string -> none:
    cli_.ui.inform msg
