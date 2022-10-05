// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import net.x509
import log
import http
import encoding.tison

import .jobs
import ..shared.device show Device

ENABLED_ := false
INTERVAL ::= Duration --m=20
INTERVAL_BETWEEN_ATTEMPTS ::= Duration --m=2

last_success_/JobTime? := null
last_attempt_/JobTime? := null

ping_schedule now/JobTime -> JobTime:
  if not last_attempt_: return now
  next := last_attempt_ + INTERVAL_BETWEEN_ATTEMPTS
  if last_success_: next = max next (last_success_ + INTERVAL)
  return next

ping_timeout -> Duration?:
  if not ENABLED_: return null
  now := JobTime.now
  next := ping_schedule now
  return now.to next

ping_monitoring network/net.Interface logger/log.Logger -> none:
  if not ENABLED_: return
  now := JobTime.now
  next := ping_schedule now
  if now < next: return

  last_attempt_ = now
  success := false
  try:
    client := ping_create_client_ network ping_certificate_text_
    // TODO(kasper): We need some timeout here.
    response := client.post ping_payload_
        --host=ping_host_
        --headers=ping_headers_
        --path=ping_path_
    if response.status_code == 201:
      logger.info "status reporting succeeded"
      last_success_ = now
      success = true
  finally:
    if not success: logger.warn "status reporting failed"

ping_setup assets/Map -> Device?:
  device := ping_device_assets "artemis.device" assets
  if not device: return null

  ping_host_ = device["supabase"]["host"]
  ping_headers_ = http.Headers
  anon := device["supabase"]["anon"]
  ping_headers_.add "apikey" anon
  ping_headers_.add "Authorization" "Bearer $anon"
  ping_certificate_text_ = device["supabase"]["certificate"]

  hardware_id := device["hardware_id"]
  fleet_id := device["fleet_id"]
  ping_path_ = "/rest/v1/events-$fleet_id"
  // TODO(kasper): json escape hardware-id.
  ping_payload_ = """{
    "device": "$hardware_id",
    "data": { "type": "ping" }
  }""".to_byte_array

  ENABLED_ = true
  return Device device["device_id"]

ping_device_assets key/string assets/Map -> Map?:
  device := assets.get key --if_present=: tison.decode it
  if not device: return null
  if supabase := device.get "supabase":
    certificate_name := supabase["certificate"]
    certificate := assets.get certificate_name
    // TODO(kasper): Fix x509 certificate parser to accept slices.
    if certificate is ByteArraySlice_: certificate = certificate.copy
    supabase["certificate"] = certificate
  return device

ping_create_client_ network/net.Interface certificate_text/any -> http.Client:
  certificate := x509.Certificate.parse certificate_text
  return http.Client.tls network --root_certificates=[certificate]

ping_host_/string := ""
ping_headers_/http.Headers? := null
ping_certificate_text_/any := null
ping_path_/string := ""
ping_payload_/ByteArray? := null
