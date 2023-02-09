// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import host.file
import .firmware
import .server_config

/**
A specification of a device.

This class contains the information needed to install/flash and
  update a device.

Relevant data includes (but is not limited to):
- the SDK version (which currently gives the firmware binary),
- max offline,
- connection information (Wi-Fi, cellular, ...),
- installed containers.
*/
class DeviceSpecification:
  sdk_version/string
  artemis_version/string
  max_offline_seconds/int
  connections/List  // Of $ConnectionInfo.
  containers/Map  // Of name -> $Container.

  constructor
      --.sdk_version
      --.artemis_version
      --.max_offline_seconds
      --.connections
      --.containers:

  constructor.from_json data/Map:
    if data["version"] != 1:
      throw "Unsupported device specification version: $data["version"]"

    if data.contains "apps" and not data.contains "containers":
      data = data.copy
      data["containers"] = data["apps"]

    containers := data["containers"].map: | _ container_description |
          Container.from_json container_description

    return DeviceSpecification
      --sdk_version=data["sdk-version"]
      --artemis_version=data["artemis-version"]
      --max_offline_seconds=data["max-offline-seconds"]
      --connections=data["connections"].map: ConnectionInfo.from_json it
      --containers=containers

  static parse path/string -> DeviceSpecification:
    encoded := file.read_content path
    return DeviceSpecification.from_json (json.parse encoded.to_string)

  to_json -> Map:
    return {
      "version": 1,
      "sdk-version": sdk_version,
      "artemis-version": artemis_version,
      "max-offline-seconds": max_offline_seconds,
      "connections": connections.map: it.to_json,
      "containers": containers.map: | _ container/Container | container.to_json,
    }

interface ConnectionInfo:
  static from_json data/Map -> ConnectionInfo:
    if data["type"] == "wifi":
      return WifiConnectionInfo.from_json data
    throw "Unknown connection type: $data["type"]"

  type -> string
  to_json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string
  password/string

  constructor --.ssid --.password:

  constructor.from_json data/Map:
    return WifiConnectionInfo --ssid=data["ssid"] --password=data["password"]

  type -> string:
    return "wifi"

  to_json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

interface Container:
  static from_json data/Map -> Container:
    if data.contains "entrypoint":
      return ContainerPath.from_json data
    if data.contains "snapshot":
      return ContainerSnapshot.from_json data
    throw "Unsupported container: $data"

  type -> string
  to_json -> Map

class ContainerPath implements Container:
  entrypoint/string

  constructor --.entrypoint:

  constructor.from_json data/Map:
    return ContainerPath --entrypoint=data["entrypoint"]

  type -> string:
    return "path"

  to_json -> Map:
    return { "entrypoint": entrypoint }

class ContainerSnapshot implements Container:
  snapshot_path/string

  constructor --.snapshot_path:

  constructor.from_json data/Map:
    return ContainerSnapshot --snapshot_path=data["snapshot"]

  type -> string:
    return "snapshot"

  to_json -> Map:
    return { "snapshot": snapshot_path}
