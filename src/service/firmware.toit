// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.ubjson

class Firmware:
  size/int
  parts/List
  device_specific_encoded/ByteArray
  checksum/ByteArray

  constructor.encoded encoded/string:
    decoded := ubjson.decode (base64.decode encoded)
    device_specific_encoded = decoded["device-specific"]
    device_specific := ubjson.decode device_specific_encoded
    parts = ubjson.decode device_specific["parts"]
    checksum = decoded["checksum"]
    size = parts.last["to"] + checksum.size

  static id --hash/ByteArray -> string:
    return base64.encode hash --url_mode

class Checkpoint:
  // We keep the checksums for the new and the old firmware
  // around, so we can validate if a stored checkpoint is
  // intended for a specific firmware update.
  old_checksum/ByteArray
  new_checksum/ByteArray

  // How far did we get in reading the structured description
  // of the target firmware?
  read_part_index/int
  read_offset/int

  // How far did we get in writing the bits of the target
  // firmware out to flash?
  write_offset/int
  write_skip/int

  constructor
      --.old_checksum
      --.new_checksum
      --.read_part_index
      --.read_offset
      --.write_offset
      --.write_skip:
