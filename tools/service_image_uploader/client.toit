// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import encoding.base64
import encoding.ubjson
import http
import net
import supabase

import artemis.cli.config as cli
import artemis.cli.ui as ui
import artemis.cli.config show
    CONFIG_ARTEMIS_DEFAULT_KEY
    CONFIG_SERVER_AUTHS_KEY
    ConfigLocalStorage
import artemis.cli.server_config show *
import uuid

import .utils

interface UploadClient:
  close
  upload
      --sdk_version/string --service_version/string
      --image_id/string --image_content/ByteArray
      --snapshot/ByteArray

with_upload_client parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  if server_config is ServerConfigSupabase:
    with_upload_client_supabase parsed config ui block
  else if server_config is ServerConfigHttpToit:
    with_upload_client_http (server_config as ServerConfigHttpToit) ui block
  else:
    throw "Unsupported server type"

class UploadClientSupabase implements UploadClient:
  client_/supabase.Client
  ui_/ui.Ui

  constructor .client_ --ui/ui.Ui:
    ui_ = ui

  close: client_.close

  upload
      --sdk_version/string --service_version/string
      --image_id/string --image_content/ByteArray
      --snapshot/ByteArray:
    client_.ensure_authenticated: it.sign_in --provider="github" --ui=ui_

    ui_.info "Uploading image archive."

    // TODO(florian): share constants with the CLI.
    sdk_ids := client_.rest.select "sdks" --filters=[
      "version=eq.$sdk_version",
    ]
    sdk_id := ?
    if not sdk_ids.is_empty:
      sdk_id = sdk_ids[0]["id"]
    else:
      inserted := client_.rest.insert "sdks" {
        "version": sdk_version,
      }
      sdk_id = inserted["id"]

    service_ids := client_.rest.select "artemis_services" --filters=[
      "version=eq.$service_version",
    ]
    service_id := ?
    if not service_ids.is_empty:
      service_id = service_ids[0]["id"]
    else:
      inserted := client_.rest.insert "artemis_services" {
        "version": service_version,
      }
      service_id = inserted["id"]

    client_.storage.upload
        --path="service-images/$image_id"
        --content=snapshot

    client_.rest.insert "service_images" {
      "sdk_id": sdk_id,
      "service_id": service_id,
      "image": image_id,
    }

    ui_.info "Successfully uploaded $service_version into service-images/$image_id."

    ui_.info "Uploading snapshot."
    client_.storage.upload
      --path="service-snapshots/$image_id"
      --content=snapshot
    ui_.info "Successfully uploaded the snapshot."

with_upload_client_supabase parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  with_supabase_client parsed config: | client/supabase.Client |
    upload_client := UploadClientSupabase client --ui=ui
    try:
      block.call upload_client
    finally:
      upload_client.close

class UploadClientHttp implements UploadClient:
  client_/http.Client
  server_config_/ServerConfigHttpToit
  ui_/ui.Ui
  network_/net.Interface

  constructor .server_config_ --ui/ui.Ui:
    ui_ = ui
    network_ = net.open
    client_ = http.Client network_

  close:
    // TODO(florian): we would like to close the http client here.
    network_.close

  upload
      --sdk_version/string --service_version/string
      --image_id/string --image_content/ByteArray
      --snapshot/ByteArray:
    // We only upload the image.
    send_request_ "upload-service-image" {
      "sdk_version": sdk_version,
      "service_version": service_version,
      "image_id": image_id,
      "image_content": base64.encode image_content,
    }

  // TODO(florian): share this code with the cli and the service.
  send_request_ command/string data/Map -> any:
    payload := {
      "command": command,
      "data": data,
    }
    encoded := ubjson.encode payload
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk
    decoded := ubjson.decode encoded_response
    if not (decoded.get "success"):
      throw "Broker error: $(decoded.get "error")"

    return decoded["data"]

with_upload_client_http server_config/ServerConfigHttpToit ui/ui.Ui [block]:
  upload_client := UploadClientHttp server_config --ui=ui
  try:
    block.call upload_client
  finally:
    upload_client.close
