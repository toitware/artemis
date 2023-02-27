// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import fs
import fs.xdg
import host.directory
import host.file
import host.os
import cli
import uuid
import .utils_

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

cached_snapshot_path_ uuid/string --output_directory/string? -> string:
  if output_directory:
    return "$output_directory/$(uuid).snapshot"
  else:
    cache_home := xdg.cache_home
    return "$cache_home/jaguar/snapshots/$(uuid).snapshot"

/**
Stores the given $snapshot in the user's snapshot directory.

This way, the monitor can find it and automatically decode stack traces.

Returns the UUID of the snapshot.
*/
cache_snapshot snapshot/ByteArray --output_directory/string?=null -> string:
  ar_reader := ar.ArReader.from_bytes snapshot
  ar_file := ar_reader.find "uuid"
  if not ar_file: throw "No uuid file in snapshot"
  uuid := (uuid.Uuid (ar_file.content)).stringify
  out_path := cached_snapshot_path_ uuid --output_directory=output_directory
  dir_path := fs.dirname out_path
  if not file.is_directory dir_path:
    directory.mkdir --recursive dir_path
  write_blob_to_file out_path snapshot
  return uuid
