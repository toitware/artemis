// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import host.file

BROKER_OPTION_ ::= cli.OptionString "broker" --default="toitware-testing"
BROKER_ARTEMIS_OPTION_ ::= cli.OptionString "broker.artemis" --default="artemis"

broker_options -> List:
  return [ BROKER_OPTION_, BROKER_ARTEMIS_OPTION_ ]

