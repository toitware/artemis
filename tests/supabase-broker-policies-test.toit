// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server-config as cli-server-config
import artemis.shared.server-config show ServerConfigSupabase
import expect show *
import log
import supabase
import .broker
import .supabase-broker-policies-shared

main args:
  with-broker --args=args --type="supabase-local" --logger=log.default: | broker/TestBroker |
    server-config := broker.server-config as ServerConfigSupabase
    client-anon := supabase.Client --server-config=server-config
    client1 := supabase.Client --server-config=server-config

    email := "$(random)@toit.io"
    password := "password"
    client1.auth.sign-up --email=email --password=password
    // On local setups, the sign up does not need to be confirmed.
    client1.auth.sign-in --email=email --password=password

    run-shared-test --client1=client1 --client-anon=client-anon
    run-shared-pod-description-test
        --client1=client1
        --other-clients=[client-anon]
