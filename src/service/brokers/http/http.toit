// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import log
import net
import reader show Reader
import system show BITS-PER-WORD
import uuid show Uuid

import .connection
import ..broker
import ...device
import ....shared.broker-config show BrokerConfig

class BrokerServiceHttp implements BrokerService:
  logger_/log.Logger
  broker-config_/BrokerConfig

  constructor .logger_ .broker-config_:

  connect --network/net.Client --device/Device -> BrokerConnection:
    connection := HttpConnection_ network broker-config_
    return BrokerConnectionHttp
        logger_
        device
        connection
        broker-config_

class BrokerConnectionHttp implements BrokerConnection:
  device_/Device
  connection_/HttpConnection_
  config_/BrokerConfig
  logger_/log.Logger

  last-poll-us_/int? := null

  constructor .logger_ .device_ .connection_ .config_:

  fetch-goal-state --wait/bool -> Map?:
    last := last-poll-us_
    if last:
      elapsed := Duration --us=(Time.monotonic-us - last)
      interval := config_.poll-interval
      if elapsed < interval:
        if not wait: return null
        sleep interval - elapsed
    values := template-values_
    values["wait"] = wait
    url := expand-template_ config_.fetch-goal-state-url-template values
    result := connection_.send-json http.GET url
    last-poll-us_ = Time.monotonic-us
    return result

  fetch-image id/Uuid [block] -> none:
    values := template-values_
    values["id"] = id
    values["word-size"] = BITS-PER-WORD
    url := expand-template_ config_.fetch-image-url-template values
    connection_.download url: | reader/Reader |
      block.call reader

  fetch-firmware id/string --offset/int=0 [block] -> none:
    values := template-values_
    values["id"] = id
    values["offset"] = offset
    url := expand-template_ config_.fetch-firmware-url-template values
    connection_.download url --offset=offset: | reader/Reader |
      block.call reader offset

  report-state state/Map -> none:
    url := expand-template_ config_.report-state-url-template template-values_
    connection_.send-json http.PUT url state

  report-event --type/string data/any -> none:
    values := template-values_
    values["type"] = type
    url := expand-template_ config_.report-event-url-template values
    connection_.send-json http.POST url {
      "type": type,
      "data": data,
    }

  close -> none:
    connection_.close

  template-values_ -> Map:
    return {
      "device-id": "$device_.id",
      "organization-id": "$device_.organization-id",
    }

expand-template_ template/string values/Map -> string:
  result := template
  values.do: | name/string value/any |
    placeholder := "{$name}"
    if result.contains placeholder:
      result = result.replace --all placeholder "$value"
  return result
