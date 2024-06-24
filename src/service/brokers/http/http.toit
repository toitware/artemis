// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import log
import net
import reader show Reader
import system show BITS-PER-WORD
import uuid

import .connection
import ..broker
import ...device
import ....shared.constants show *
import ....shared.server-config show ServerConfigHttp

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  server-config_/ServerConfigHttp

  constructor .logger_ .server-config_:

  connect --network/net.Client --device/Device -> BrokerConnection:
    connection := HttpConnection_ network server-config_
    return BrokerConnectionHttp logger_ device connection server-config_.poll-interval

class BrokerConnectionHttp implements BrokerConnection:
  device_/Device
  connection_/HttpConnection_
  logger_/log.Logger

  poll-interval_/Duration
  last-poll-us_/int? := null

  constructor .logger_ .device_ .connection_ .poll-interval_:

  fetch-goal-state --wait/bool -> Map?:
    // We deliberately delay fetching from the cloud, so we
    // can avoid fetching from the cloud over and over again.
    last := last-poll-us_
    if last:
      elapsed := Duration --us=(Time.monotonic-us - last)
      interval := poll-interval_
      if elapsed < interval:
        // We are not yet supposed to go online.
        // If we are allowed to wait, do so. Otherwise return null.
        if not wait: return null
        sleep interval - elapsed
    result := connection_.send-request COMMAND-GET-GOAL_ {
      "_device_id": "$device_.id",
    }
    last-poll-us_ = Time.monotonic-us
    return result

  fetch-image id/uuid.Uuid [block] -> none:
    payload :=  {
      "path": "/toit-artemis-assets/$device_.organization-id/images/$id.$BITS-PER-WORD",
    }
    connection_.send-request COMMAND-DOWNLOAD_ payload: | reader/Reader |
      block.call reader

  fetch-firmware id/string --offset/int=0 [block] -> none:
    payload := {
      "path": "/toit-artemis-assets/$device_.organization-id/firmware/$id",
      "offset": offset,
    }
    expected-status := offset == 0 ? null : http.STATUS-PARTIAL-CONTENT
    connection_.send-request COMMAND-DOWNLOAD_ payload --expected-status=expected-status:
      | reader/Reader |
      block.call reader offset

  report-state state/Map -> none:
    connection_.send-request COMMAND-REPORT-STATE_ {
      "_device_id": "$device_.id",
      "_state": state,
    }

  report-event --type/string data/any -> none:
    connection_.send-request COMMAND-REPORT-EVENT_ {
      "_device_id": "$device_.id",
      "_type": type,
      "_data": data,
    }

  close -> none:
    connection_.close
