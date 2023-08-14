// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import uuid

import .supabase show ArtemisServerServiceSupabase
import .http.base show ArtemisServerServiceHttp
import ...shared.server-config

/**
An abstraction for the Artemis server.

Devices check in with the server to report that they are alive and
  should be billed.
*/
interface ArtemisServerService:
  constructor server-config/ServerConfig --hardware-id/uuid.Uuid:
    if server-config is ServerConfigSupabase:
      return ArtemisServerServiceSupabase
          (server-config as ServerConfigSupabase)
          --hardware-id=hardware-id
    if server-config is ServerConfigHttp:
      return ArtemisServerServiceHttp
          (server-config as ServerConfigHttp)
          --hardware-id=hardware-id
    throw "UNSUPPORTED ARTEMIS SERVER CONFIG"

  /**
  Checks in with the server.

  Throws an exception if the check in fails.
  */
  check-in network/net.Interface logger/log.Logger -> none
