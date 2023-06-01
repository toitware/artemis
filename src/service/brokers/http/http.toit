// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import uuid

import .connection
import ..broker
import ...device
import ....shared.constants show *

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  host_/string
  port_/int
  path_/string

  constructor .logger_ --host/string --port/int --path/string:
    host_ = host
    port_ = port
    path_ = path

  connect --network/net.Client --device/Device -> BrokerConnection:
    connection := HttpConnection_ network host_ port_ path_
    return BrokerConnectionHttp logger_ device connection


class BrokerConnectionHttp implements BrokerConnection:
  device_/Device
  connection_/HttpConnection_
  logger_/log.Logger

  poll_interval_/Duration := Duration --ms=10
  last_poll_us_/int? := null

  // We don't know our state revision.
  // The server will ask us to reconcile.
  static STATE_REVISION_UNKNOWN_/int ::= -1
  state_revision_/int := STATE_REVISION_UNKNOWN_

  constructor .logger_ .device_ .connection_:

  fetch_goal --wait/bool -> Map?:
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
      "public": true,
      "path": "/toit-artemis-assets/$device_.organization_id/images/$id.$BITS_PER_WORD",
    }
    connection_.send_request COMMAND_DOWNLOAD_ payload: | reader/Reader |
      block.call reader

  fetch_firmware id/string --offset/int=0 [block] -> none:
    payload := {
      "public": true,
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
