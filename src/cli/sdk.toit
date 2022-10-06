// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import host.file
import host.directory
import host.pipe
import host.os
import uuid

IS_SOURCE_BUILD              ::= resolve_is_source_build_
PATH_FIRMWARE_ENVELOPE_ESP32 ::= resolve_firmware_envelope_path_ "esp32"

PATH_TOIT_COMPILE_           ::= resolve_jaguar_sdk_path_ --dir="bin" "toit.compile"
PATH_ASSETS_TOOL_            ::= resolve_jaguar_sdk_path_ --dir="tools" "assets"
PATH_FIRMWARE_TOOL_          ::= resolve_jaguar_sdk_path_ --dir="tools" "firmware"
PATH_SNAPSHOT_TO_IMAGE_TOOL_ ::= resolve_jaguar_sdk_path_ --dir="tools" "snapshot_to_image"

run_assets_tool arguments/List -> none:
  pipe.run_program [PATH_ASSETS_TOOL_] + arguments

run_firmware_tool arguments/List -> none:
  pipe.run_program [PATH_FIRMWARE_TOOL_] + arguments

run_toit_compile arguments/List -> none:
  pipe.run_program [PATH_TOIT_COMPILE_] + arguments

run_snapshot_to_image_tool arguments/List -> none:
  pipe.run_program [PATH_SNAPSHOT_TO_IMAGE_TOOL_] + arguments

with_tmp_directory [block]:
  tmpdir := directory.mkdtemp "/tmp/artemis-"
  try:
    block.call tmpdir
  finally:
    directory.rmdir --recursive tmpdir

cache_snapshot path/string -> none:
  if not os.env.contains "HOME": return
  cache := "$(os.env["HOME"])/.cache/jaguar/snapshots"
  if not file.is_directory cache: return
  id := extract_id_from_snapshot_ path
  if not id: return
  pipe.run_program ["cp", "-f", path, "$cache/$(id).snapshot"]

class CompiledProgram:
  id/string
  image32/ByteArray
  image64/ByteArray

  constructor .id .image32 .image64:

  constructor.application path/string:
    id/string? := extract_id_from_snapshot_ path
    return id ? (CompiledProgram.snapshot path --id=id) : CompiledProgram.source path

  constructor.source path/string:
    with_tmp_directory: | tmp/string |
      snapshot_path := "$tmp/snapshot"
      run_toit_compile ["-w", snapshot_path, path]
      return CompiledProgram.snapshot snapshot_path
    unreachable

  constructor.snapshot path/string --id/string?=null:
    with_tmp_directory: | tmp/string |
      id = id or extract_id_from_snapshot_ path
      if not id:
        print_on_stderr_ "$path: Not a valid Toit snapshot"
        exit 1
      image32 := "$tmp/image32"
      image64 := "$tmp/image64"
      run_snapshot_to_image_tool ["-m32", "--binary", "-o", image32, path]
      run_snapshot_to_image_tool ["-m64", "--binary", "-o", image64, path]
      return CompiledProgram id (file.read_content image32) (file.read_content image64)
    unreachable

resolve_is_source_build_ -> bool:
  path := resolve_jaguar_path_
      --repo_directory="build/host/sdk"
      --repo_file="repo"
      --cache_directory="sdk"
      --cache_file="cache"
  return path.ends_with "/repo"

resolve_firmware_envelope_path_ model/string -> string:
  return resolve_jaguar_path_
      --repo_directory="build/$model"
      --repo_file="firmware.envelope"
      --cache_directory="assets"
      --cache_file="firmware-$(model).envelope"

resolve_jaguar_sdk_path_ --dir/string name/string -> string:
  return resolve_jaguar_path_
      --repo_directory="build/host/sdk/$dir"
      --repo_file=name
      --cache_directory="sdk/$dir"
      --cache_file=name

resolve_jaguar_path_ -> string
    --repo_directory/string
    --repo_file/string
    --cache_directory/string
    --cache_file/string:
  directory/string? := null
  result/string? := null
  if os.env.contains "JAG_TOIT_REPO_PATH":
    root := os.env["JAG_TOIT_REPO_PATH"]
    build := "$root/build"
    if not file.is_directory "$build/host" or not file.is_directory "$build/esp32":
      print_on_stderr_ "\$JAG_TOIT_REPO_PATH doesn't point to a built Toit repo"
      exit 1
    directory = "$root/$repo_directory"
    result = "$directory/$repo_file"
  else if os.env.contains "HOME":
    root := "$(os.env["HOME"])/.cache/jaguar"
    if not file.is_directory "$root/sdk" or not file.is_directory "$root/assets":
      print_on_stderr_ "\$HOME/.cache/jaguar doesn't contain the Jaguar bits"
      exit 1
    directory = "$root/$cache_directory"
    result = "$directory/$cache_file"
  if not directory or not file.is_directory directory:
    print_on_stderr_ "Did not find \$JAG_TOIT_REPO_PATH or a Jaguar installation"
    exit 1
  return result

extract_id_from_snapshot_ snapshot_path/string -> string?:
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
