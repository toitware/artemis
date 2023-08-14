// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.ubjson

class Firmware:
  size/int
  parts/List
  device-specific-encoded/ByteArray
  checksum/ByteArray

  constructor.encoded encoded/string:
    decoded := ubjson.decode (base64.decode encoded)
    device-specific-encoded = decoded["device-specific"]
    device-specific := ubjson.decode device-specific-encoded
    parts = ubjson.decode device-specific["parts"]
    checksum = decoded["checksum"]
    size = parts.last["to"] + checksum.size

  static id --hash/ByteArray -> string:
    return base64.encode hash --url-mode

class Checkpoint:
  // We keep the checksums for the new and the old firmware
  // around, so we can validate if a stored checkpoint is
  // intended for a specific firmware update.
  old-checksum/ByteArray
  new-checksum/ByteArray

  // How far did we get in reading the structured description
  // of the target firmware?
  read-part-index/int
  read-offset/int

  // How far did we get in writing the bits of the target
  // firmware out to flash?
  write-offset/int
  write-skip/int

  constructor
      --.old-checksum
      --.new-checksum
      --.read-part-index
      --.read-offset
      --.write-offset
      --.write-skip:
