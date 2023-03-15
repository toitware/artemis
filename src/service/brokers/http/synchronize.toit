// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import net

import .connection
import .resources
import ...check_in show check_in
import ..broker

IDLE_TIMEOUT ::= Duration --m=10

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  host_/string
  port_/int
  idle_/monitor.Gate ::= monitor.Gate

  constructor .logger_ host/string port/int:
    host_ = host
    port_ = port

  connect --device_id/string --callback/EventHandler [block]:
    network := net.open
    check_in network logger_

    connection := HttpConnection_ network host_ port_
    resources := ResourceManagerHttp connection
    disconnected := monitor.Latch

    // Always start non-idle and wait for the $block to call
    // the $on_idle method when it is ready for the handle
    // task to do its work. This avoids processing multiple
    // requests at once.
    idle_.lock

    handle_task/Task? := ?
    handle_task = task --background::
      // We don't know our state revision.
      // The server will ask us to reconcile.
      state_revision := -1
      try:
        while true:
          // Long poll for new events.
          with_timeout IDLE_TIMEOUT: idle_.enter
          response := connection.send_request "get_event" {
            "device_id": device_id,
            "state_revision": state_revision,
          }
          idle_.lock
          if response["event_type"] == "goal_updated":
            callback.handle_goal response["goal"] resources
            state_revision = response["state_revision"]
          else if response["event_type"] == "out_of_sync":
            // We need to reconcile.
            // At the moment the only thing that we need to synchronize is the
            // goal state.
            // TODO(florian): centralize the things that need to be synchronized.
            goal_response := connection.send_request "get_goal" {
              "device_id": device_id,
            }
            // Even if the goal-response is empty, notify the callback, since
            // an empty goal means that the device should revert to the firmware
            // state.
            callback.handle_goal goal_response resources
            state_revision = response["state_revision"]
          else if response["event_type"] == "timed_out":
            // For timeouts, we just unlock the gate so we can take another
            // iteration in the loop and issue a new request.
            idle_.unlock
          else:
            logger_.warn "unknown event received" --tags={"response": response}
            callback.handle_nop
      finally:
        critical_do: disconnected.set true
        handle_task = null

    try:
      block.call resources
    finally:
      if handle_task: handle_task.cancel
      disconnected.get
      connection.close
      network.close

  on_idle -> none:
    idle_.unlock
