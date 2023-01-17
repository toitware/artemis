// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import .cache as cli
import host.file
import host.pipe
import http
import log
import net
import writer show Writer

import .cache show SDK_PATH
import .utils

class Sdk:
  sdk_path/string

  constructor .sdk_path:

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

  return Sdk path

untar path/string --target/string:
  pipe.backticks [
    // All modern tar versions automatically detect the compression.
    // No need to provide `-z` or so.
    "tar",
    "x",            // Extract.
    "-f", "$path",  // The file at 'path'
    "-C", target,   // Extract to 'target'.
  ]
