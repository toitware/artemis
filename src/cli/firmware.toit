// Copyright (C) 2023 Toitware ApS. All rights reserved.

import bytes
import crypto.sha256
import encoding.base64
import encoding.ubjson
import host.file

import .sdk
import .cache show ENVELOPE_PATH
import .cache as cli
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
    field which describes the individual parts of the firmware.
  */
  device_specific_data/ByteArray
  /** A decoded version of the $device_specific_data. */
  device_specific_data_/Map

  constructor .content .device_specific_data:
    map := { "config": device_specific_data, "checksum": content.checksum }
    encoded = base64.encode (ubjson.encode map)
    device_specific_data_ = ubjson.decode device_specific_data
    assert: device_specific_data_["parts"] == content.encoded_parts

  constructor.encoded .encoded:
    map := ubjson.decode (base64.decode encoded)
    device_specific_data = map["config"]
    device_specific_data_ = ubjson.decode device_specific_data
    content = FirmwareContent.encoded device_specific_data_["parts"] --checksum=map["checksum"]

  /**
  Embets device-specific information ($device and $wifi) into a firmware
    given by its $envelope_path.

  Computes the "parts" which describes the individual parts of the
    firmware. Most parts consist of a range, and the binary hash of its content.
    Some parts, like the one containing the device-specific information only
    contains its range. The parts description is then encoded with ubjson and
    also stored in the device-specific information part (under the name "parts").

  Since adding the encoded parts to the device-specific information part
    may change the size of the part (and thus the ranges of the other parts),
    the process is repeated until the encoded parts do not change anymore.
  */
  constructor --device/Map --wifi/Map --envelope_path/string --cache/cli.Cache:
    unconfigured := FirmwareContent.from_envelope envelope_path --cache=cache
    encoded_parts := unconfigured.encoded_parts
    while true:
      device_specific := ubjson.encode {
        "artemis.device" : device,
        "wifi"           : wifi,
        "parts"          : encoded_parts,
      }

      configured := FirmwareContent.from_envelope envelope_path
          --device_specific=device_specific
          --cache=cache
      if configured.encoded_parts == encoded_parts:
        return Firmware configured device_specific
      encoded_parts = configured.encoded_parts

  device_specific key/string -> any:
    return device_specific_data_.get key

  patches from/Firmware? -> List:
    result := []
    content.parts.size.repeat: | index/int |
      part := content.parts[index]
      if part is FirmwarePartConfig: continue.repeat
      // TODO(kasper): This should not just be based on index.
      old/FirmwarePartPatch? := null
      if from: old = from.content.parts[index]
      if old and old.hash == part.hash:
        continue.repeat
      else if old:
        result.add (FirmwarePatch --bits=part.bits --from=old.hash --to=part.hash)
      else:
        result.add (FirmwarePatch --bits=part.bits --to=part.hash)
    return result

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
    sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
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
envelope_url version/string -> string:
  return "github.com/toitlang/toit/releases/download/$version/firmware-esp32.gz"

/**
Returns a path to the firmware envelope for the given $version.
*/
// TODO(florian): we probably want to create a class for the firmware
// envelope.
get_envelope version/string --cache/cli.Cache -> string:
  url := envelope_url version
  path := "firmware-esp32.envelope"
  envelope_key := "$ENVELOPE_PATH/$version/$path"
  return cache.get_file_path envelope_key: | store/cli.FileStore |
    store.with_tmp_directory: | tmp_dir |
      out_path := "$tmp_dir/$(path).gz"
      download_url url --out_path=out_path
      gunzip out_path
      store.move "$tmp_dir/$path"
