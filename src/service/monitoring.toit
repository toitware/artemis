// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import log

import .jobs
import ..shared.postgrest.supabase as supabase

INTERVAL ::= Duration --m=1

// TODO(kasper): Implement backoff.
MIN_TIME_BETWEEN_ATTEMPTS ::= Duration --s=20

last_success_/JobTime? := null
last_attempt_/JobTime? := null

ping_schedule now/JobTime -> JobTime:
  if not last_attempt_: return now
  next := last_attempt_ + MIN_TIME_BETWEEN_ATTEMPTS
  if now < next: return next
  if not last_success_: return now
  return last_success_ + INTERVAL

ping_timeout -> Duration:
  now := JobTime.now
  next := ping_schedule now
  return now.to next

ping_monitoring network/net.Interface logger/log.Logger -> none:
  now := JobTime.now
  if now < (ping_schedule now): return

  last_attempt_ = now
  success := false
  try:
    client := supabase.supabase_create_client network
    hardware_id := "fa5b0234-7b1f-4f9d-bc68-352a17abdd1a"
    fleet_id := "c6fb0602-79a6-4cc3-b1ee-08df55fb30ad"
    table := "events-$fleet_id"

    payload := """{
      "device": "$hardware_id",
      "data": { "type": "ping" }
    }"""

    headers := supabase.supabase_create_headers
    // TODO(kasper): We need some timeout here.
    response := client.post payload.to_byte_array
        --host=supabase.SUPABASE_HOST
        --headers=headers
        --path="/rest/v1/$table"

    if response.status_code == 201:
      logger.info "status reporting succeeded"
      last_success_ = now
      success = true
  finally:
    if not success: logger.warn "status reporting failed"
