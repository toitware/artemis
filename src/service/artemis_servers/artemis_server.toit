// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .postgrest.supabase show ArtemisServerServiceSupabase
import ...shared.broker_config

/**
An abstraction for the Artemis server.

Devices check in with the server to report that they are alive and
  should be billed.
*/
interface ArtemisServerService:
  constructor broker_config/BrokerConfig --hardware_id/string:
    if broker_config is BrokerConfigSupabase:
      return ArtemisServerServiceSupabase
          (broker_config as BrokerConfigSupabase)
          --hardware_id=hardware_id
    throw "UNSUPPORTED BROKER_CONFIG"

  /**
  Checks in with the server.

  Returns true if the check in succeeded. False otherwise.

  # Inheritance
  This function should not throw.
  */
  check_in network/net.Interface logger/log.Logger -> bool
