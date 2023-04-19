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

  constructor .logger_ host/string port/int:
    host_ = host
    port_ = port

  connect --network/net.Client --device/Device -> ResourceManager:
    connection := HttpConnection_ network host_ port_
    return ResourceManagerHttp logger_ device connection
