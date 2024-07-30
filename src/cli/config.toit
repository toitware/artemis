// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import supabase

// When adding a new config don't forget to update the 'config show' command.
CONFIG-DEVICE-DEFAULT-KEY ::= "device.default"
CONFIG-BROKER-DEFAULT-KEY ::= "server.broker.default"
CONFIG-ARTEMIS-DEFAULT-KEY ::= "server.artemis.default"
CONFIG-SERVERS-KEY ::= "servers"
CONFIG-SERVER-AUTHS-KEY ::= "auths"
CONFIG-RECOVERY-SERVERS-KEY ::= "recovery"
CONFIG-ORGANIZATION-DEFAULT-KEY ::= "organization.default"
// When adding a new config don't forget to update the 'config show' command.

class ConfigLocalStorage implements supabase.LocalStorage:
  cli_/Cli
  auth-key_/string

  constructor --cli/Cli --auth-key/string="":
    cli_ = cli
    auth-key_ = auth-key

  has-auth -> bool:
    return cli_.config.contains auth-key_

  get-auth -> any?:
    return cli_.config.get auth-key_

  set-auth value/any:
    cli_.config[auth-key_] = value
    cli_.config.write

  remove-auth -> none:
    cli_.config.remove auth-key_
    cli_.config.write
