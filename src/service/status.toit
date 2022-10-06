// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import net.x509
import log
import http
import encoding.tison
import encoding.json

import .broker
import .jobs

import ..shared.device show Device
import ..shared.postgrest.supabase as supabase

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
    if report_status_host_.is_empty: return

    // TODO(kasper): It is silly to generate a map here.
    client := supabase.create_client network {
      "supabase": {
        "certificate": report_status_certificate_text_
      }
    }
    // TODO(kasper): We need some timeout here.
    response := client.post report_status_payload_
        --host=report_status_host_
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

report_status_setup assets/Map -> Device?:
  device := decode_broker "artemis.device" assets
  if not device: return null

  report_status_host_ = device["supabase"]["host"]
  report_status_headers_ = http.Headers
  anon := device["supabase"]["anon"]
  report_status_headers_.add "apikey" anon
  report_status_headers_.add "Authorization" "Bearer $anon"
  report_status_certificate_text_ = device["supabase"]["certificate"]

  hardware_id := device["hardware_id"]
  fleet_id := device["fleet_id"]
  report_status_path_ = "/rest/v1/events-$fleet_id"
  report_status_payload_ = """{
    "device": "$(json.escape_string hardware_id)",
    "data": { "type": "ping" }
  }""".to_byte_array

  return Device device["device_id"]

// TODO(kasper): These should probably be encapsulated in an object.
report_status_host_/string := ""
report_status_headers_/http.Headers? := null
report_status_certificate_text_/any := null
report_status_path_/string := ""
report_status_payload_/ByteArray? := null
