// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import reader show Reader
import uuid

import .connection
import ..broker
import ...device

class ResourceManagerHttp implements ResourceManager:
  device_/Device
  connection_/HttpConnection_
  logger_/log.Logger

  // We don't know our state revision.
  // The server will ask us to reconcile.
  static STATE_REVISION_UNKNOWN_/int ::= -1
  state_revision_/int := STATE_REVISION_UNKNOWN_

  constructor .logger_ .device_ .connection_:

  fetch_goal --wait/bool -> Map?:
    while true:
      // If we're not going to wait for a reply using long polling,
      // we force the server to respond with an out-of-sync message.
      state_revision := wait ? state_revision_ : STATE_REVISION_UNKNOWN_
      response := connection_.send_request "get_event" {
        "device_id": "$device_.id",
        "state_revision": state_revision,
      }

      response_event_type := response["event_type"]
      if response_event_type == "goal_updated":
        state_revision_ = response["state_revision"]
        return response["goal"]

      is_out_of_sync := response_event_type == "out_of_sync"
      is_timed_out := response_event_type == "timed_out"
      if is_out_of_sync and state_revision_ == response["state_revision"]:
        // We don't have a new goal state, so we're technically
        // not out-of-sync. This only happens when we're not
        // waiting for a response.
        assert: not wait
        throw DEADLINE_EXCEEDED_ERROR

      if is_out_of_sync or is_timed_out:
        // We need to reconcile or produce a new goal, so we
        // ask explicitly for the goal.
        goal_response := connection_.send_request "get_goal" {
          "device_id": "$device_.id",
        }
        // Even if the goal in the goal-response is null we return it,
        // since a null goal means that the device should revert to
        // the firmware state.
        state_revision_ = goal_response["state_revision"]
        return goal_response["goal"]

      logger_.warn "unknown event received" --tags={"response": response}

  fetch_image id/uuid.Uuid [block] -> none:
    payload :=  {
      "path": "/toit-artemis-assets/$device_.organization_id/images/$id.$BITS_PER_WORD",
    }
    connection_.send_binary_request "download" payload: | reader/Reader |
      block.call reader

  fetch_firmware id/string --offset/int=0 [block] -> none:
    payload := {
      "path": "/toit-artemis-assets/$device_.organization_id/firmware/$id",
      "offset": offset,
    }
    connection_.send_binary_request "download" payload: | reader/Reader |
      block.call reader offset

  report_state state/Map -> none:
    connection_.send_request "report_state" {
      "device_id": "$device_.id",
      "state": state,
    }

  report_event --type/string data/any -> none:
    connection_.send_request "report_event" {
      "device_id": "$device_.id",
      "type": type,
      "data": data,
    }

  close -> none:
    connection_.close
