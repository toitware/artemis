// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import log
import supabase
import uuid
import .broker
import .supabase_broker_policies_shared

main:
  with_broker --type="supabase-local" --logger=log.default: | broker/TestBroker |
    server_config := broker.server_config as ServerConfigSupabase
    client_anon := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client1 := supabase.Client --server_config=server_config --certificate_provider=:unreachable

    email := "$(random)@toit.io"
    password := "password"
    client1.auth.sign_up --email=email --password=password
    // On local setups, the sign up does not need to be confirmed.
    client1.auth.sign_in --email=email --password=password

    run_shared_test --client1=client1 --client_anon=client_anon
