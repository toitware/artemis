// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate_roots
import .cache as cli
import host.file
import host.pipe
import http
import log
import net
import writer show Writer
import uuid

import .cache show SDK_PATH
import .jaguar
import .utils

class Sdk:
  sdk_path/string
  version/string

  // TODO(florian): remove default constructor.
  constructor:
    path := resolve_jaguar_sdk_path
    if not path:
      // TODO(florian): improve this.
      throw "Could not find the Toit SDK."
    sdk_path = path
    version = (pipe.backticks "$sdk_path/bin/toit.compile" "--version").trim

  constructor .sdk_path .version:

  is_source_build -> bool:
    return sdk_path.ends_with "build/host"

  compile_to_snapshot path/string --out/string -> none:
    pipe.backticks [
      "$sdk_path/bin/toit.compile",
      "-w", "$out",
      path,
    ]

  compile_snapshot_to_image -> none
      --bits/int
      --snapshot_path/string
      --out/string:
    if bits != 32 and bits != 64: throw "Unsupported bits: $bits"
    pipe.backticks [
      "$sdk_path/tools/snapshot_to_image",
      "-o", out,
      "--binary",
      bits == 32 ? "-m32" : "-m64",
      snapshot_path,
    ]

  download_packages dir/string -> none:
    pipe.backticks [
      "$sdk_path/bin/toit.pkg",
      "install",
      "--project-root=$dir",
    ]

  run_assets_tool arguments/List -> none:
    pipe.run_program [tools_executable "assets"] + arguments

  run_firmware_tool arguments/List -> none:
    pipe.run_program [tools_executable "firmware"] + arguments

  run_toit_compile arguments/List -> none:
    pipe.run_program [bin_executable "toit.compile"] + arguments

  run_snapshot_to_image_tool arguments/List -> none:
    pipe.run_program [tools_executable "snapshot_to_image"] + arguments

  tools_executable name/string -> string:
    return "$sdk_path/tools/$name$exe_extension"

  bin_executable name/string -> string:
    return "$sdk_path/bin/$name$exe_extension"

  static exe_extension ::= (platform == PLATFORM_WINDOWS) ? ".exe" : ""

sdk_url version/string -> string:
  platform_str/string := ?
  if platform == PLATFORM_LINUX:
    platform_str = "linux"
  else if platform == PLATFORM_MACOS:
    platform_str = "macos"
  else:
    throw "Unsupported platform: $platform"

  return "github.com/toitlang/toit/releases/download/$version/toit-$(platform_str).tar.gz"

get_sdk version/string --cache/cli.Cache -> Sdk:
  sdk_url := sdk_url version
  sdk_key := "$SDK_PATH/$version"
  path := cache.get_directory_path sdk_key: | store/cli.DirectoryStore |
    with_tmp_directory: | tmp_dir |
      network := net.open
      client := http.Client.tls network
          --root_certificates=certificate_roots.ALL
      parts := sdk_url.split --at_first "/"
      host := parts.first
      path := parts.last
      log.info "Downloading $sdk_url"
      response := client.get host path
      if response.status_code != 200:
        throw "Failed to download $sdk_url: $response.status_code $response.status_message"
      file := file.Stream.for_write "$tmp_dir/toit.tar.gz"
      writer := Writer file
      while chunk := response.body.read:
        writer.write chunk
      writer.close
      // TODO(florian): closing should be idempotent.
      // file.close

      store.with_tmp_directory: | final_out_dir/string |
        untar "$tmp_dir/toit.tar.gz" --target=final_out_dir
        store.move "$final_out_dir/toit"

  return Sdk path version

untar path/string --target/string:
  pipe.backticks [
    // All modern tar versions automatically detect the compression.
    // No need to provide `-z` or so.
    "tar",
    "x",            // Extract.
    "-f", "$path",  // The file at 'path'
    "-C", target,   // Extract to 'target'.
  ]
