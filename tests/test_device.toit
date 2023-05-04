// Copyright (C) 2023 Toitware ApS.

import encoding.json

import cli
import artemis.shared.server_config
import artemis.service.service
import artemis.service.device as service
import artemis.cli.utils show OptionUuid
import uuid

main args:
  cmd := cli.Command "root"
    --options=[
      cli.Option "broker-config-json" --required,
      OptionUuid "alias-id" --required,
      OptionUuid "hardware-id" --required,
      OptionUuid "organization-id" --required,
      cli.Option "encoded-firmware" --required,
    ]
    --run=::
      run
          --alias_id=it["alias-id"]
          --hardware_id=it["hardware-id"]
          --organization_id=it["organization-id"]
          --encoded_firmware=it["encoded-firmware"]
          --broker_config_json=it["broker-config-json"]

  cmd.run args

run
    --alias_id/uuid.Uuid
    --hardware_id/uuid.Uuid
    --organization_id/uuid.Uuid
    --encoded_firmware/string
    --broker_config_json/string:
  decoded_broker_config := json.parse broker_config_json
  broker_config := server_config.ServerConfig.from_json
      "device-broker"
      decoded_broker_config
      --der_deserializer=: unreachable

  device := service.Device
      --id=alias_id
      --hardware_id=hardware_id
      --organization_id=organization_id
      --firmware_state={
        "firmware": encoded_firmware,
      }
  while true:
    sleep_duration := service.run_artemis device broker_config --no-start_ntp
    sleep sleep_duration

