// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import supabase

import .resources
import ..broker

import ...check_in show check_in
import ...device
import ....shared.server_config

class BrokerServiceSupabase implements BrokerService:
  logger_/log.Logger
  broker_/ServerConfigSupabase
  constructor .logger_ .broker_:

  connect --network/net.Client --device/Device -> ResourceManager:
    client := supabase.Client network --server_config=broker_
        --certificate_provider=: throw "UNSUPPORTED"
    return ResourceManagerSupabase device client broker_.poll_interval
