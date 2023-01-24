// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import host.os
import uuid
import .utils

cache_snapshot snapshot/ByteArray --output_directory/string?=null -> string:
  ar_reader := ar.ArReader.from_bytes snapshot
  ar_file := ar_reader.find "uuid"
  if not ar_file: throw "No uuid file in snapshot."
  uuid := (uuid.Uuid (ar_file.content)).stringify

  out_path/string := ?
  if output_directory:
    out_path = "$output_directory/$(uuid).snapshot"
  else:
    home := os.env.get "HOME"
    if not home: throw "No home directory."
    out_path = "$home/.cache/jaguar/snapshots/$(uuid).snapshot"

  write_file --path=out_path snapshot
  return uuid
