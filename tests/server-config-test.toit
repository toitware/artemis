// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.shared.broker-config show BrokerConfig
import artemis.shared.server-config show
    ServerConfig
    ServerConfigHttp
    ServerConfigSupabase
import expect show *

main:
  test-supabase-templates
  test-http-templates
  test-legacy-configs

test-supabase-templates:
  config := ServerConfigSupabase
      "supabase"
      --url="http://localhost:54321/"
      --anon="anon"
  cli-json := config.to-json --base64 --der-serializer=: unreachable
  expect-equals "http://localhost:54321" cli-json["url"]
  expect-not (cli-json.contains "host")
  expect-not (cli-json.contains "use_tls")
  encoded := config.to-service-json --base64 --der-serializer=: unreachable
  expect-not (encoded.contains "type")
  expect-equals
      "http://localhost:54321/functions/v1/device/{device-id}/goal"
      encoded["fetch_goal_state_url_template"]
  expect-equals
      "http://localhost:54321/storage/v1/object/public/toit-artemis-assets/{organization-id}/images/{id}.{word-size}"
      encoded["fetch_image_url_template"]
  expect-equals
      "http://localhost:54321/storage/v1/object/public/toit-artemis-assets/{organization-id}/firmware/{id}"
      encoded["fetch_firmware_url_template"]
  expect-equals
      "http://localhost:54321/functions/v1/device/{device-id}/state"
      encoded["report_state_url_template"]
  expect-equals
      "http://localhost:54321/functions/v1/device/{device-id}/events"
      encoded["report_event_url_template"]

  decoded := BrokerConfig.from-json encoded --der-deserializer=: unreachable
  expect-equals
      encoded["fetch_goal_state_url_template"]
      decoded.fetch-goal-state-url-template

test-http-templates:
  config := ServerConfigHttp
      "http"
      --url="http://localhost:1234/api/"
      --root-certificate-ders=null
      --device-headers={"X-Device": "true"}
      --admin-headers=null
  cli-json := config.to-json --base64 --der-serializer=: unreachable
  expect-equals "http://localhost:1234/api" cli-json["url"]
  expect-not (cli-json.contains "host")
  expect-not (cli-json.contains "port")
  expect-not (cli-json.contains "path")
  expect-not (cli-json.contains "use_tls")
  encoded := config.to-service-json --base64 --der-serializer=: unreachable
  expect-equals
      "http://localhost:1234/api/device/{device-id}/goal"
      encoded["fetch_goal_state_url_template"]
  expect-equals
      "http://localhost:1234/api/artifacts/{organization-id}/images/{id}.{word-size}"
      encoded["fetch_image_url_template"]
  expect-equals
      "http://localhost:1234/api/artifacts/{organization-id}/firmware/{id}"
      encoded["fetch_firmware_url_template"]
  expect-equals
      "http://localhost:1234/api/device/{device-id}/state"
      encoded["report_state_url_template"]
  expect-equals
      "http://localhost:1234/api/device/{device-id}/events"
      encoded["report_event_url_template"]
  expect-equals "true" encoded["headers"]["X-Device"]

test-legacy-configs:
  supabase := ServerConfig.from-json "supabase" {
    "type": "supabase",
    "host": "localhost:54321",
    "anon": "anon",
    "poll_interval": 20_000_000,
    "use_tls": false,
  } --der-deserializer=: unreachable
  expect supabase is ServerConfigSupabase
  expect-equals "http://localhost:54321" (supabase as ServerConfigSupabase).url

  http-config := ServerConfig.from-json "http" {
    "type": "toit-http",
    "host": "localhost",
    "port": 1234,
    "path": "/api/",
    "poll_interval": 20_000_000,
    "use_tls": true,
  } --der-deserializer=: unreachable
  expect http-config is ServerConfigHttp
  expect-equals "https://localhost:1234/api" (http-config as ServerConfigHttp).url
