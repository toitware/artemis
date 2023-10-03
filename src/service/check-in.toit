// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .artemis-servers.artemis-server
import .device
import .jobs
import .periodic-network-request
import .utils

import ..shared.server-config

// TODO(kasper): Pass the check-in object to the synchronize
// job directly instead of forcing everything to go through
// the static state here.
check-in_/CheckInRequest? := null
check-in -> CheckInRequest?: return check-in_

class CheckInRequest extends PeriodicNetworkRequest:
  server_/ArtemisServerService
  constructor --device/Device --server/ArtemisServerService:
    server_ = server
    super "check-in" device
        --period=(Duration --h=24)
        --backoff=(Duration --m=30)

  request network/net.Interface logger/log.Logger -> none:
    server_.check-in network logger
    logger.info "succeeded"

/**
Sets up the check-in functionality.

This is the service that contacts the Toitware backend to report that a
  certain device is online and using Artemis.
*/
check-in-setup --assets/Map --device/Device -> none:
  server-config := decode-server-config "artemis.broker" assets
  if not server-config: return

  server := ArtemisServerService server-config
      --hardware-id=device.hardware-id
  check-in_ = CheckInRequest --device=device --server=server
