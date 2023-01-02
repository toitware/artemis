// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

BROKER_OPTION_ ::= cli.OptionString "broker"
BROKER_ARTEMIS_OPTION_ ::= cli.OptionString "broker.artemis" --hidden

broker_options -> List:
  return [ BROKER_OPTION_, BROKER_ARTEMIS_OPTION_ ]
