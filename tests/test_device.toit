// Copyright (C) 2023 Toitware ApS.

import encoding.json

import cli
import artemis.shared.server_config
import artemis.service.service
import artemis.service.device as service

/**
*/
main args:
  cmd := cli.Command "root"
    --options=[
      cli.Option "json-broker-config" --required,
      cli.Option "alias-id" --required,
      cli.Option "hardware-id" --required,
      cli.Option "organization-id" --required,
      cli.Option "encoded-firmware" --required,
    ]
    --run=::
      run
          --alias_id=it["alias-id"]
          --hardware_id=it["hardware-id"]
          --organization_id=it["organization-id"]
          --encoded_firmware=it["encoded-firmware"]
          --json_broker_config=it["json-broker-config"]

  cmd.run args

run
    --alias_id/string
    --hardware_id/string
    --organization_id/string
    --encoded_firmware/string
    --json_broker_config/string:
  decoded_broker_config := json.parse json_broker_config
  broker_config := server_config.ServerConfig.from_json
      "device-broker"
      decoded_broker_config
      --der_deserializer=: unreachable

  device := service.Device
      --id=alias_id
      --organization_id=organization_id
      --firmware_state={
        "firmware": encoded_firmware,
      }
  while true:
    sleep_duration := service.run_artemis device broker_config --no-start_ntp
    sleep sleep_duration

