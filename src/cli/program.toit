// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import host.file
import snapshot show cache-snapshot
import uuid

import .utils
import .sdk

class CompiledProgram:
  id/uuid.Uuid
  image32/ByteArray
  image64/ByteArray
  sdk_/Sdk

  constructor .id .image32 .image64 --sdk:
    sdk_ = sdk

  constructor.application path/string --sdk/Sdk:
    snapshot-uuid/string? := extract-id-from-snapshot path
    if snapshot-uuid: return CompiledProgram.snapshot path --sdk=sdk
    return CompiledProgram.source path --sdk=sdk

  constructor.source path/string --sdk/Sdk:
    with-tmp-directory: | tmp/string |
      snapshot-path := "$tmp/snapshot"
      sdk.compile-to-snapshot path --out=snapshot-path
      snapshot-content := file.read-content snapshot-path
      cache-snapshot snapshot-content
      return CompiledProgram.snapshot snapshot-path --sdk=sdk
    unreachable

  constructor.snapshot path/string --sdk/Sdk:
    with-tmp-directory: | tmp/string |
      image-ubjson-path := "$tmp/image.ubjson"
      sdk.compile-snapshot-to-image
          --format="ubjson"
          --out=image-ubjson-path
          --word-sizes=[32, 64]
          --snapshot-path=path
      image := read-ubjson image-ubjson-path
      id := uuid.parse image["id"]
      image32/ByteArray? := null
      image64/ByteArray? := null
      image["images"].do: | map/Map |
        flags := map["flags"]
        bytes := map["bytes"]
        if flags.contains "-m32": image32 = bytes
        if flags.contains "-m64": image64 = bytes
      return CompiledProgram id image32 image64 --sdk=sdk
    unreachable

extract-id-from-snapshot snapshot-path/string -> string?:
  if not file.is-file snapshot-path:
    print-on-stderr_ "$snapshot-path: Not a file"
    exit 1

  snapshot := file.read-content snapshot-path
  ar-reader/ar.ArReader? := null
  exception := catch:
    ar-reader = ar.ArReader.from-bytes snapshot
  if exception: return null
  first := ar-reader.next
  if first.name != "toit": return null
  id/string? := null
  while member := ar-reader.next:
    if member.name == "uuid":
      id = (uuid.Uuid member.content).stringify
  return id
