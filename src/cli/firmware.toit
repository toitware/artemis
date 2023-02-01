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
In addition, it contains the $config which is unique to the device.
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
  Contains the $config, and a checksum of the $content.
  */
  encoded/string
  config/ByteArray
  config_/Map

  constructor .content .config:
    map := { "config": config, "checksum": content.checksum }
    encoded = base64.encode (ubjson.encode map)
    config_ = ubjson.decode config
    assert: config_["parts"] == content.encoded

  constructor.encoded .encoded:
    map := ubjson.decode (base64.decode encoded)
    config = map["config"]
    config_ = ubjson.decode config
    content = FirmwareContent.encoded config_["parts"] --checksum=map["checksum"]

  config key/string -> any:
    return config_.get key

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
  encoded/ByteArray

  constructor --.bits --.parts --.checksum:
    encoded = ubjson.encode (parts.map: it.encode)

  constructor.encoded .encoded --.checksum:
    bits = null
    list := ubjson.decode encoded
    parts = list.map: FirmwarePart.encoded it

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

extract_firmware_ envelope_path/string config/ByteArray? sdk/Sdk -> FirmwareContent:
  extract/Map? := null
  with_tmp_directory: | tmp/string |
    firmware_ubjson_path := "$tmp/firmware.ubjson"
    arguments := ["-e", envelope_path, "extract", "-o", firmware_ubjson_path, "--format=ubjson"]
    if config:
      config_path := "$tmp/config.json"
      write_blob_to_file config_path config
      arguments += ["--config", config_path]

    sdk.run_firmware_tool arguments
    extract = ubjson.decode (file.read_content firmware_ubjson_path)

  bits := extract["binary"]
  parts := []
  checksum/ByteArray? := null

  extract["parts"].do: | entry/Map |
    from := entry["from"]
    to := entry["to"]
    part := bits[from..to]

    if entry["type"] == "config":
      parts.add (FirmwarePartConfig --to=to --from=from)
    else if entry["type"] == "checksum":
      checksum = part
    else:
      parts.add (FirmwarePartPatch --to=to --from=from --bits=part)

  return FirmwareContent --bits=bits --parts=parts --checksum=checksum

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
