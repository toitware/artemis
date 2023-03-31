// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import uuid

import .artemis
import .config
import .cache
import .device
import .device_specification
import .firmware
import .ui
import .utils

class Fleet:
  artemis_/Artemis
  ui_/Ui
  cache_/Cache

  constructor .artemis_ --ui/Ui --cache/Cache:
    ui_ = ui
    cache_ = cache

  create_firmware --specification_path/string --output_path/string --organization_ids/List:
    specification := parse_device_specification_file specification_path --ui=ui_
    artemis_.customize_envelope
        --output_path=output_path
        --device_specification=specification

    organization_ids.do: | organization_id/string |
      artemis_.upload_firmware output_path --organization_id=organization_id
      ui_.info "Successfully uploaded firmware to organization $organization_id."

  create_identities --output_directory/string --organization_id/string count/int:
    count.repeat: | i/int |
      device_id := random_uuid_string

      output := "$output_directory/$(device_id).identity"

      artemis_.provision
          --device_id=device_id
          --out_path=output
          --organization_id=organization_id
      ui_.info "Created $output."

  update devices/List --specification_path/string? --firmware_path/string? --diff_bases/List:
    broker := artemis_.connected_broker
    detailed_devices := {:}
    devices.do: | device_id/string |
      device := broker.get_device --device_id=device_id
      if not device:
        ui_.error "Device $device_id does not exist."
        ui_.abort

    base_patches := {:}

    base_firmwares := diff_bases.map: | diff_base/string |
      FirmwareContent.from_envelope diff_base --cache=cache_

    base_firmwares.do: | content/FirmwareContent |
      trivial_patches := artemis_.extract_trivial_patches content
      trivial_patches.do: | key value/FirmwarePatch | base_patches[key] = value

    with_tmp_directory: | tmp_dir/string |
      if specification_path:
        firmware_path = "$tmp_dir/firmware.envelope"
        specification := parse_device_specification_file specification_path --ui=ui_
        artemis_.customize_envelope
            --output_path=firmware_path
            --device_specification=specification

      seen_organizations := {}
      devices.do: | device_id/string |
        if not diff_bases.is_empty:
          device/DeviceDetailed := detailed_devices[device_id]
          if not seen_organizations.contains device.organization_id:
            seen_organizations.add device.organization_id
            base_patches.do: | _ patch/FirmwarePatch |
              artemis_.upload_patch patch --organization_id=device.organization_id

        artemis_.update
            --device_id=device_id
            --envelope_path=firmware_path
            --base_firmwares=base_firmwares

        ui_.info "Successfully updated device $device_id."

  upload envelope_path/string --to/List:
    to.do: | organization_id/string |
      artemis_.upload_firmware envelope_path --organization_id=organization_id
      ui_.info "Successfully uploaded firmware."
