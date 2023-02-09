// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
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
    id/string? := extract_id_from_snapshot path
    if id: return CompiledProgram.snapshot path --id=id --sdk=sdk
    return  CompiledProgram.source path --sdk=sdk

  constructor.source path/string --sdk/Sdk:
    with_tmp_directory: | tmp/string |
      snapshot_path := "$tmp/snapshot"
      sdk.run_toit_compile ["-w", snapshot_path, path]
      return CompiledProgram.snapshot snapshot_path --sdk=sdk
    unreachable

  constructor.snapshot path/string --id/string?=null --sdk/Sdk:
    with_tmp_directory: | tmp/string |
      id = id or extract_id_from_snapshot path
      if not id:
        print_on_stderr_ "$path: Not a valid Toit snapshot"
        exit 1
      image32 := "$tmp/image32"
      image64 := "$tmp/image64"
      sdk.run_snapshot_to_image_tool ["-m32", "--binary", "-o", image32, path]
      sdk.run_snapshot_to_image_tool ["-m64", "--binary", "-o", image64, path]
      return CompiledProgram id
          file.read_content image32
          file.read_content image64
          --sdk=sdk
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
