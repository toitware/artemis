// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import encoding.ubjson
import host.file
import uuid

import .utils
import .sdk

class CompiledProgram:
  id/string
  image32/ByteArray
  image64/ByteArray
  sdk_/Sdk

  constructor .id .image32 .image64 --sdk:
    sdk_ = sdk

  constructor.application path/string --sdk/Sdk:
    snapshot_uuid/string? := extract_id_from_snapshot path
    if snapshot_uuid: return CompiledProgram.snapshot path --sdk=sdk
    return  CompiledProgram.source path --sdk=sdk

  constructor.source path/string --sdk/Sdk:
    with_tmp_directory: | tmp/string |
      snapshot_path := "$tmp/snapshot"
      sdk.run_toit_compile ["-w", snapshot_path, path]
      return CompiledProgram.snapshot snapshot_path --sdk=sdk
    unreachable

  constructor.snapshot path/string --sdk/Sdk:
    with_tmp_directory: | tmp/string |
      image_ubjson := "$tmp/image.ubjson"
      sdk.run_snapshot_to_image_tool ["-m32", "-m64", "--format=ubjson", "-o", image_ubjson, path]
      image := ubjson.decode (file.read_content image_ubjson)
      id := image["id"]
      image32/ByteArray? := null
      image64/ByteArray? := null
      image["images"].do: | map/Map |
        flags := map["flags"]
        bytes := map["bytes"]
        if flags.contains "-m32": image32 = bytes
        if flags.contains "-m64": image64 = bytes
      return CompiledProgram id image32 image64 --sdk=sdk
    unreachable

extract_id_from_snapshot snapshot_path/string -> string?:
  if not file.is_file snapshot_path:
    print_on_stderr_ "$snapshot_path: Not a file"
    exit 1

  snapshot := file.read_content snapshot_path
  ar_reader/ar.ArReader? := null
  exception := catch:
    ar_reader = ar.ArReader.from_bytes snapshot
  if exception: return null
  first := ar_reader.next
  if first.name != "toit": return null
  id/string? := null
  while member := ar_reader.next:
    if member.name == "uuid":
      id = (uuid.Uuid member.content).stringify
  return id
