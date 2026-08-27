// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.shared.server-config show
    ServerConfig
    ServerConfigHttp
    ServerConfigHttpTemplates
    ServerConfigSupabase
import expect show *

main:
  test-supabase-templates
  test-http-templates

test-supabase-templates:
  config := ServerConfigSupabase
      "supabase"
      --host="localhost:54321"
      --anon="anon"
      --no-use-tls
  encoded := config.to-service-json --base64 --der-serializer=: unreachable
  expect-equals "http-templates" encoded["type"]
  expect-equals
      "http://localhost:54321/functions/v1/device/{device-id}/{operation}"
      encoded["broker_url_template"]
  expect-equals
      "http://localhost:54321/storage/v1/object/public/toit-artemis-assets/{path}"
      encoded["artifact_url_template"]

  decoded := ServerConfig.from-json
      "supabase"
      encoded
      --der-deserializer=: unreachable
  expect decoded is ServerConfigHttpTemplates

test-http-templates:
  config := ServerConfigHttp
      "http"
      --host="localhost"
      --port=1234
      --path="/api/"
      --root-certificate-ders=null
      --device-headers={"X-Device": "true"}
      --admin-headers=null
  encoded := config.to-service-json --base64 --der-serializer=: unreachable
  expect-equals
      "http://localhost:1234/api/device/{device-id}/{operation}"
      encoded["broker_url_template"]
  expect-equals
      "http://localhost:1234/api/artifacts/{path}"
      encoded["artifact_url_template"]
  expect-equals "true" encoded["headers"]["X-Device"]
