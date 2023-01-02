// Copyright (C) 2022 Toitware ApS.

import .brokers

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import .utils

main:
  with_test_cli
      --artemis_type="supabase"
      --broker_type="supabase"
      --no-start_device_artemis
      : | test_cli/TestCli _ |
        test_cli.run [
          "auth", "artemis", "login",
          "--email", TEST_EXAMPLE_COM_EMAIL,
          "--password", TEST_EXAMPLE_COM_PASSWORD,
        ]
        test_cli.run [
          "provision",
          "create-identity",
          "--organization-id",
          TEST_ORGANIZATION_UUID
        ]
