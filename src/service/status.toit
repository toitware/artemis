// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import net.x509
import log
import http
import encoding.tison
import encoding.json

import .broker
import .jobs

import .device
import ..shared.postgrest as supabase
import ..shared.broker_config

INTERVAL ::= Duration --m=20
INTERVAL_BETWEEN_ATTEMPTS ::= Duration --m=2

last_success_/JobTime? := null
last_attempt_/JobTime? := null

report_status_schedule now/JobTime -> JobTime:
  if not last_attempt_: return now
  next := last_attempt_ + INTERVAL_BETWEEN_ATTEMPTS
  if last_success_: next = max next (last_success_ + INTERVAL)
  return next

report_status_timeout -> Duration?:
  now := JobTime.now
  next := report_status_schedule now
  return now.to next

report_status network/net.Interface logger/log.Logger -> none:
  now := JobTime.now
  next := report_status_schedule now
  if now < next: return

  last_attempt_ = now
  success := false
  try:
    // TODO(kasper): Let this be more mockable for testing.
    // For now, we just always fail to report when this
    // runs under tests.
    if not report_status_broker_: return

    client := supabase.create_client network report_status_broker_
        --certificate_provider=: throw "UNSUPPORTED"

    // TODO(kasper): We need some timeout here.
    response := client.post report_status_payload_
        --host=report_status_broker_.host
        --headers=report_status_headers_
        --path=report_status_path_
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code == 201:
      logger.info "status reporting succeeded"
      last_success_ = now
      success = true
  finally:
    if not success: logger.warn "status reporting failed"

report_status_setup assets/Map device/Map -> Device?:
  generic_broker := decode_broker_config "artemis.broker" assets
  if not generic_broker: return null

  broker := generic_broker as SupabaseBrokerConfig

  report_status_headers_ = http.Headers
  anon := broker.anon
  report_status_headers_.add "apikey" anon
  report_status_headers_.add "Authorization" "Bearer $anon"

  hardware_id := device["hardware_id"]
  report_status_path_ = "/rest/v1/events"
  report_status_payload_ = """{
    "device": "$(json.escape_string hardware_id)",
    "data": { "type": "ping" }
  }""".to_byte_array

  return Device device["device_id"]

// TODO(kasper): These should probably be encapsulated in an object.
report_status_broker_/SupabaseBrokerConfig? := null
report_status_headers_/http.Headers? := null
report_status_path_/string := ""
report_status_payload_/ByteArray? := null
