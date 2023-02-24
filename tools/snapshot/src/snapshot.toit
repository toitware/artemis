// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import host.file
import cli
import uuid

extract_uuid --path/string -> string:
  if not file.is_file path:
    throw "Snapshot file not found: $path"
  bytes := file.read_content path
  return extract_uuid bytes

extract_uuid snapshot_bytes/ByteArray -> string:
  ar_reader := ar.ArReader.from_bytes snapshot_bytes
  ar_file := ar_reader.find "uuid"
  if not ar_file: throw "No uuid file in snapshot"
  return (uuid.Uuid (ar_file.content)).stringify
