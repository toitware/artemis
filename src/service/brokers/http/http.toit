// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import uuid

import .connection
import ..broker
import ...device
import ....shared.constants show *
import ....shared.server_config show ServerConfigHttp

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  server_config_/ServerConfigHttp

  constructor .logger_ .server_config_:

  connect --network/net.Client --device/Device -> BrokerConnection:
    connection := HttpConnection_ network server_config_
    return BrokerConnectionHttp logger_ device connection server_config_.poll_interval


class BrokerConnectionHttp implements BrokerConnection:
  device_/Device
  connection_/HttpConnection_
  logger_/log.Logger

  poll_interval_/Duration
  last_poll_us_/int? := null

  constructor .logger_ .device_ .connection_ .poll_interval_:

  fetch_goal_state --wait/bool -> Map?:
    // We deliberately delay fetching from the cloud, so we
    // can avoid fetching from the cloud over and over again.
    last := last_poll_us_
    if last:
      elapsed := Duration --us=(Time.monotonic_us - last)
      interval := poll_interval_
      if elapsed < interval:
        // We are not yet supposed to go online.
        // If we are allowed to wait, do so. Otherwise return null.
        if not wait: return null
        sleep interval - elapsed
    result := connection_.send_request COMMAND_GET_GOAL_ {
      "_device_id": "$device_.id",
    }
    last_poll_us_ = Time.monotonic_us
    return result

  fetch_image id/uuid.Uuid [block] -> none:
    payload :=  {
      "path": "/toit-artemis-assets/$device_.organization_id/images/$id.$BITS_PER_WORD",
    }
    connection_.send_request COMMAND_DOWNLOAD_ payload: | reader/Reader |
      block.call reader

  fetch_firmware id/string --offset/int=0 [block] -> none:
    payload := {
      "path": "/toit-artemis-assets/$device_.organization_id/firmware/$id",
      "offset": offset,
    }
    connection_.send_request COMMAND_DOWNLOAD_ payload: | reader/Reader |
      block.call reader offset

  report_state state/Map -> none:
    connection_.send_request COMMAND_REPORT_STATE_ {
      "_device_id": "$device_.id",
      "_state": state,
    }

  report_event --type/string data/any -> none:
    connection_.send_request COMMAND_REPORT_EVENT_ {
      "_device_id": "$device_.id",
      "_type": type,
      "_data": data,
    }

  close -> none:
    connection_.close
