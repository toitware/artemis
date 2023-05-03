// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import bytes
import crypto.sha256
import encoding.base64
import encoding.ubjson
import host.file
import host.os
import snapshot show cache_snapshot
import uuid

import .sdk
import .cache show ENVELOPE_PATH
import .cache as cli
import .device
import .pod
import .utils
import ..shared.utils.patch


/**
A firmware for a specific device.

Contains the generic $content which is shared among devices that use the same firmware version.
In addition, it contains the $device_specific_data which is unique to the device.
*/
class Firmware:
  /**
  The generic firmware.
  The generic firmware can be shared among different devices.
  The content always contains a description, identifying the firmware, but does not
    always contain the actual bytes.
  */
  content/FirmwareContent
  /**
  An encoded description of this firmware.
  Contains the $device_specific_data, and a checksum of the $content.
  */
  encoded/string
  /**
  The device-specific data.

  This data contains information such as the device ID, the organization ID,
    the hardware ID and the wifi configuration. It also contains the "parts"
    field which describes the individual parts of the firmware, and the sdk
    version that was used to create the firmware.
  */
  device_specific_data/ByteArray
  /** A decoded version of the $device_specific_data. */
  device_specific_data_/Map

  constructor .content .device_specific_data:
    map := {
      "device-specific": device_specific_data,
      "checksum": content.checksum }
    encoded = base64.encode (ubjson.encode map)
    device_specific_data_ = ubjson.decode device_specific_data
    if not device_specific_data_.contains "artemis.device":
      throw "Invalid device-specific data: Missing artemis.device"
    if not device_specific_data_.contains "parts":
      throw "Invalid device-specific data: Missing parts"
    if not device_specific_data_.contains "sdk-version":
      throw "Invalid device-specific data: Missing sdk-version"
    assert: device_specific_data_["parts"] == content.encoded_parts

  constructor.encoded .encoded:
    map := ubjson.decode (base64.decode encoded)
    device_specific_data = map["device-specific"]
    device_specific_data_ = ubjson.decode device_specific_data
    content = FirmwareContent.encoded device_specific_data_["parts"] --checksum=map["checksum"]

  /**
  Embeds device-specific information in $device into a firmware given by
    its pod.

  Computes the "parts" which describes the individual parts of the
    firmware. Most parts consist of a range, and the binary hash of its content.
    Some parts, like the one containing the device-specific information only
    contains its range. The parts description is then encoded with ubjson and
    also stored in the device-specific information part (under the name "parts").

  Since adding the encoded parts to the device-specific information part
    may change the size of the part (and thus the ranges of the other parts),
    the process is repeated until the encoded parts do not change anymore.
  */
  constructor --device/Device --pod/Pod --cache/cli.Cache:
    sdk_version := Sdk.get_sdk_version_from --envelope_path=pod.envelope_path
    unconfigured := FirmwareContent.from_envelope pod.envelope_path --cache=cache
    encoded_parts := unconfigured.encoded_parts
    device_map := {
      "device_id":       "$device.id",
      "organization_id": "$device.organization_id",
      "hardware_id":     "$device.hardware_id",
    }
    while true:
      device_specific := ubjson.encode {
        "artemis.device" : device_map,
        "parts"          : encoded_parts,
        // TODO(florian): these don't feel like they are device-specific properties.
        "sdk-version"    : sdk_version,
        "pod-id"         : pod.id.to_byte_array,
      }

      configured := FirmwareContent.from_envelope pod.envelope_path
          --device_specific=device_specific
          --cache=cache
      if configured.encoded_parts == encoded_parts:
        return Firmware configured device_specific
      encoded_parts = configured.encoded_parts

  device_specific key/string -> any:
    return device_specific_data_.get key

  device -> Device:
    device_map := device_specific "artemis.device"
    return Device
        --id=uuid.parse device_map["device_id"]
        --organization_id=uuid.parse device_map["organization_id"]
        --hardware_id=uuid.parse device_map["hardware_id"]

  /** The sdk version that was used for this firmware. */
  sdk_version -> string:
    return device_specific "sdk-version"

  pod_id -> uuid.Uuid:
    return uuid.Uuid (device_specific "pod-id")

class FirmwareContent:
  bits/ByteArray?
  parts/List
  checksum/ByteArray
  encoded_parts/ByteArray

  constructor --.bits --.parts --.checksum:
    encoded_parts = ubjson.encode (parts.map: it.encode)

  constructor.encoded .encoded_parts --.checksum:
    bits = null
    list := ubjson.decode encoded_parts
    parts = list.map: FirmwarePart.encoded it

  constructor.from_envelope envelope_path/string --device_specific/ByteArray?=null --cache/cli.Cache:
    sdk_version := Sdk.get_sdk_version_from --envelope_path=envelope_path
    sdk := get_sdk sdk_version --cache=cache
    firmware_description/Map := {:}
    if device_specific:
      with_tmp_directory: | tmp_dir/string |
        device_specific_path := tmp_dir + "/device_specific"
        write_blob_to_file device_specific_path device_specific
        firmware_description = sdk.firmware_extract
            --envelope_path=envelope_path
            --device_specific_path=device_specific_path
    else:
      firmware_description = sdk.firmware_extract --envelope_path=envelope_path

    bits := firmware_description["binary"]
    checksum/ByteArray? := null

    parts := []
    firmware_description["parts"].do: | entry/Map |
      from := entry["from"]
      to := entry["to"]
      part_bits := bits[from..to]
      type := entry["type"]

      if type == "config":
        parts.add (FirmwarePartConfig --from=from --to=to)
      else if type == "checksum":
        checksum = part_bits
      else:
        parts.add (FirmwarePartPatch --from=from --to=to --bits=part_bits)

    return FirmwareContent --bits=bits --parts=parts --checksum=checksum

  patches from/FirmwareContent? -> List:
    result := []
    parts.size.repeat: | index/int |
      part := parts[index]
      if part is FirmwarePartConfig: continue.repeat
      // TODO(kasper): This should not just be based on index.
      old/FirmwarePartPatch? := null
      if from: old = from.parts[index]
      if old and old.hash == part.hash:
        continue.repeat
      else if old:
        result.add (FirmwarePatch --bits=part.bits --from=old.hash --to=part.hash)
      else:
        result.add (FirmwarePatch --bits=part.bits --to=part.hash)
    return result

  trivial_patches -> List:
    result := []
    parts.do: | part/FirmwarePart |
      if part is FirmwarePartConfig: continue.do
      patch_part := part as FirmwarePartPatch
      result.add (FirmwarePatch --bits=patch_part.bits --to=patch_part.hash)
    return result

class PatchWriter implements PatchObserver:
  buffer/bytes.Buffer ::= bytes.Buffer
  size/int? := null
  on_write data from/int=0 to/int=data.size:
    buffer.write data[from..to]
  on_size size/int -> none:
    this.size = size
  on_new_checksum checksum/ByteArray -> none:
    // Do nothing.
  on_checkpoint patch_position/int -> none:
    // Do nothing.

class FirmwarePatch:
  bits_/ByteArray
  from_/ByteArray?
  to_/ByteArray

  constructor --bits/ByteArray --to/ByteArray --from/ByteArray?=null:
    bits_ = bits
    to_ = to
    from_ = from

abstract class FirmwarePart:
  from/int
  to/int
  constructor .from .to:

  constructor.encoded map/Map:
    type := map.get "type"
    if type == "config": return FirmwarePartConfig.encoded map
    else: return FirmwarePartPatch.encoded map

  abstract encode -> Map

class FirmwarePartPatch extends FirmwarePart:
  bits/ByteArray? := null
  hash/ByteArray

  constructor --from/int --to/int --.bits/ByteArray:
    sha := sha256.Sha256
    sha.add bits
    hash = sha.get
    super from to

  constructor --from/int --to/int --.hash:
    super from to

  constructor.encoded map/Map:
    return FirmwarePartPatch --from=map["from"] --to=map["to"] --hash=map["hash"]

  encode -> Map:
    return { "from": from, "to": to, "hash": hash }

class FirmwarePartConfig extends FirmwarePart:
  constructor --from/int --to/int:
    super from to

  constructor.encoded map/Map:
    return FirmwarePartConfig --from=map["from"] --to=map["to"]

  encode -> Map:
    return { "from": from, "to": to, "type": "config" }

/**
Builds the URL for the firmware envelope for the given $version on GitHub.
*/
envelope_url version/string --chip/string -> string:
  return "github.com/toitlang/toit/releases/download/$version/firmware-$(chip).gz"

/**
Stores the snapshots inside the envelope in the user's snapshot directory.
*/
cache_snapshots --envelope_path/string --output_directory/string?=null --cache/cli.Cache:
  sdk_version := Sdk.get_sdk_version_from --envelope_path=envelope_path
  sdk := get_sdk sdk_version --cache=cache
  containers := sdk.firmware_list_containers --envelope_path=envelope_path
  with_tmp_directory: | tmp_dir/string |
    containers.do: | name/string description/Map |
      if description["kind"] == "snapshot":
        id := description["id"]
        tmp_snapshot_path := "$tmp_dir/$(id).snapshot"
        sdk.firmware_extract_container
            --envelope_path=envelope_path
            --name=name
            --output_path=tmp_snapshot_path
        snapshot_content := file.read_content tmp_snapshot_path
        cache_snapshot snapshot_content --output_directory=output_directory

// A forwarding function to work around the shadowing in 'get_envelope'.
cache_snapshots_ --envelope_path/string --cache/cli.Cache:
  cache_snapshots --envelope_path=envelope_path --cache=cache

reported_local_envelope_use_/bool := false
/**
Returns a path to the firmware envelope for the given $version.

If $cache_snapshots is true, then copies the contained snapshots
  into the cache.
*/
// TODO(florian): we probably want to create a class for the firmware
// envelope.
get_envelope version/string -> string
    --chip/string="esp32"
    --cache/cli.Cache
    --cache_snapshots/bool=true:
  if is_dev_setup:
    local_sdk := os.env.get "DEV_TOIT_REPO_PATH"
    if local_sdk:
      if not reported_local_envelope_use_:
        print_on_stderr_ "Using envelope from local SDK"
        reported_local_envelope_use_ = true
      return "$local_sdk/build/esp32/firmware.envelope"

  url := envelope_url version --chip=chip
  path := "firmware-$(chip).envelope"
  envelope_key := "$ENVELOPE_PATH/$version/$path"
  return cache.get_file_path envelope_key: | store/cli.FileStore |
    store.with_tmp_directory: | tmp_dir |
      out_path := "$tmp_dir/$(path).gz"
      download_url url --out_path=out_path
      gunzip out_path
      envelope_path := "$tmp_dir/$path"
      if cache_snapshots:
        cache_snapshots_ --envelope_path=envelope_path --cache=cache
      store.move envelope_path
