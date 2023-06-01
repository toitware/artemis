// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import supabase
import uuid

import ..broker
import ...device
import ....shared.server_config

class BrokerServiceSupabase implements BrokerService:
  logger_/log.Logger
  broker_/ServerConfigSupabase
  constructor .logger_ .broker_:

  connect --network/net.Client --device/Device -> BrokerConnection:
    client := supabase.Client network --server_config=broker_
        --certificate_provider=: throw "UNSUPPORTED"
    return BrokerConnectionSupabase device client broker_.poll_interval

class BrokerConnectionSupabase implements BrokerConnection:
  device_/Device
  client_/supabase.Client

  poll_interval_/Duration
  last_poll_us_/int? := null

  constructor .device_ .client_ .poll_interval_:

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
    result := client_.rest.rpc "toit_artemis.get_goal" {
      "_device_id": "$device_.id",
    }
    last_poll_us_ = Time.monotonic_us
    return result

  fetch_image id/uuid.Uuid [block] -> none:
    client_.storage.download
        --public
        --path="/toit-artemis-assets/$device_.organization_id/images/$id.$BITS_PER_WORD"
        block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    path := "/toit-artemis-assets/$device_.organization_id/firmware/$id"
    client_.storage.download
        --public
        --path=path
        --offset=offset
        : | reader/Reader |
          block.call reader offset

  report_state state/Map -> none:
    client_.rest.rpc "toit_artemis.update_state" {
      "_device_id" : "$device_.id",
      "_state" : state,
    }

  report_event --type/string data/any -> none:
    client_.rest.rpc "toit_artemis.report_event" {
      "_device_id" : "$device_.id",
      "_type" : type,
      "_data" : data,
    }

  close -> none:
    client_.close
