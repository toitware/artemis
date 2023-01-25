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
- installed applications.
*/
class DeviceSpecification:
  sdk_version/string
  artemis_version/string
  max_offline_seconds/int
  connections/List  // Of $ConnectionInfo.
  apps/List  // Of $Application.

  constructor
      --.sdk_version
      --.artemis_version
      --.max_offline_seconds
      --.connections
      --.apps:

  constructor.from_json data/Map:
    if data["version"] != 1:
      throw "Unsupported device specification version: $data["version"]"

    return DeviceSpecification
      --sdk_version=data["sdk_version"]
      --artemis_version=data["artemis_version"]
      --max_offline_seconds=data["max_offline_seconds"]
      --connections=data["connections"].map: ConnectionInfo.from_json it
      --apps=data["apps"].map: Application.from_json it

  static parse path/string -> DeviceSpecification:
    encoded := file.read_content path
    return DeviceSpecification.from_json (json.parse encoded.to_string)

interface ConnectionInfo:
  static from_json data/Map -> ConnectionInfo:
    if data["type"] == "wifi":
      return WifiConnectionInfo.from_json data
    throw "Unknown connection type: $data["type"]"

  to_json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string
  password/string

  constructor --.ssid --.password:

  constructor.from_json data/Map:
    return WifiConnectionInfo --ssid=data["ssid"] --password=data["password"]

  to_json -> Map:
    return {"type": "wifi", "ssid": ssid, "password": password}

interface Application:
  static from_json data/Map -> Application:
    type := data.get "type"
    if not type: type = "path"
    if data["type"] != "path":
      throw "Unsupported application type: $data["type"]"
    return ApplicationPath.from_json data

  to_json -> Map

class ApplicationPath implements Application:
  entry_point/string

  constructor --.entry_point:

  constructor.from_json data/Map:
    return ApplicationPath --entry_point=data["entry_point"]

  to_json -> Map:
    return {"type": "path", "entry_point": entry_point}
