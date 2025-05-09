// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli show *
import encoding.base64
import encoding.json
import http
import io
import net
import supabase
import supabase.filter show equals

import artemis.cli.config
  show
    CONFIG-ARTEMIS-DEFAULT-KEY
    CONFIG-SERVER-AUTHS-KEY
    ConfigLocalStorage
import artemis.cli.server-config show *
import artemis.cli.utils.supabase show *
import artemis.shared.constants show *

import .utils

AR-SNAPSHOT-HEADER ::= "<snapshots>"

interface UploadClient:
  close
  upload
      --sdk-version/string --service-version/string
      --image-id/string --image-contents/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool

  upload --snapshot-uuid/string cli-snapshot/ByteArray

get-artemis-config --cli/Cli -> ServerConfig:
  result := get-server-from-config --key=CONFIG-ARTEMIS-DEFAULT-KEY --cli=cli
  return result


with-upload-client invocation/Invocation [block]:
  server-config := get-artemis-config --cli=invocation.cli
  if server-config is ServerConfigSupabase:
    with-upload-client-supabase invocation block
  else if server-config is ServerConfigHttp:
    with-upload-client-http (server-config as ServerConfigHttp) --cli=invocation.cli block
  else:
    throw "Unsupported server type"

class UploadClientSupabase implements UploadClient:
  client_/supabase.Client
  cli_/Cli

  constructor .client_ --cli/Cli:
    cli_ = cli

  close:
    client_.close

  upload
      --sdk-version/string --service-version/string
      --image-id/string --image-contents/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool:
    ui := cli_.ui
    client_.ensure-authenticated: | reason/string |
      print "Authentication failure: $reason"
      supabase-ui := SupabaseUi cli_
      client_.auth.sign_in --provider="github" --ui=supabase-ui

    ui.emit --info "Uploading image archive."

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
        ui.emit --error "Image already exists$suffix."
        ui.emit --error "Use --force to overwrite."
        ui.abort

    client_.storage.upload
        --path="service-images/$image-id"
        --content=image-contents

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

    ui.emit --info "Successfully uploaded $service-version into service-images/$image-id."

    ui.emit --info "Uploading snapshots."
    buffer := io.Buffer
    ar-writer := ar.ArWriter buffer
    ar-writer.add AR-SNAPSHOT-HEADER "<snapshots>"
    snapshots.do: | chip-family/string snapshot/ByteArray |
      ar-writer.add chip-family snapshot
    client_.storage.upload
      --path="service-snapshots/$image-id"
      --content=buffer.bytes
    ui.emit --info "Successfully uploaded the snapshot."

  upload --snapshot-uuid/string cli-snapshot/ByteArray:
    client_.ensure-authenticated: it.sign-in --provider="github" --cli=cli_
    client_.storage.upload
      --path="cli-snapshots/$snapshot-uuid"
      --content=cli-snapshot

with-upload-client-supabase invocation/Invocation [block]:
  with-supabase-client invocation: | client/supabase.Client |
    upload-client := UploadClientSupabase client --cli=invocation.cli
    try:
      block.call upload-client
    finally:
      upload-client.close

class UploadClientHttp implements UploadClient:
  client_/http.Client
  server-config_/ServerConfigHttp
  cli_/Cli
  network_/net.Interface

  constructor .server-config_ --cli/Cli:
    cli_ = cli
    network_ = net.open
    client_ = http.Client network_

  close:
    // TODO(florian): we would like to close the http client here.
    network_.close

  upload
      --sdk-version/string --service-version/string
      --image-id/string --image-contents/ByteArray
      --snapshots/Map  // From chip-family to ByteArray.
      --organization-id/string?
      --force/bool:
    // We only upload the image.
    send-request_ COMMAND-UPLOAD-SERVICE-IMAGE_ --contents=image-contents {
      "sdk_version": sdk-version,
      "service_version": service-version,
      "image_id": image-id,
      "organization_id": organization-id,
      "force": force,
    }

  upload --snapshot-uuid/string cli-snapshot/ByteArray:
    throw "UNIMPLEMENTED"

  // TODO(florian): share this code with the cli and the service.
  send-request_ command/int meta-data/Map --contents/ByteArray -> any:
    encoded-meta := json.encode meta-data
    encoded := #[command] + encoded-meta + #[0] + contents

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

with-upload-client-http server-config/ServerConfigHttp --cli/Cli [block]:
  upload-client := UploadClientHttp server-config --cli=cli
  try:
    block.call upload-client
  finally:
    upload-client.close
