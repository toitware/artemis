// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import uuid

import .supabase show ArtemisServerServiceSupabase
import .http.base show ArtemisServerServiceHttp
import ...shared.server_config

/**
An abstraction for the Artemis server.

Devices check in with the server to report that they are alive and
  should be billed.
*/
interface ArtemisServerService:
  constructor server_config/ServerConfig --hardware_id/uuid.Uuid:
    if server_config is ServerConfigSupabase:
      return ArtemisServerServiceSupabase
          (server_config as ServerConfigSupabase)
          --hardware_id=hardware_id
    if server_config is ServerConfigHttpToit:
      return ArtemisServerServiceHttp
          (server_config as ServerConfigHttpToit)
          --hardware_id=hardware_id
    throw "UNSUPPORTED ARTEMIS SERVER CONFIG"

  /**
  Checks in with the server.

  Throws an exception if the check in fails.
  */
  check_in network/net.Interface logger/log.Logger -> none
