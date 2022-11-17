// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .artemis_servers.artemis_server
import .broker
import .jobs

import ..shared.broker_config
import ..shared.postgrest as supabase


INTERVAL_ ::= Duration --m=20
INTERVAL_BETWEEN_ATTEMPTS_ ::= Duration --m=2

last_success_/JobTime? := null
last_attempt_/JobTime? := null

check_in_schedule now/JobTime -> JobTime:
  if not last_attempt_: return now
  next := last_attempt_ + INTERVAL_BETWEEN_ATTEMPTS_
  if last_success_: next = max next (last_success_ + INTERVAL_)
  return next

check_in_timeout -> Duration?:
  now := JobTime.now
  next := check_in_schedule now
  return now.to next

check_in network/net.Interface logger/log.Logger:
  now := JobTime.now
  next := check_in_schedule now
  if now < next: return

  last_attempt_ = now
  success := false
  try:
    // TODO(kasper): Let this be more mockable for testing.
    // For now, we just always fail to report when this
    // runs under tests.
    if not check_in_server_: return

    success = check_in_server_.check_in network logger
    if success: logger.info "status reporting succeeded"
    last_success_ = now
  finally:
    if not success: logger.warn "status reporting failed"

/**
Sets up the check-in functionality.

This is the service that contacts the Toitware backend to report that a
  certain device is online and using Artemis.
*/
check_in_setup assets/Map device/Map -> none:
  // For simplicity we are reusing the broker configurations for
  // the customer brokers for the Artemis-server configurations.
  broker_config := decode_broker_config "artemis.broker" assets
  if not broker_config: return

  hardware_id := device["hardware_id"]
  check_in_server_ = ArtemisServerService broker_config --hardware_id=hardware_id


check_in_server_/ArtemisServerService? := null
