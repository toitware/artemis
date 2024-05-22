// Copyright (C) 2024 Toitware ApS. All rights reserved.

import io
import system.storage
import uuid

abstract class Storage:
  /** UUID used to ensure that the flash's data is actually from us. */
  static FLASH-ENTRY-UUID_ ::= "ccf4efed-6825-44e6-b71d-1aa118d43824"

  static flash_/storage.Bucket ::= storage.Bucket.open --flash "toit.io/artemis"
  static ram_/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis"

  flash-load key/string -> any:
    entry := flash_.get key
    if entry is not Map: return null
    if (entry.get "uuid") != FLASH-ENTRY-UUID_: return null
    return entry["data"]

  flash-store key/string value/any -> none:
    if value == null:
      flash_.remove key
    else:
      flash_[key] = { "uuid": FLASH-ENTRY-UUID_, "data": value }

  ram-load key/string -> any:
    return ram_.get key

  ram-store key/string value/any -> none:
    if value == null:
      ram_.remove key
    else:
      ram_[key] = value

  abstract container-list-images -> List
  abstract container-write-image --id/uuid.Uuid --size/int --reader/io.Reader -> uuid.Uuid
