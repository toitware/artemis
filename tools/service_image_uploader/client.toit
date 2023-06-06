// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import encoding.base64
import encoding.json
import http
import net
import supabase

import artemis.cli.config as cli
import artemis.cli.ui as ui
import artemis.cli.config
  show
    CONFIG_ARTEMIS_DEFAULT_KEY
    CONFIG_SERVER_AUTHS_KEY
    ConfigLocalStorage
import artemis.cli.server_config show *
import artemis.shared.constants show *
import uuid

import .utils

interface UploadClient:
  close
  upload
      --sdk_version/string --service_version/string
      --image_id/string --image_content/ByteArray
      --snapshot/ByteArray
      --organization_id/string?
      --force/bool

  upload --snapshot_uuid/string cli_snapshot/ByteArray

get_artemis_config parsed/cli.Parsed config/cli.Config -> ServerConfig:
  return get_server_from_config config CONFIG_ARTEMIS_DEFAULT_KEY

with_upload_client parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  server_config := get_artemis_config parsed config
  if server_config is ServerConfigSupabase:
    with_upload_client_supabase parsed config ui block
  else if server_config is ServerConfigHttp:
    with_upload_client_http (server_config as ServerConfigHttp) ui block
  else:
    throw "Unsupported server type"

class UploadClientSupabase implements UploadClient:
  client_/supabase.Client
  ui_/ui.Ui

  constructor .client_ --ui/ui.Ui:
    ui_ = ui

  close:
    client_.close

  upload
      --sdk_version/string --service_version/string
      --image_id/string --image_content/ByteArray
      --snapshot/ByteArray
      --organization_id/string?
      --force/bool:
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

    if not force:
      existing_images := client_.rest.select "service_images" --filters=[
        "sdk_id=eq.$sdk_id",
        "service_id=eq.$service_id",
      ]
      if not existing_images.is_empty:
        suffix := ""
        if existing_images[0].get "organization_id":
          suffix = " in organization $organization_id"
        ui_.error "Image already exists$suffix."
        ui_.error "Use --force to overwrite."
        ui_.abort

    client_.storage.upload
        --path="service-images/$image_id"
        --content=image_content

    // In theory we should be able to use 'upsert' here, but
    // there are unique constraints on the columns that we
    // are updating, and that makes things a bit more difficult.
    // Given a complete Supabase API (and probably better Postgres
    // knowledge) it should be possible, but just checking for
    // the entry is significantly easier.
    rows := client_.rest.select "service_images" --filters=[
      "sdk_id=eq.$sdk_id",
      "service_id=eq.$service_id",
    ]
    if rows.is_empty:
      client_.rest.insert "service_images" {
        "sdk_id": sdk_id,
        "service_id": service_id,
        "image": image_id,
        "organization_id": organization_id,
      }
    else:
      client_.rest.update "service_images" --filters=[
        "sdk_id=eq.$sdk_id",
        "service_id=eq.$service_id",
      ] {
        "image": image_id,
        "organization_id": organization_id,
      }

    ui_.info "Successfully uploaded $service_version into service-images/$image_id."

    ui_.info "Uploading snapshot."
    client_.storage.upload
      --path="service-snapshots/$image_id"
      --content=snapshot
    ui_.info "Successfully uploaded the snapshot."

  upload --snapshot_uuid/string cli_snapshot/ByteArray:
    client_.ensure_authenticated: it.sign_in --provider="github" --ui=ui_
    client_.storage.upload
      --path="cli-snapshots/$snapshot_uuid"
      --content=cli_snapshot

with_upload_client_supabase parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  with_supabase_client parsed config: | client/supabase.Client |
    upload_client := UploadClientSupabase client --ui=ui
    try:
      block.call upload_client
    finally:
      upload_client.close

class UploadClientHttp implements UploadClient:
  client_/http.Client
  server_config_/ServerConfigHttp
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
      --snapshot/ByteArray
      --organization_id/string?
      --force/bool:
    // We only upload the image.
    send_request_ COMMAND_UPLOAD_SERVICE_IMAGE_ {
      "sdk_version": sdk_version,
      "service_version": service_version,
      "image_id": image_id,
      "image_content": base64.encode image_content,
      "organization_id": organization_id,
      "force": force,
    }

  upload --snapshot_uuid/string cli_snapshot/ByteArray:
    throw "UNIMPLEMENTED"

  // TODO(florian): share this code with the cli and the service.
  send_request_ command/int data/Map -> any:
    encoded := #[command] + (json.encode data)
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200 and response.status_code != http.STATUS_IM_A_TEAPOT:
      throw "HTTP error: $response.status_code $response.status_message"

    decoded := json.decode_stream response.body

    if response.status_code == http.STATUS_IM_A_TEAPOT:
      throw "Broker error: $decoded"

    return decoded

with_upload_client_http server_config/ServerConfigHttp ui/ui.Ui [block]:
  upload_client := UploadClientHttp server_config --ui=ui
  try:
    block.call upload_client
  finally:
    upload_client.close
