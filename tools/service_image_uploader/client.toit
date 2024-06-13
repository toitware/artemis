// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli
import encoding.base64
import encoding.json
import http
import io
import net
import supabase
import supabase.filter show equals

import artemis.cli.config as cli
import artemis.cli.ui as ui
import artemis.cli.config
  show
    CONFIG-ARTEMIS-DEFAULT-KEY
    CONFIG-SERVER-AUTHS-KEY
    ConfigLocalStorage
import artemis.cli.server-config show *
import artemis.shared.constants show *
import uuid

import .utils

AR-SNAPSHOT-HEADER ::= "<snapshots>"

interface UploadClient:
  close
  upload
      --sdk-version/string --service-version/string
      --image-id/string --image-content/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool

  upload --snapshot-uuid/string cli-snapshot/ByteArray

get-artemis-config parsed/cli.Parsed config/cli.Config ui/ui.Ui -> ServerConfig:
  result := get-server-from-config config --key=CONFIG-ARTEMIS-DEFAULT-KEY
  if not result:
    ui.abort "Default server not configured correctly."
  return result


with-upload-client parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  server-config := get-artemis-config parsed config ui
  if server-config is ServerConfigSupabase:
    with-upload-client-supabase parsed config ui block
  else if server-config is ServerConfigHttp:
    with-upload-client-http (server-config as ServerConfigHttp) ui block
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
      --sdk-version/string --service-version/string
      --image-id/string --image-content/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool:
    client_.ensure-authenticated: | reason/string |
      print "Authentication failure: $reason"
      client_.auth.sign_in --provider="github" --ui=ui_

    ui_.info "Uploading image archive."

    // TODO(florian): share constants with the CLI.
    sdk-ids := client_.rest.select "sdks" --filters=[
      equals "version" sdk-version,
    ]
    sdk-id := ?
    if not sdk-ids.is-empty:
      sdk-id = sdk-ids[0]["id"]
    else:
      inserted := client_.rest.insert "sdks" {
        "version": sdk-version,
      }
      sdk-id = inserted["id"]

    service-ids := client_.rest.select "artemis_services" --filters=[
      equals "version" service-version,
    ]
    service-id := ?
    if not service-ids.is-empty:
      service-id = service-ids[0]["id"]
    else:
      inserted := client_.rest.insert "artemis_services" {
        "version": service-version,
      }
      service-id = inserted["id"]

    if not force:
      existing-images := client_.rest.select "service_images" --filters=[
        equals "sdk_id" sdk-id,
        equals "service_id" service-id,
      ]
      if not existing-images.is-empty:
        existing-org := existing-images[0].get "organization_id"
        suffix := existing-org ? " in organization $existing-org" : ""
        ui_.error "Image already exists$suffix."
        ui_.error "Use --force to overwrite."
        ui_.abort

    client_.storage.upload
        --path="service-images/$image-id"
        --content=image-content

    // In theory we should be able to use 'upsert' here, but
    // there are unique constraints on the columns that we
    // are updating, and that makes things a bit more difficult.
    // Given a complete Supabase API (and probably better Postgres
    // knowledge) it should be possible, but just checking for
    // the entry is significantly easier.
    rows := client_.rest.select "service_images" --filters=[
      equals "sdk_id" sdk-id,
      equals "service_id" service-id,
    ]
    if rows.is-empty:
      client_.rest.insert "service_images" {
        "sdk_id": sdk-id,
        "service_id": service-id,
        "image": image-id,
        "organization_id": organization-id,
      }
    else:
      client_.rest.update "service_images" --filters=[
        equals "sdk_id" sdk-id,
        equals "service_id" service-id,
      ] {
        "image": image-id,
        "organization_id": organization-id,
      }

    ui_.info "Successfully uploaded $service-version into service-images/$image-id."

    ui_.info "Uploading snapshots."
    buffer := io.Buffer
    ar-writer := ar.ArWriter buffer
    ar-writer.add AR-SNAPSHOT-HEADER "<snapshots>"
    snapshots.do: | chip-family/string snapshot/ByteArray |
      ar-writer.add chip-family snapshot
    client_.storage.upload
      --path="service-snapshots/$image-id"
      --content=buffer.bytes
    ui_.info "Successfully uploaded the snapshot."

  upload --snapshot-uuid/string cli-snapshot/ByteArray:
    client_.ensure-authenticated: it.sign-in --provider="github" --ui=ui_
    client_.storage.upload
      --path="cli-snapshots/$snapshot-uuid"
      --content=cli-snapshot

with-upload-client-supabase parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  with-supabase-client parsed config ui: | client/supabase.Client |
    upload-client := UploadClientSupabase client --ui=ui
    try:
      block.call upload-client
    finally:
      upload-client.close

class UploadClientHttp implements UploadClient:
  client_/http.Client
  server-config_/ServerConfigHttp
  ui_/ui.Ui
  network_/net.Interface

  constructor .server-config_ --ui/ui.Ui:
    ui_ = ui
    network_ = net.open
    client_ = http.Client network_

  close:
    // TODO(florian): we would like to close the http client here.
    network_.close

  upload
      --sdk-version/string --service-version/string
      --image-id/string --image-content/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool:
    // We only upload the image.
    send-request_ COMMAND-UPLOAD-SERVICE-IMAGE_ --content=image-content {
      "sdk_version": sdk-version,
      "service_version": service-version,
      "image_id": image-id,
      "organization_id": organization-id,
      "force": force,
    }

  upload --snapshot-uuid/string cli-snapshot/ByteArray:
    throw "UNIMPLEMENTED"

  // TODO(florian): share this code with the cli and the service.
  send-request_ command/int meta-data/Map --content/ByteArray -> any:
    encoded-meta := json.encode meta-data
    encoded := #[command] + encoded-meta + #[0] + content

    headers := null
    if server-config_.admin-headers:
      headers = http.Headers
      server-config_.admin-headers.do: | key value |
        headers.add key value

    response := client_.post encoded
        --host=server-config_.host
        --port=server-config_.port
        --path=server-config_.path
        --headers=headers

    if response.status-code != 200 and response.status-code != http.STATUS-IM-A-TEAPOT:
      throw "HTTP error: $response.status-code $response.status-message"

    decoded := json.decode-stream response.body

    if response.status-code == http.STATUS-IM-A-TEAPOT:
      throw "Broker error: $decoded"

    return decoded

with-upload-client-http server-config/ServerConfigHttp ui/ui.Ui [block]:
  upload-client := UploadClientHttp server-config --ui=ui
  try:
    block.call upload-client
  finally:
    upload-client.close
