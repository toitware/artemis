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

broker_options --artemis_only/bool=false -> List:
  if artemis_only: return [ BROKER_ARTEMIS_OPTION_ ]
  return [ BROKER_OPTION_, BROKER_ARTEMIS_OPTION_ ]

read_broker key/string parsed/cli.Parsed -> Map:
  broker_path := parsed[key]
  broker := json.decode (file.read_content broker_path)
  supabase_x := broker["supabase"]
  certificate_name := supabase_x["certificate"]
  // PEM certificates need to be zero terminated. Ugh.
  certificate := (file.read_content "config/certificates/$certificate_name") + #[0]
  supabase_x["certificate"] = certificate
  return broker
