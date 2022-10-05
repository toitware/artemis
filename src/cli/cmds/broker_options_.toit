// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import encoding.json
import host.file

BROKER_OPTION_ ::= cli.OptionString "broker"
        --default="config/brokers/toitware-testing.broker"
        --type="file"

BROKER_ARTEMIS_OPTION_ ::= cli.OptionString "broker.artemis"
    --default="config/brokers/artemis.broker"
    --type="file"

broker_options -> List:
  return [ BROKER_OPTION_, BROKER_ARTEMIS_OPTION_ ]
