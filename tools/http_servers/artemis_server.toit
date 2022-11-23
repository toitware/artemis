// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import uuid

import .base

main args:
  root_cmd := cli.Command "root"
    --long_help="""An HTTP-based Artemis server.

      Can be used instead of the Supabase servers.
      This server keeps data in memory and should thus only be used for testing.
      """
    --options=[
      cli.OptionInt "port" --short_name="p"
          --short_help="The port to listen on."
    ]
    --run=:: | parsed/cli.Parsed |
      broker := HttpArtemisServer parsed["port"]
      broker.start

  root_cmd.run args

class DeviceEntry:
  id/string
  alias/string
  fleet/string

  constructor .id --.alias --.fleet:

class EventEntry:
  device_id/string
  data/any

  constructor .device_id --.data:

  stringify -> string:
    return "EventEntry($device_id, $data)"

class HttpArtemisServer extends HttpServer:
  static DEVICE_NOT_FOUND ::= 0

  /** Map from ID to name. */
  organizations/Map := {:}
  /** Map from fleet-ID to organization ID. */
  fleets/Map := {:}
  /** Map from device-ID to $DeviceEntry. */
  devices/Map := {:}
  /** List of $EventEntry. */
  events/List := []

  errors/List := []

  constructor port/int:
    super port

  run_command command/string data -> any:
    if command == "check-in": return store_event data
    if command == "create-device-in-fleet": return create_device_in_fleet data
    if command == "notify-created": return store_event data
    else:
      throw "BAD COMMAND $command"

  store_event data/Map:
    device_id := data["hardware_id"]
    if not devices.contains device_id:
      errors.add [DEVICE_NOT_FOUND, device_id]
      throw "Device not found"
    events.add
        EventEntry device_id --data=data["data"]

  create_device_in_fleet data/Map:
    fleet_id := data["fleet"]
    alias := data.get "alias"

    hardware_id := "$(uuid.uuid5 "" "hardware_id - $Time.monotonic_us")"
    devices[hardware_id] = DeviceEntry hardware_id --alias=(alias or "") --fleet=fleet_id
    return hardware_id
