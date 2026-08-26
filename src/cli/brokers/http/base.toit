// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show Cli
import encoding.json
import http
import net
import net.x509
import tls
import uuid show Uuid

import ..server
import ..stores
import ...device
import ...event
import ...pod-registry
import ....shared.scope show Scope
import ....shared.server-config
import ....shared.utils as utils

ARTIFACT-STORE-PATH_ ::= "/artifact-store"
UPDATE-BROKER-PATH_ ::= "/update-broker"
BROKER-STATE-READER-PATH_ ::= "/broker-state-reader"
BROKER-EVENT-READER-PATH_ ::= "/broker-event-reader"
POD-STORE-PATH_ ::= "/pod-store"

create-server-http-toit server-config/ServerConfigHttp -> ServerHttp:
  id := "toit-http/$server-config.host-$server-config.port"
  return ServerHttp server-config --id=id

class ServerHttp implements Server:
  network_/net.Interface? := ?
  id/string
  server-config_/ServerConfigHttp
  client_/http.Client? := null

  constructor .server-config_ --.id:
    server-config_.install-root-certificates
    network_ = net.open
    add-finalizer this:: close

  close:
    if not network_: return
    remove-finalizer this
    if client_:
      client_.close
      client_ = null
    network_.close
    network_ = null

  is-closed -> bool:
    return network_ == null

  ensure-authenticated [block]:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign-up --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign-in --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign-in --provider/string --cli/Cli --open-browser/bool:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  update --email/string? --password/string?:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  logout:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  scope -> Scope:
    return server-config_.scope

  send-request method/string path/string data/any=null -> any
      --query-parameters/Map?=null
      --binary-request/bool=false
      --binary-response/bool=false:
    if is-closed: throw "CLOSED"
    encoded/ByteArray? := null
    if data != null:
      encoded = binary-request ? data : json.encode data

    content-type := binary-request ? "application/octet-stream" : "application/json"
    send-encoded-request_ method path encoded
        --query-parameters=query-parameters
        --content-type=content-type:
      | response/http.Response |
      body := response.body
      if not http.is-success-status-code response.status-code:
        body-bytes := utils.read-all body
        message := ""
        exception := catch:
          decoded := json.decode body-bytes
          message = decoded.get "msg" or
              decoded.get "message" or
              decoded.get "error_description" or
              decoded.get "error" or
              body-bytes.to-string-non-throwing
        if exception:
          message = body-bytes.to-string-non-throwing
        message = message.trim
        if message != "":
          message = " - $message"
        throw "HTTP error: $response.status-code - $response.status-message$message"

      if binary-response:
        return utils.read-all response.body

      decoded := json.decode-stream response.body
      return decoded
    unreachable

  send-encoded-request_ method/string path/string encoded/ByteArray?
      --query-parameters/Map?=null
      --content-type/string
      [block]:
    MAX-ATTEMPTS ::= 3
    MAX-ATTEMPTS.repeat: | attempt/int |
      response := send-encoded-request_ method path encoded
          --query-parameters=query-parameters
          --content-type=content-type
      // Cloudflare frequently rejects our requests with a 502, 520 or 546.
      // Just try again.
      status-code := response.status-code
      if (status-code == http.STATUS-BAD-GATEWAY or status-code == 520 or status-code == 546)
          and attempt != MAX-ATTEMPTS - 1:
        // Try again with a different client.
        client_.close
        client_ = null
      else:
        block.call response
        return

  send-encoded-request_ method/string path/string encoded/ByteArray?
      --query-parameters/Map?=null
      --content-type/string
      -> http.Response:
    if not client_:
      if server-config_.use-tls or server-config_.root-certificate-ders:
        client_ = http.Client.tls network_
      else:
        client_ = http.Client network_

    headers := null
    if server-config_.admin-headers:
      headers = http.Headers
      server-config_.admin-headers.do: | key value |
        headers.add key value

    extra := extra-headers
    if extra:
      if not headers: headers = http.Headers
      extra.do: | key value |
        headers.add key value
    if encoded:
      if not headers: headers = http.Headers
      headers.set "Content-Type" content-type

    base-path := server-config_.path
    if base-path.ends-with "/": base-path = base-path[..base-path.size - 1]
    if not path.starts-with "/": path = "/$path"
    return client_.request method encoded
        --host=server-config_.host
        --port=server-config_.port
        --path="$base-path$path"
        --query-parameters=query-parameters
        --headers=headers

  extra-headers -> Map?:
    return null
class ArtifactStoreHttp implements ArtifactStore:
  server/Server

  constructor .server:

  upload-image --app-id/Uuid --word-size/int contents/ByteArray -> none:
    scope := server.scope.to-json
    server.send-request http.PUT "$ARTIFACT-STORE-PATH_/images" contents
        --query-parameters={"scope": scope, "app_id": "$app-id", "word_size": "$word-size"}
        --binary-request

  upload-firmware --firmware-id/string chunks/List -> none:
    scope := server.scope.to-json
    firmware := #[]
    chunks.do: firmware += it
    server.send-request http.PUT "$ARTIFACT-STORE-PATH_/firmware" firmware
        --query-parameters={"scope": scope, "id": firmware-id}
        --binary-request

  download-firmware --id/string -> ByteArray:
    scope := server.scope.to-json
    return server.send-request http.GET "$ARTIFACT-STORE-PATH_/firmware"
        --query-parameters={"scope": scope, "id": id}
        --binary-response

class BrokerStateReaderHttp implements BrokerStateReader:
  server/Server

  constructor .server:

  get-devices --device-ids/List -> Map:
    response := server.send-request http.POST "$BROKER-STATE-READER-PATH_/devices/query" {
      "device_ids": device-ids.map: "$it"
    }
    result := {:}
    response.do: | row/Map |
      device-id := Uuid.parse row["device_id"]
      goal := row["goal"]
      state := row["state"]
      result[device-id] = DeviceDetailed --goal=goal --state=state
    return result

class BrokerEventReaderHttp implements BrokerEventReader:
  server/Server

  constructor .server:

  get-events -> Map
      --types/List?=null
      --device-ids/List
      --limit/int=10
      --since/Time?=null:
    payload := {
      "types": types,
      "device_ids": device-ids.map: "$it",
      "limit": limit,
    }
    if since: payload["since"] = since.utc.to-iso8601-string
    response := server.send-request http.POST "$BROKER-EVENT-READER-PATH_/events/query" payload
    result := {:}
    current-list/List? := null
    current-id/Uuid? := null
    response.do: | row/Map |
      device-id := Uuid.parse row["device_id"]
      event-type := row["type"]
      data := row["data"]
      timestamp := row["ts"]
      time := Time.parse timestamp
      if device-id != current-id:
        current-id = device-id
        current-list = result.get device-id --init=:[]
      current-list.add (Event event-type time data)
    return result

class UpdateBrokerHttp implements UpdateBroker:
  server/Server
  state-reader_/BrokerStateReader

  constructor .server:
    state-reader_ = BrokerStateReaderHttp server

  update-goal --device-id/Uuid [block] -> none:
    detailed-devices := state-reader_.get-devices --device-ids=[device-id]
    if detailed-devices.size != 1: throw "Device not found: $device-id"
    detailed-device := detailed-devices[device-id]
    new-goal := block.call detailed-device
    server.send-request http.PUT "$UPDATE-BROKER-PATH_/goal" {
      "device_id": "$device-id",
      "goal": new-goal
    }

  update-goals --device-ids/List --goals/List -> none:
    server.send-request http.PUT "$UPDATE-BROKER-PATH_/goals" {
      "device_ids": device-ids.map: "$it",
      "goals": goals
    }

  notify-created --device-id/Uuid --state/Map -> none:
    server.send-request http.POST "$UPDATE-BROKER-PATH_/devices" {
      "device_id": "$device-id",
      "organization_id": server.scope.to-json,
      "state": state,
    }

class PodStoreHttp implements PodStore:
  server/Server

  constructor .server:

  pod-registry-description-upsert -> int
      --fleet-id/Uuid
      --name/string
      --description/string?:
    scope := server.scope.to-json
    return server.send-request http.PUT "$POD-STORE-PATH_/descriptions" {
      "fleet_id": "$fleet-id",
      "organization_id": scope,
      "name": name,
      "description": description,
    }

  pod-registry-descriptions-delete --fleet-id/Uuid --description-ids/List -> none:
    server.send-request http.DELETE "$POD-STORE-PATH_/descriptions" {
      "fleet_id": "$fleet-id",
      "description_ids": description-ids,
    }

  pod-registry-add --pod-description-id/int --pod-id/Uuid -> none:
    server.send-request http.POST "$POD-STORE-PATH_/pods" {
      "pod_description_id": pod-description-id,
      "pod_id": "$pod-id",
    }

  pod-registry-delete --fleet-id/Uuid --pod-ids/List -> none:
    server.send-request http.DELETE "$POD-STORE-PATH_/pods" {
      "fleet_id": "$fleet-id",
      "pod_ids": pod-ids.map: "$it",
    }

  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/Uuid
      --tag/string
      --force/bool=false:
    server.send-request http.PUT "$POD-STORE-PATH_/tags" {
      "pod_description_id": pod-description-id,
      "pod_id": "$pod-id",
      "tag": tag,
      "force": force,
    }

  pod-registry-tag-remove --pod-description-id/int --tag/string -> none:
    server.send-request http.DELETE "$POD-STORE-PATH_/tags" {
      "pod_description_id": pod-description-id,
      "tag": tag,
    }

  pod-registry-descriptions --fleet-id/Uuid -> List:
    response := server.send-request http.POST "$POD-STORE-PATH_/descriptions/query" {
      "query": "fleet",
      "fleet_id": "$fleet-id",
    }
    return response.map: PodRegistryDescription.from-map it

  pod-registry-descriptions --ids/List -> List:
    response := server.send-request http.POST "$POD-STORE-PATH_/descriptions/query" {
      "query": "ids",
      "description_ids": ids,
    }
    return response.map: PodRegistryDescription.from-map it

  pod-registry-descriptions -> List
      --fleet-id/Uuid
      --names/List
      --create-if-absent/bool:
    scope := server.scope.to-json
    response := server.send-request http.POST "$POD-STORE-PATH_/descriptions/query" {
      "query": "names",
      "fleet_id": "$fleet-id",
      "organization_id": scope,
      "names": names,
      "create_if_absent": create-if-absent,
    }
    return response.map: PodRegistryDescription.from-map it

  pod-registry-pods --pod-description-id/int -> List:
    response := server.send-request http.POST "$POD-STORE-PATH_/pods/query" {
      "query": "description",
      "pod_description_id": pod-description-id,
      "limit": 1000,
      "offset": 0,
    }
    return response.map: PodRegistryEntry.from-map it

  pod-registry-pods --fleet-id/Uuid --pod-ids/List -> List:
    response := server.send-request http.POST "$POD-STORE-PATH_/pods/query" {
      "query": "ids",
      "fleet_id": "$fleet-id",
      "pod_ids": pod-ids.map: "$it",
    }
    return response.map: PodRegistryEntry.from-map it

  pod-registry-pod-ids --fleet-id/Uuid --references/List -> Map:
    response := server.send-request http.POST "$POD-STORE-PATH_/references/resolve" {
      "fleet_id": "$fleet-id",
      "references": references.map: | reference/PodReference |
        ref := {
          "name": reference.name,
        }
        if reference.tag: ref["tag"] = reference.tag
        if reference.revision: ref["revision"] = reference.revision
        ref,
    }
    result := {:}
    response.do: | it/Map |
      pod-id := Uuid.parse it["pod_id"]
      reference := PodReference
          --name=it["name"]
          --tag=it.get "tag"
          --revision=it.get "revision"
      result[reference] = pod-id
    return result

  pod-registry-upload-pod-part --part-id/string contents/ByteArray -> none:
    scope := server.scope.to-json
    server.send-request http.PUT "$POD-STORE-PATH_/parts" contents
        --query-parameters={"scope": scope, "id": part-id}
        --binary-request

  pod-registry-download-pod-part part-id/string -> ByteArray:
    scope := server.scope.to-json
    return server.send-request http.GET "$POD-STORE-PATH_/parts"
        --query-parameters={"scope": scope, "id": part-id}
        --binary-response

  pod-registry-upload-pod-manifest --pod-id/Uuid contents/ByteArray -> none:
    scope := server.scope.to-json
    server.send-request http.PUT "$POD-STORE-PATH_/manifests" contents
        --query-parameters={"scope": scope, "id": "$pod-id"}
        --binary-request

  pod-registry-download-pod-manifest --pod-id/Uuid -> ByteArray:
    scope := server.scope.to-json
    return server.send-request http.GET "$POD-STORE-PATH_/manifests"
        --query-parameters={"scope": scope, "id": "$pod-id"}
        --binary-response
