// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_

import ...shared.mqtt.base

create_status_commands _ -> List:
  status_cmd := cli.Command "status"
      --short_help="Print the online status of the device."
      --options=device_options
      --run=:: show_status it

  watch_presence_cmd := cli.Command "watch-presence"
      --short_help="Watch for presence status changes of the device."
      --options=device_options
      --run=:: watch_presence it

  return [
    status_cmd,
    watch_presence_cmd
  ]

show_status parsed/cli.Parsed:
  mediator := create_mediator parsed
  if mediator is not MediatorCliMqtt:
    throw "Only MQTT is supported for this command."

  mqtt_mediator := mediator as MediatorCliMqtt
  // TODO(florian): map device name to device id.
  device_id := parsed["device"]
  mqtt_mediator.print_status --device_id=device_id
  mqtt_mediator.close

watch_presence parsed/cli.Parsed:
  mediator := create_mediator parsed
  if mediator is not MediatorCliMqtt:
    throw "Only MQTT is supported for this command."

  mqtt_mediator := mediator as MediatorCliMqtt
  mqtt_mediator.watch_presence
  unreachable
