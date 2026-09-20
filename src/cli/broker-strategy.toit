// Copyright (C) 2026 Toit contributors. All rights reserved.

import cli show Cli
import uuid show Uuid

import .broker show Broker
import .server-config show ServerConfig

/** Opens one configured broker client. */
interface BrokerStrategy:
  /** Opens the configured broker client. */
  open -> Broker

/** Opens the current combined broker implementation from legacy configuration. */
class LegacyBrokerStrategy implements BrokerStrategy:
  configuration_/ServerConfig
  fleet-id_/Uuid
  tmp-directory_/string
  short-strings_/Map?
  cli_/Cli

  constructor
      --configuration/ServerConfig
      --fleet-id/Uuid
      --tmp-directory/string
      --short-strings/Map?
      --cli/Cli:
    configuration_ = configuration
    fleet-id_ = fleet-id
    tmp-directory_ = tmp-directory
    short-strings_ = short-strings
    cli_ = cli

  open -> Broker:
    return Broker
        --server-config=configuration_
        --fleet-id=fleet-id_
        --tmp-directory=tmp-directory_
        --short-strings=short-strings_
        --cli=cli_
