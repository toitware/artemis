// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid
import system.storage
import encoding.ubjson

import .config.magic
import .config.proto.api.config_pb as proto
import .config.tpack as tpack

read_device_id -> string:
  region := storage.Region.open --partition "secure" --no-writable
  bytes := region.read --from=0 --to=0x1000
  decoder := ubjson.Decoder bytes
  decoded := decoder.decode
  return decoded["identity"]["hardware_id"]

read_connections -> List:
  config_bytes := TOIT_CONFIG
  16.repeat: print "0x$(%02x config_bytes[it])"
  decoded := tpack.Message.in config_bytes
  deserialized := proto.Config.deserialize decoded

  result := []
  deserialized.connection.connections.do: | connection/proto.Connection |
    if connection.network_oneof_case == proto.Connection.NETWORK_WIFI:
      result.add {
        "type": "wifi",
        "ssid": connection.network_wifi.ssid,
        "password": connection.network_wifi.password,
      }
      print "Found wifi $connection.network_wifi.ssid"
  return result
