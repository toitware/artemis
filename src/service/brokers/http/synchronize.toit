// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .connection
import .resources
import ...check_in show check_in
import ...device
import ..broker

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  host_/string
  port_/int

  device_/Device? := null
  connection_/HttpConnection_? := null

  // We don't know our state revision.
  // The server will ask us to reconcile.
  static STATE_REVISION_UNKNOWN_/int ::= -1
  state_revision_/int := STATE_REVISION_UNKNOWN_

  constructor .logger_ host/string port/int:
    host_ = host
    port_ = port

  connect --network/net.Client --device/Device [block]:
    check_in network logger_ --device=device

    connection := HttpConnection_ network host_ port_
    resources := ResourceManagerHttp device connection

    try:
      device_ = device
      connection_ = connection
      block.call resources
    finally:
      device_ = connection_ = null
      state_revision_ = STATE_REVISION_UNKNOWN_
      connection.close

  fetch_goal --wait/bool -> Map?:
    while true:
      // If we're not going to wait for a reply using long polling,
      // we force the server to respond with an out-of-sync message.
      state_revision := wait ? state_revision_ : STATE_REVISION_UNKNOWN_
      response := connection_.send_request "get_event" {
        "device_id": device_.id,
        "state_revision": state_revision,
      }

      if response["event_type"] == "goal_updated":
        state_revision_ = response["state_revision"]
        return response["goal"]

      if response["event_type"] == "out_of_sync":
        if response["state_revision"] == state_revision_:
          // We don't have a new goal state, so we're technically
          // not out-of-sync. This only happens when we're not
          // waiting for a response.
          assert: not wait
          throw DEADLINE_EXCEEDED_ERROR

        // We need to reconcile, so we ask for a new goal.
        goal_response := connection_.send_request "get_goal" {
          "device_id": device_.id,
        }
        // Even if the goal in the goal-response is null we return it,
        // since a null goal means that the device should revert to
        // the firmware state.
        state_revision_ = goal_response["state_revision"]
        return goal_response["goal"]

      if response["event_type"] == "timed_out":
        // For timeouts, we just take another iteration in the loop and
        // issue a new request.
        continue

      logger_.warn "unknown event received" --tags={"response": response}
