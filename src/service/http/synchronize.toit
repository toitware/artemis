// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import .connection
import .resources
import ..status show report_status
import ..mediator_service

class MediatorServiceHttp implements MediatorService:
  logger_/log.Logger
  connection_/HttpConnection_

  constructor .logger_ host/string port/int:
    connection_ = HttpConnection_ host port

  connect --device_id/string --callback/EventHandler [block]:
    network := net.open
    report_status network logger_
    network.close

    resources := ResourceManagerHttp connection_

    handle_task/Task? := ?
    handle_task = task::
      while not connection_.is_closed:
        response := connection_.send_request "get_event" {
          "device_id": device_id,
        }
        if response["event_type"] == "config_updated":
          callback.handle_update_config response["config"] resources
        else:
          print "unknown event received: $response"
          callback.handle_nop

    block.call resources
    handle_task.cancel

  on_idle -> none:
