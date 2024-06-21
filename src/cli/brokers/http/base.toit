// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import encoding.json
import http
import net
import net.x509
import tls
import uuid

import ..broker
import ...device
import ...event
import ...pod-registry
import ...ui
import ....shared.server-config
import ....shared.utils as utils
import ....shared.constants show *

create-broker-cli-http-toit server-config/ServerConfigHttp -> BrokerCliHttp:
  id := "toit-http/$server-config.host-$server-config.port"
  return BrokerCliHttp server-config --id=id

class BrokerCliHttp implements BrokerCli:
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

  sign-in --provider/string --ui/Ui --open-browser/bool:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  update --email/string? --password/string?:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  logout:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  send-request_ command/int data/any -> any:
    if is-closed: throw "CLOSED"
    encoded/ByteArray := ?
    if command == COMMAND-UPLOAD_:
      path := data["path"]
      content := data["content"]
      encoded = #[COMMAND-UPLOAD_] + path.to-byte-array + #[0] + content
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
      // Cloudflare frequently rejects our requests with a 502.
      // Just try again.
      if response.status-code == http.STATUS-BAD-GATEWAY and attempt != MAX-ATTEMPTS - 1:
        // Try again with a different client.
        client_.close
        client_ = null
      else:
        block.call response
        return

  send-request_ encoded/ByteArray -> http.Response:
    if not client_:
      if server-config_.root-certificate-names:
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

  update-goal --device-id/uuid.Uuid [block] -> none:
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
      device-id := uuid.parse row["device_id"]
      goal := row["goal"]
      state := row["state"]
      result[device-id] = DeviceDetailed --goal=goal --state=state
    return result

  upload-image -> none
      --organization-id/uuid.Uuid
      --app-id/uuid.Uuid
      --word-size/int
      content/ByteArray:
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-assets/$organization-id/images/$app-id.$word-size",
      "content": content,
    }

  upload-firmware --organization-id/uuid.Uuid --firmware-id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-assets/$organization-id/firmware/$firmware-id",
      "content": firmware,
    }

  download-firmware --organization-id/uuid.Uuid --id/string -> ByteArray:
    return send-request_ COMMAND-DOWNLOAD_ {
      "path": "/toit-artemis-assets/$organization-id/firmware/$id",
    }

  notify-created --device-id/uuid.Uuid --state/Map -> none:
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
    current-id/uuid.Uuid? := null
    response.do: | row/Map |
      device-id := uuid.parse row["device_id"]
      event-type := row["type"]
      data := row["data"]
      timestamp := row["ts"]
      time := Time.parse timestamp
      if device-id != current-id:
        current-id = device-id
        current-list = result.get device-id --init=:[]
      current-list.add (Event event-type time data)
    return result

  /** See $BrokerCli.pod-registry-description-upsert. */
  pod-registry-description-upsert -> int
      --fleet-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --name/string
      --description/string?:
    return send-request_ COMMAND-POD-REGISTRY-DESCRIPTION-UPSERT_ {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_name": name,
      "_description": description,
    }

  /** See $BrokerCli.pod-registry-descriptions-delete. */
  pod-registry-descriptions-delete --fleet-id/uuid.Uuid --description-ids/List -> none:
    send-request_ COMMAND-POD-REGISTRY-DELETE-DESCRIPTIONS_ {
      "_fleet_id": "$fleet-id",
      "_description_ids": description-ids,
    }

  /** See $BrokerCli.pod-registry-add. */
  pod-registry-add -> none
      --pod-description-id/int
      --pod-id/uuid.Uuid:
    send-request_ COMMAND-POD-REGISTRY-ADD_ {
      "_pod_description_id": pod-description-id,
      "_pod_id": "$pod-id",
    }

  /** See $BrokerCli.pod-registry-delete. */
  pod-registry-delete --fleet-id/uuid.Uuid --pod-ids/List -> none:
    send-request_ COMMAND-POD-REGISTRY-DELETE_ {
      "_fleet_id": "$fleet-id",
      "_pod_ids": pod-ids.map: "$it",
    }

  /** See $BrokerCli.pod-registry-tag-set. */
  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/uuid.Uuid
      --tag/string
      --force/bool=false:
    send-request_ COMMAND-POD-REGISTRY-TAG-SET_ {
      "_pod_description_id": pod-description-id,
      "_pod_id": "$pod-id",
      "_tag": tag,
      "_force": force,
    }

  /** See $BrokerCli.pod-registry-tag-remove. */
  pod-registry-tag-remove -> none
      --pod-description-id/int
      --tag/string:
    send-request_ COMMAND-POD-REGISTRY-TAG-REMOVE_ {
      "_pod_description_id": pod-description-id,
      "_tag": tag,
    }

  /** See $BrokerCli.pod-registry-descriptions. */
  pod-registry-descriptions --fleet-id/uuid.Uuid -> List:
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS_ {
      "_fleet_id": "$fleet-id",
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(BrokerCli.pod-registry-descriptions --ids). */
  pod-registry-descriptions --ids/List -> List:
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-IDS_ {
      "_description_ids": ids,
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(BrokerCli.pod-registry-descriptions --fleet-id --organization-id --names --create-if-absent). */
  pod-registry-descriptions -> List
      --fleet-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --names/List
      --create-if-absent/bool:
    response := send-request_ COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-NAMES_ {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_names": names,
      "_create_if_absent": create-if-absent,
    }
    return response.map: PodRegistryDescription.from-map it

  /** See $(BrokerCli.pod-registry-pods --pod-description-id). */
  pod-registry-pods --pod-description-id/int -> List:
    response := send-request_ COMMAND-POD-REGISTRY-PODS_ {
      "_pod_description_id": pod-description-id,
      "_limit": 1000,
      "_offset": 0,
    }
    return response.map: PodRegistryEntry.from-map it

  /** See $(BrokerCli.pod-registry-pods --fleet-id --pod-ids). */
  pod-registry-pods --fleet-id/uuid.Uuid --pod-ids/List -> List:
    response := send-request_ COMMAND-POD-REGISTRY-PODS-BY-IDS_ {
      "_fleet_id": "$fleet-id",
      "_pod_ids": (pod-ids.map: "$it"),
    }
    return response.map: PodRegistryEntry.from-map it

  /** See $BrokerCli.pod-registry-pod-ids. */
  pod-registry-pod-ids --fleet-id/uuid.Uuid --references/List -> Map:
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
      pod-id := uuid.parse it["pod_id"]
      reference := PodReference
          --name=it["name"]
          --tag=it.get "tag"
          --revision=it.get "revision"
      result[reference] = pod-id
    return result

  /** See $BrokerCli.pod-registry-upload-pod-part. */
  pod-registry-upload-pod-part -> none
      --organization-id/uuid.Uuid
      --part-id/string
      content/ByteArray:
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-pods/$organization-id/part/$part-id",
      "content": content,
    }

  /** See $BrokerCli.pod-registry-download-pod-part. */
  pod-registry-download-pod-part part-id/string --organization-id/uuid.Uuid -> ByteArray:
    return send-request_ COMMAND-DOWNLOAD-PRIVATE_ {
      "path": "/toit-artemis-pods/$organization-id/part/$part-id",
    }

  /** See $BrokerCli.pod-registry-upload-pod-manifest. */
  pod-registry-upload-pod-manifest -> none
      --organization-id/uuid.Uuid
      --pod-id/uuid.Uuid
      content/ByteArray:
    send-request_ COMMAND-UPLOAD_ {
      "path": "/toit-artemis-pods/$organization-id/manifest/$pod-id",
      "content": content,
    }

  /** See $BrokerCli.pod-registry-download-pod-manifest. */
  pod-registry-download-pod-manifest --organization-id/uuid.Uuid --pod-id/uuid.Uuid -> ByteArray:
    return send-request_ COMMAND-DOWNLOAD-PRIVATE_ {
      "path": "/toit-artemis-pods/$organization-id/manifest/$pod-id",
    }
