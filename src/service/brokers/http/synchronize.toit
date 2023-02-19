// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import .connection
import .resources
import ...check_in show check_in
import ..broker

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  connection_/HttpConnection_

  constructor .logger_ host/string port/int:
    connection_ = HttpConnection_ host port

  connect --device_id/string --callback/EventHandler [block]:
    network := net.open
    check_in network logger_
    network.close

    resources := ResourceManagerHttp connection_

    handle_task/Task? := ?
    handle_task = task --background::
      // We don't know our state revision.
      // The server will ask us to reconcile.
      state_revision := -1
      while not connection_.is_closed:
        // Long poll for new events.
        response := connection_.send_request "get_event" {
          "device_id": device_id,
          "state_revision": state_revision,
        }
        if response["event_type"] == "goal_updated":
          callback.handle_goal response["goal"] resources
          state_revision = response["state_revision"]
        else if response["event_type"] == "out_of_sync":
          // We need to reconcile.
          // At the moment the only thing that we need to synchronize is the
          // goal state.
          // TODO(florian): centralize the things that need to be synchronized.
          goal_response := connection_.send_request "get_goal" {
            "device_id": device_id,
          }
          // Even if the goal-response is empty, notify the callback, since
          // an empty goal means that the device should revert to the firmware
          // state.
          callback.handle_goal goal_response resources
          state_revision = response["state_revision"]
        else:
          print "unknown event received: $response"
          callback.handle_nop

    block.call resources
    handle_task.cancel

  on_idle -> none:
