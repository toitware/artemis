// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import fs
import fs.xdg
import host.directory
import host.file
import host.os
import uuid
import .utils_

extract-uuid --path/string -> string:
  if not file.is-file path:
    throw "Snapshot file not found: $path"
  bytes := file.read-content path
  return extract-uuid bytes

extract-uuid snapshot-bytes/ByteArray -> string:
  ar-reader := ar.ArReader.from-bytes snapshot-bytes
  ar-file := ar-reader.find "uuid"
  if not ar-file: throw "No uuid file in snapshot"
  return (uuid.Uuid (ar-file.content)).stringify

cached-snapshot-path_ uuid/string --output-directory/string? -> string:
  if output-directory:
    return "$output-directory/$(uuid).snapshot"
  else:
    cache-home := xdg.cache-home
    return "$cache-home/jaguar/snapshots/$(uuid).snapshot"

/**
Stores the given $snapshot in the user's snapshot directory.

This way, the monitor can find it and automatically decode stack traces.

Returns the UUID of the snapshot.
*/
cache-snapshot snapshot/ByteArray --output-directory/string?=null -> string:
  ar-reader := ar.ArReader.from-bytes snapshot
  ar-file := ar-reader.find "uuid"
  if not ar-file: throw "No uuid file in snapshot"
  uuid := (uuid.Uuid (ar-file.content)).stringify
  out-path := cached-snapshot-path_ uuid --output-directory=output-directory
  dir-path := fs.dirname out-path
  if not file.is-directory dir-path:
    directory.mkdir --recursive dir-path
  write-blob-to-file out-path snapshot
  return uuid
