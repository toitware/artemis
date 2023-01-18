// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import host.directory
import host.pipe
import host.os

import .utils
import .program

cache_snapshot path/string -> none:
  if not os.env.contains "HOME": return
  cache := "$(os.env["HOME"])/.cache/jaguar/snapshots"
  if not file.is_directory cache: return
  id := extract_id_from_snapshot_ path
  if not id: return
  pipe.run_program ["cp", "-f", path, "$cache/$(id).snapshot"]


resolve_firmware_envelope_path model/string -> string?:
  return resolve_jaguar_path_
      --repo="build/$model/firmware.envelope"
      --cache="assets/firmware-$(model).envelope"

resolve_jaguar_sdk_path -> string?:
  return resolve_jaguar_path_
      --repo="build/host/sdk"
      --cache="sdk"

resolve_jaguar_path_ --repo/string --cache/string -> string?:
  if os.env.contains "JAG_TOIT_REPO_PATH":
    root := os.env["JAG_TOIT_REPO_PATH"]
    build := "$root/build"
    if not file.is_directory "$build/host" or not file.is_directory "$build/esp32":
      throw "\$JAG_TOIT_REPO_PATH doesn't point to a built Toit repo"

    return "$root/$repo"

  if os.env.contains "HOME":
    root := "$(os.env["HOME"])/.cache/jaguar"
    if not file.is_directory "$root/sdk" or not file.is_directory "$root/assets":
      throw "\$HOME/.cache/jaguar doesn't contain the Jaguar bits"
    return "$root/$cache"

  return null
