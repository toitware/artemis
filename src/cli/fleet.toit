// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import host.file

import .artemis
import .cache
import .device
import .firmware
import .ui
import .utils

class DeviceFleet:
  id/string
  organization_id/string

  name/string?
  aliases/List?

  constructor --.id --.organization_id --.name=null --.aliases=null:

  constructor.from_json .id/string encoded/Map:
    organization_id = encoded["organization_id"]
    name = encoded.get "name"
    aliases = encoded.get "aliases"

  short_string -> string:
    if name: return "$id ($name)"
    return id

class Fleet:
  static DEVICES_FILE_ ::= "devices.json"
  /** Signal that an alias is ambiguous. */
  static AMBIGUOUS_ ::= -1

  artemis_/Artemis
  ui_/Ui
  cache_/Cache
  fleet_root_/string
  devices_/List
  /** Map from name, device-id, alias to index in $devices_. */
  aliases_/Map := {:}

  constructor .fleet_root_ .artemis_ --ui/Ui --cache/Cache:
    ui_ = ui
    cache_ = cache
    devices_ = load_devices_ fleet_root_ --ui=ui
    aliases_ = build_alias_map_ devices_ ui

  static init fleet_root/string --ui/Ui:
    if not file.is_directory fleet_root:
      ui.error "Fleet root $fleet_root is not a directory."
      ui.abort

    if file.is_file "$fleet_root/$DEVICES_FILE_":
      ui.error "Fleet root $fleet_root already contains a $DEVICES_FILE_ file."
      ui.abort

    write_json_to_file "$fleet_root/$DEVICES_FILE_" {:}

    ui.info "Initialized fleet directory $fleet_root."

  static load_devices_ fleet_root/string --ui/Ui -> List:
    if not file.is_directory fleet_root:
      ui.error "Fleet root $fleet_root is not a directory."
      ui.abort
    devices_path := "$fleet_root/$DEVICES_FILE_"
    if not file.is_file devices_path:
      ui.error "Fleet root $fleet_root does not contain a $DEVICES_FILE_ file."
      ui.error "Use 'init' to initialize a directory as fleet directory."
      ui.abort

    encoded_devices := null
    exception := catch: encoded_devices = read_json devices_path
    if exception:
      ui.error "Fleet file $devices_path is not a valid JSON."
      ui.error exception.message
      ui.abort
    if encoded_devices is not Map:
      ui.error "Fleet file $devices_path has invalid format."
      ui.abort

    devices := []
    encoded_devices.do: | device_id encoded_device |
      if encoded_device is not Map:
        ui.error "Fleet file $devices_path has invalid format for device ID $device_id."
        ui.abort
      exception = catch:
        device := DeviceFleet.from_json device_id encoded_device
        devices.add device
      if exception:
        ui.error "Fleet file $devices_path has invalid format for device ID $device_id."
        ui.error exception.message
        ui.abort
    return devices

  /**
  Builds an alias map.

  When referring to devices we allow names, device-ids and aliases as
    designators. This function builds a map for these and warns the
    user if any of them is ambiguous.
  */
  static build_alias_map_ devices/List ui/Ui -> Map:
    result := {:}
    ambiguous_ids := {:}
    devices.size.repeat: | i/int |
      device/DeviceFleet := devices[i]
      add_alias := : | id/string |
        if result.contains id:
          old := result[id]
          if old == i:
            // The name, device-id or alias appears twice for the same
            // device. Not best practice, but not ambiguous.
            continue.add_alias

          if old == AMBIGUOUS_:
            ambiguous_ids[id].add id
          else:
            ambiguous_ids[id] = [old, id]
            result[id] = AMBIGUOUS_
        else:
          result[id] = i

      add_alias.call device.id
      if device.name:
        add_alias.call device.name
      if device.aliases:
        device.aliases.do: | alias/string |
          add_alias.call alias
    if ambiguous_ids.size > 0:
      ui.warning "The following names, device-ids or aliases are ambiguous:"
      ambiguous_ids.do: | id index_list/List |
        uuid_list := index_list.map: devices[it].id
        ui.warning "  $id maps to $(uuid_list.join ", ")"
    return result

  write_devices_ -> none:
    encoded_devices := {:}
    devices_.do: | device/DeviceFleet |
      entry := {
        "organization_id": device.organization_id,
      }
      if device.name: entry["name"] = device.name
      if device.aliases: entry["aliases"] = device.aliases
      encoded_devices[device.id] = entry
    write_json_to_file "$fleet_root_/$DEVICES_FILE_" encoded_devices --pretty

  create_firmware --specification_path/string --output_path/string --organization_ids/List:
    specification := parse_device_specification_file specification_path --ui=ui_
    artemis_.customize_envelope
        --output_path=output_path
        --device_specification=specification

    organization_ids.do: | organization_id/string |
      artemis_.upload_firmware output_path --organization_id=organization_id
      ui_.info "Successfully uploaded firmware to organization $organization_id."

  create_identities --output_directory/string --organization_id/string count/int:
    old_size := devices_.size
    try:
      count.repeat: | i/int |
        device_id := random_uuid_string

        output := "$output_directory/$(device_id).identity"

        artemis_.provision
            --device_id=device_id
            --out_path=output
            --organization_id=organization_id

        // TODO(florian): create a nice random name.
        devices_.add (DeviceFleet --id=device_id --organization_id=organization_id)
        ui_.info "Created $output."
    finally:
      if devices_.size != old_size:
        write_devices_

  update devices/List --specification_path/string? --firmware_path/string? --diff_bases/List:
    broker := artemis_.connected_broker
    detailed_devices := {:}
    fleet_devices := devices.map: | alias/string |
      fleet_device := resolve_alias_ alias
      device := broker.get_device --device_id=fleet_device.id
      if not device:
        ui_.error "Device $device.id is unknown to the broker."
        ui_.abort
      fleet_device

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
      fleet_devices.do: | fleet_device/DeviceFleet |
        if not diff_bases.is_empty:
          device/DeviceDetailed := detailed_devices[fleet_device.id]
          if not seen_organizations.contains device.organization_id:
            seen_organizations.add device.organization_id
            base_patches.do: | _ patch/FirmwarePatch |
              artemis_.upload_patch patch --organization_id=device.organization_id

        artemis_.update
            --device_id=fleet_device.id
            --envelope_path=firmware_path
            --base_firmwares=base_firmwares

        ui_.info "Successfully updated device $fleet_device.short_string."

  upload envelope_path/string --to/List:
    to.do: | organization_id/string |
      artemis_.upload_firmware envelope_path --organization_id=organization_id
      ui_.info "Successfully uploaded firmware."

  resolve_alias_ alias/string -> DeviceFleet:
    if not aliases_.contains alias:
      ui_.error "No device with name, device-id, or alias $alias in the fleet."
      ui_.abort
    device_index := aliases_[alias]
    if device_index == AMBIGUOUS_:
      ui_.error "The name, device-id, or alias $alias is ambiguous."
      ui_.abort
    return devices_[device_index]
