// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show Cli
import encoding.json
import http
import net
import net.x509
import tls
import uuid show Uuid

import ..broker
import ..stores
import ...device
import ...event
import ...pod-registry
import ....shared.scope show Scope
import ....shared.server-config
import ....shared.utils as utils
import ....shared.constants show *

create-combined-backend-http-toit server-config/ServerConfigHttp -> CombinedBackendHttp:
  id := "toit-http/$server-config.host-$server-config.port"
  return CombinedBackendHttp server-config --id=id

create-combined-backend-http-toit-shared server-config/ServerConfigHttp -> CombinedBackendHttpShared:
  id := "toit-http/$server-config.host-$server-config.port"
  return CombinedBackendHttpShared server-config --id=id

class CombinedBackendHttp implements CombinedBackend:
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

  artifact-store -> ArtifactStore:
    return CombinedArtifactStore_ this

  update-broker -> UpdateBroker:
    return CombinedUpdateBroker_ this

  fleet-store -> FleetStore:
    return CombinedFleetStore_ this

  pod-store -> PodStore:
    return CombinedPodStore_ this

  send-request_ command/int data/any -> any:
    if is-closed: throw "CLOSED"
    encoded/ByteArray := ?
    if command == COMMAND-UPLOAD_:
      path := data["path"]
      contents := data["content"]
      encoded = #[COMMAND-UPLOAD_] + path.to-byte-array + #[0] + contents
    else:
      encoded = #[command] + (json.encode data)

    send-request_ encoded: | response/http.Response |
      body := response.body
      // Teapot status codes are exceptions from our server code.
      // They are handled below.
      if response.status-code != http.STATUS-IM-A-TEAPOT and
          not http.is-success-status-code response.status-code:
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

      if (command == COMMAND-DOWNLOAD_ or command == COMMAND-DOWNLOAD-PRIVATE_)
          and response.status-code != http.STATUS-IM-A-TEAPOT:
        return utils.read-all response.body

      decoded := json.decode-stream response.body
      if response.status-code == http.STATUS-IM-A-TEAPOT:
        throw "Broker error: $decoded"
      return decoded
    unreachable

  send-request_ encoded/ByteArray [block]:
    MAX-ATTEMPTS ::= 3
    MAX-ATTEMPTS.repeat: | attempt/int |
      response := send-request_ encoded
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

  send-request_ encoded/ByteArray -> http.Response:
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

    return client_.post encoded
        --host=server-config_.host
        --port=server-config_.port
        --path=server-config_.path
        --headers=headers

  extra-headers -> Map?:
    return null

  update-goal --device-id/Uuid [block] -> none:
    detailed-devices := get-devices --device-ids=[device-id]
    if detailed-devices.size != 1: throw "Device not found: $device-id"
    detailed-device := detailed-devices[device-id]
    new-goal := block.call detailed-device
    send-request_ COMMAND-UPDATE-GOAL_ {
      "_device_id": "$device-id",
      "_goal": new-goal
    }

  update-goals --device-ids/List --goals/List -> none:
    send-request_ COMMAND-UPDATE-GOALS_ {
      "_device_ids": device-ids.map: "$it",
      "_goals": goals
    }

  get-devices --device-ids/List -> Map:
    response := send-request_ COMMAND-GET-DEVICES_ {
      "_device_ids": device-ids.map: "$it"
    }
    result := {:}
    response.do: | row/Map |
      device-id := Uuid.parse row["device_id"]
      goal := row["goal"]
      state := row["state"]
      result[device-id] = DeviceDetailed --goal=goal --state=state
    return result

  upload-image -> none
      --app-id/Uuid
      --word-size/int
      contents/ByteArray:
    scope := server-config_.scope.to-json
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-assets/$scope/images/$app-id.$word-size",
      "content": contents,
    }

  upload-firmware --firmware-id/string chunks/List -> none:
    scope := server-config_.scope.to-json
    firmware := #[]
    chunks.do: firmware += it
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-assets/$scope/firmware/$firmware-id",
      "content": firmware,
    }

  download-firmware --id/string -> ByteArray:
    scope := server-config_.scope.to-json
    return send-request_ COMMAND-DOWNLOAD_ {
      "path": "/toit-artemis-assets/$scope/firmware/$id",
    }

  notify-created --device-id/Uuid --state/Map -> none:
    send-request_ COMMAND-NOTIFY-BROKER-CREATED_ {
      "_device_id": "$device-id",
      "_state": state,
    }

  get-events -> Map
      --types/List?=null
      --device-ids/List
      --limit/int=10
      --since/Time?=null:
    payload := {
      "_types": types,
      "_device_ids": device-ids.map: "$it",
      "_limit": limit,
    }
    if since: payload["_since"] = since.utc.to-iso8601-string
    response := send-request_ COMMAND-GET-EVENTS_ payload
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

  /** See $PodStore.pod-registry-description-upsert. */
  pod-registry-description-upsert -> int
      --fleet-id/Uuid
      --name/string
      --description/string?:
    scope := server-config_.scope.to-json
    return send-request_ COMMAND-POD-REGISTRY-DESCRIPTION-UPSERT_ {
      "_fleet_id": "$fleet-id",
      "_organization_id": scope,
      "_name": name,
      "_description": description,
    }

  /** See $PodStore.pod-registry-descriptions-delete. */
  pod-registry-descriptions-delete --fleet-id/Uuid --description-ids/List -> none:
    send-request_ COMMAND-POD-REGISTRY-DELETE-DESCRIPTIONS_ {
      "_fleet_id": "$fleet-id",
      "_description_ids": description-ids,
    }

  /** See $PodStore.pod-registry-add. */
  pod-registry-add -> none
      --pod-description-id/int
      --pod-id/Uuid:
    send-request_ COMMAND-POD-REGISTRY-ADD_ {
      "_pod_description_id": pod-description-id,
      "_pod_id": "$pod-id",
    }

  /** See $PodStore.pod-registry-delete. */
  pod-registry-delete --fleet-id/Uuid --pod-ids/List -> none:
    send-request_ COMMAND-POD-REGISTRY-DELETE_ {
      "_fleet_id": "$fleet-id",
      "_pod_ids": pod-ids.map: "$it",
    }

  /** See $PodStore.pod-registry-tag-set. */
  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/Uuid
      --tag/string
      --force/bool=false:
    send-request_ COMMAND-POD-REGISTRY-TAG-SET_ {
      "_pod_description_id": pod-description-id,
      "_pod_id": "$pod-id",
      "_tag": tag,
      "_force": force,
    }

  /** See $PodStore.pod-registry-tag-remove. */
  pod-registry-tag-remove -> none
      --pod-description-id/int
      --tag/string:
    send-request_ COMMAND-POD-REGISTRY-TAG-REMOVE_ {
      "_pod_description_id": pod-description-id,
      "_tag": tag,
    }

  /** See $PodStore.pod-registry-descriptions. */
  pod-registry-descriptions --fleet-id/Uuid -> List:
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS_ {
      "_fleet_id": "$fleet-id",
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(PodStore.pod-registry-descriptions --ids). */
  pod-registry-descriptions --ids/List -> List:
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-IDS_ {
      "_description_ids": ids,
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(PodStore.pod-registry-descriptions --fleet-id --names --create-if-absent). */
  pod-registry-descriptions -> List
      --fleet-id/Uuid
      --names/List
      --create-if-absent/bool:
    scope := server-config_.scope.to-json
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-NAMES_ {
      "_fleet_id": "$fleet-id",
      "_organization_id": scope,
      "_names": names,
      "_create_if_absent": create-if-absent,
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(PodStore.pod-registry-pods --pod-description-id). */
  pod-registry-pods --pod-description-id/int -> List:
    response := send-request_ COMMAND-POD-REGISTRY-PODS_ {
      "_pod_description_id": pod-description-id,
      "_limit": 1000,
      "_offset": 0,
    }
    return response.map: PodRegistryEntry.from-map it

  /** See $(PodStore.pod-registry-pods --fleet-id --pod-ids). */
  pod-registry-pods --fleet-id/Uuid --pod-ids/List -> List:
    response := send-request_ COMMAND-POD-REGISTRY-PODS-BY-IDS_ {
      "_fleet_id": "$fleet-id",
      "_pod_ids": (pod-ids.map: "$it"),
    }
    return response.map: PodRegistryEntry.from-map it

  /** See $PodStore.pod-registry-pod-ids. */
  pod-registry-pod-ids --fleet-id/Uuid --references/List -> Map:
    response := send-request_ COMMAND-POD-REGISTRY-POD-IDS-BY-REFERENCE_ {
      "_fleet_id": "$fleet-id",
      "_references": references.map: | reference/PodReference |
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

  /** See $PodStore.pod-registry-upload-pod-part. */
  pod-registry-upload-pod-part -> none
      --part-id/string
      contents/ByteArray:
    scope := server-config_.scope.to-json
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-pods/$scope/part/$part-id",
      "content": contents,
    }

  /** See $PodStore.pod-registry-download-pod-part. */
  pod-registry-download-pod-part part-id/string -> ByteArray:
    scope := server-config_.scope.to-json
    return send-request_ COMMAND-DOWNLOAD-PRIVATE_ {
      "path": "/toit-artemis-pods/$scope/part/$part-id",
    }

  /** See $PodStore.pod-registry-upload-pod-manifest. */
  pod-registry-upload-pod-manifest -> none
      --pod-id/Uuid
      contents/ByteArray:
    scope := server-config_.scope.to-json
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-pods/$scope/manifest/$pod-id",
      "content": contents,
    }

  /** See $PodStore.pod-registry-download-pod-manifest. */
  pod-registry-download-pod-manifest --pod-id/Uuid -> ByteArray:
    scope := server-config_.scope.to-json
    return send-request_ COMMAND-DOWNLOAD-PRIVATE_ {
      "path": "/toit-artemis-pods/$scope/manifest/$pod-id",
    }

/**
A $CombinedBackendHttp specialisation for shared-tenancy HTTP deployments.

In a shared-tenancy deployment the broker also owns the auth-side device
  record; this override sends the configured scope (organization-id) so the
  broker can populate that record alongside the broker-side state.
*/
class CombinedBackendHttpShared extends CombinedBackendHttp:
  constructor server-config/ServerConfigHttp --id/string:
    super server-config --id=id

  notify-created --device-id/Uuid --state/Map -> none:
    send-request_ COMMAND-NOTIFY-BROKER-CREATED_ {
      "_device_id": "$device-id",
      "_organization_id": server-config_.scope.to-json,
      "_state": state,
    }

class CombinedArtifactStore_ implements ArtifactStore:
  backend_/CombinedBackendHttp

  constructor .backend_:

  upload-image --app-id/Uuid --word-size/int contents/ByteArray -> none:
    backend_.upload-image contents --app-id=app-id --word-size=word-size

  upload-firmware --firmware-id/string chunks/List -> none:
    backend_.upload-firmware chunks --firmware-id=firmware-id

  download-firmware --id/string -> ByteArray:
    return backend_.download-firmware --id=id

class CombinedFleetStore_ implements FleetStore:
  backend_/CombinedBackendHttp

  constructor .backend_:

  notify-created --device-id/Uuid --state/Map -> none:
    backend_.notify-created --device-id=device-id --state=state

  get-events -> Map
      --types/List?=null
      --device-ids/List
      --limit/int=10
      --since/Time?=null:
    return backend_.get-events
        --types=types
        --device-ids=device-ids
        --limit=limit
        --since=since

  get-devices --device-ids/List -> Map:
    return backend_.get-devices --device-ids=device-ids

class CombinedUpdateBroker_ implements UpdateBroker:
  backend_/CombinedBackendHttp

  constructor .backend_:

  update-goal --device-id/Uuid [block] -> none:
    backend_.update-goal --device-id=device-id block

  update-goals --device-ids/List --goals/List -> none:
    backend_.update-goals --device-ids=device-ids --goals=goals

class CombinedPodStore_ implements PodStore:
  backend_/CombinedBackendHttp

  constructor .backend_:

  pod-registry-description-upsert -> int
      --fleet-id/Uuid
      --name/string
      --description/string?:
    return backend_.pod-registry-description-upsert
        --fleet-id=fleet-id
        --name=name
        --description=description

  pod-registry-descriptions-delete --fleet-id/Uuid --description-ids/List -> none:
    backend_.pod-registry-descriptions-delete
        --fleet-id=fleet-id
        --description-ids=description-ids

  pod-registry-add --pod-description-id/int --pod-id/Uuid -> none:
    backend_.pod-registry-add
        --pod-description-id=pod-description-id
        --pod-id=pod-id

  pod-registry-delete --fleet-id/Uuid --pod-ids/List -> none:
    backend_.pod-registry-delete --fleet-id=fleet-id --pod-ids=pod-ids

  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/Uuid
      --tag/string
      --force/bool=false:
    backend_.pod-registry-tag-set
        --pod-description-id=pod-description-id
        --pod-id=pod-id
        --tag=tag
        --force=force

  pod-registry-tag-remove --pod-description-id/int --tag/string -> none:
    backend_.pod-registry-tag-remove
        --pod-description-id=pod-description-id
        --tag=tag

  pod-registry-descriptions --fleet-id/Uuid -> List:
    return backend_.pod-registry-descriptions --fleet-id=fleet-id

  pod-registry-descriptions --ids/List -> List:
    return backend_.pod-registry-descriptions --ids=ids

  pod-registry-descriptions -> List
      --fleet-id/Uuid
      --names/List
      --create-if-absent/bool:
    return backend_.pod-registry-descriptions
        --fleet-id=fleet-id
        --names=names
        --create-if-absent=create-if-absent

  pod-registry-pods --pod-description-id/int -> List:
    return backend_.pod-registry-pods --pod-description-id=pod-description-id

  pod-registry-pods --fleet-id/Uuid --pod-ids/List -> List:
    return backend_.pod-registry-pods --fleet-id=fleet-id --pod-ids=pod-ids

  pod-registry-pod-ids --fleet-id/Uuid --references/List -> Map:
    return backend_.pod-registry-pod-ids
        --fleet-id=fleet-id
        --references=references

  pod-registry-upload-pod-part --part-id/string contents/ByteArray -> none:
    backend_.pod-registry-upload-pod-part contents --part-id=part-id

  pod-registry-download-pod-part part-id/string -> ByteArray:
    return backend_.pod-registry-download-pod-part part-id

  pod-registry-upload-pod-manifest --pod-id/Uuid contents/ByteArray -> none:
    backend_.pod-registry-upload-pod-manifest contents --pod-id=pod-id

  pod-registry-download-pod-manifest --pod-id/Uuid -> ByteArray:
    return backend_.pod-registry-download-pod-manifest --pod-id=pod-id
