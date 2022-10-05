// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import host.file
import host.directory
import host.pipe
import host.os
import uuid

class ToitImages:
  id/string
  image32/ByteArray
  image64/ByteArray

  constructor .id .image32 .image64:

run_assets_tool arguments/List -> none:
  sdk := get_toit_sdk
  pipe.run_program ["$sdk/tools/assets"] + arguments

application_to_images application_path -> ToitImages:
  if application_path.ends_with ".toit":
    return toit_to_images application_path
  return snapshot_to_images application_path

toit_to_images toit_path/string -> ToitImages:
  last_slash := toit_path.index_of --last "/"
  last_backslash := toit_path.index_of --last "\\"
  last_separator := max last_slash last_backslash
  name := ?
  if last_separator == -1:
    name = toit_path
  else:
    name = toit_path[last_separator + 1 ..]
  name = name.trim --right ".toit"
  with_tmp_directory: | dir/string |
    snapshot_path := "$dir/$(name).snapshot"
    sdk := get_toit_sdk
    pipe.run_program ["$sdk/bin/toit.compile", "-w", snapshot_path, toit_path]
    return snapshot_to_images snapshot_path --tmp_directory=dir
  unreachable

snapshot_to_images snapshot_path/string --tmp_directory/string?=null -> ToitImages:
  if not tmp_directory:
    with_tmp_directory: | dir/string |
      return snapshot_to_images snapshot_path --tmp_directory=dir
    unreachable

  id := get_uuid_from_snapshot snapshot_path
  if not id:
    print_on_stderr_ "$snapshot_path: Not a valid Toit snapshot"
    exit 1

  // Create the two images.
  sdk := get_toit_sdk
  image32 := "$tmp_directory/image32"
  image64 := "$tmp_directory/image64"

  pipe.run_program ["$sdk/tools/snapshot_to_image", "-m32", "--binary", "-o", image32, snapshot_path]
  pipe.run_program ["$sdk/tools/snapshot_to_image", "-m64", "--binary", "-o", image64, snapshot_path]
  return ToitImages id (file.read_content image32) (file.read_content image64)

get_toit_sdk -> string:
  if os.env.contains "JAG_TOIT_REPO_PATH":
    repo := "$(os.env["JAG_TOIT_REPO_PATH"])/build/host/sdk"
    if file.is_directory "$repo/bin" and file.is_directory "$repo/tools":
      return repo
    print_on_stderr_ "JAG_TOIT_REPO_PATH doesn't point to a built Toit repo"
    exit 1
  if os.env.contains "HOME":
    jaguar := "$(os.env["HOME"])/.cache/jaguar/sdk"
    if file.is_directory "$jaguar/bin" and file.is_directory "$jaguar/tools":
      return jaguar
    print_on_stderr_ "\$HOME/.cache/jaguar/sdk doesn't contain a Toit SDK"
    exit 1
  print_on_stderr_ "Did not find JAG_TOIT_REPO_PATH or a Jaguar installation"
  exit 1
  unreachable

get_uuid_from_snapshot snapshot_path/string -> string?:
  if not file.is_file snapshot_path:
    print_on_stderr_ "$snapshot_path: Not a file"
    exit 1

  snapshot := file.read_content snapshot_path

  ar_reader /ar.ArReader? := null
  exception := catch:
    ar_reader = ar.ArReader.from_bytes snapshot  // Throws if it's not a snapshot.
  if exception: return null
  first := ar_reader.next
  if first.name != "toit": return null
  id/string? := null
  while member := ar_reader.next:
    if member.name == "uuid":
      id = (uuid.Uuid member.content).stringify
  return id

with_tmp_directory [block]:
  tmpdir := directory.mkdtemp "/tmp/artemis-image-creation-"
  try:
    block.call tmpdir
  finally:
    directory.rmdir --recursive tmpdir
