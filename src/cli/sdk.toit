// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate_roots
import .cache as cli
import encoding.json
import encoding.ubjson
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

  constructor --envelope/string --cache/cli.Cache:
    sdk_version := get_sdk_version_from --envelope=envelope
    return get_sdk sdk_version --cache=cache

  is_source_build -> bool:
    return sdk_path.ends_with "build/host"

  compile_to_snapshot path/string --out/string -> none:
    pipe.backticks [
      "$sdk_path/bin/toit.compile",
      "-w", "$out",
      path,
    ]

  compile_snapshot_to_image -> none
      --word_size/int
      --snapshot_path/string
      --out/string:
    if word_size != 32 and word_size != 64: throw "Unsupported word size: $word_size"
    pipe.backticks [
      "$sdk_path/tools/snapshot_to_image",
      "-o", out,
      "--binary",
      word_size == 32 ? "-m32" : "-m64",
      snapshot_path,
    ]

  download_packages dir/string -> none:
    pipe.backticks [
      "$sdk_path/bin/toit.pkg",
      "install",
      "--project-root=$dir",
    ]

  assets_create --output_path/string assets/Map:
    run_assets_tool [ "-e", output_path, "create" ]
    with_tmp_directory: | tmp_dir |
      assets.do: | asset_name/string asset_description/Map |
        asset_path/string := ?
        if asset_description.contains "json":
          asset_path = "$tmp_dir/$(asset_name).json"
          write_json_to_file asset_path asset_description["json"]
        else if asset_description.contains "blob":
          asset_path = "$tmp_dir/$(asset_name).blob"
          write_blob_to_file asset_path asset_description["blob"]
        else if asset_description.contains "path":
          asset_path = asset_description["path"]
        else:
          throw "Invalid asset description: $asset_description"
        format := asset_description["format"]
        run_assets_tool [
          "-e", output_path,
          "add",
          "--format", format,
          asset_name,
          asset_path,
        ]

  /**
  Installs the container $name in the given $envelope.

  The $envelope, the $app_path and its $assets must be paths to files.
  The parameter $app_path must point to a snapshot or image.
  */
  firmware_add_container name/string --app_path/string --envelope/string --assets/string?=null:
    args := ?
    if assets:
      // TODO(florian): at the moment we can't just add the assets flags to
      // the end, as the current SDK version (alpha-50) doesn't support that.
      args = [
        "container", "install",
        "-e", envelope,
        "--assets", assets,
        name,
        app_path,
      ]
    else:
      args = [
        "container", "install",
        "-e", envelope,
        name,
        app_path,
      ]
    run_firmware_tool args

  /**
  Sets the property $name to $value in the given $envelope.
  */
  firmware_set_property name/string value/string --envelope/string:
    run_firmware_tool [
      "property", "set",
      "-e", envelope,
      name,
      value,
    ]

  /**
  Gets the property $name from the given $envelope.
  */
  firmware_get_property name/string --envelope/string -> string:
    return (pipe.backticks [
      "$sdk_path/tools/firmware",
      "property", "get",
      "-e", envelope,
      name,
    ]).trim

  /**
  Extracts the firmware from the given $envelope_path.

  If $device_specific_path is given, it is given to the firmware tool.

  The returned map has the following structure:
  ```
  {
    // The binary bits of the firmware.
    // All other offsets are relative to this.
    "binary": <binary>
    parts: [
      {
        // The offset of the part in the binary.
        "from": <int>
        "to": <int>
        // The type of the part.
        "type": "binary" | "images" | "config" | "checksum" |
      },
      ...
    ]
  }
  ```
  */
  firmware_extract --envelope_path/string --device_specific_path/string?=null -> Map:
    with_tmp_directory: | tmp_dir |
      firmware_ubjson_path := "$tmp_dir/firmware.ubjson"
      args := [
        "extract",
        "-e", envelope_path,
        "--format", "ubjson",
        "--output", firmware_ubjson_path,
      ]
      if device_specific_path: args += [ "--config", device_specific_path ]

      run_firmware_tool args
      return ubjson.decode (file.read_content firmware_ubjson_path)
    unreachable

  /**
  Lists the containers inside the given $envelope_path.
  Returns a map from container name to container description.
  Each container description has the following fields:
  - "kind": "snapshot" | "image"
  - "id": the ID of the application.
  */
  firmware_list_containers --envelope_path/string -> Map:
    return json.parse (pipe.backticks [
      "$sdk_path/tools/firmware",
      "container", "list",
      "-e", envelope_path,
    ])

  /**
  Extracts the container with the given $name from the $envelope_path and
    stores it in $output_path.

  If $assets is true, extracts the assets and not the application.
  */
  firmware_extract_container --envelope_path/string --name/string --assets/bool=false --output_path/string:
    args := [
      "container", "extract",
      "-e", envelope_path,
      "--output", output_path,
      "--part", assets ? "assets" : "image",
      name,
    ]
    if assets: args += [ "--assets" ]
    run_firmware_tool args

  /**
  Flashes the given envelope to the device at $port with the given $baud_rate.

  Combines the $envelope_path and $config_path into a single firmware while
    flashing.
  */
  flash --envelope_path/string --config_path/string --port/string --baud_rate/string?:
    args := [
      "flash",
      "-e", envelope_path,
      "--config", config_path,
      "--port", port,
    ]
    if baud_rate: args += [ "--baud", baud_rate ]
    run_firmware_tool args

  run_assets_tool arguments/List -> none:
    exit_status := pipe.run_program [tools_executable "assets"] + arguments
    if exit_status != 0: throw "assets tool failed with exit code $(pipe.exit_code exit_status)"

  run_firmware_tool arguments/List -> none:
    exit_status := pipe.run_program [tools_executable "firmware"] + arguments
    if exit_status != 0: throw "firmware tool failed with exit code $(pipe.exit_code exit_status)"

  run_toit_compile arguments/List -> none:
    exit_status := pipe.run_program [bin_executable "toit.compile"] + arguments
    if exit_status != 0: throw "toit.compile failed with exit code $(pipe.exit_code exit_status)"

  run_snapshot_to_image_tool arguments/List -> none:
    exit_status := pipe.run_program [tools_executable "snapshot_to_image"] + arguments
    if exit_status != 0: throw "snapshot_to_image tool failed with exit code $(pipe.exit_code exit_status)"

  tools_executable name/string -> string:
    return "$sdk_path/tools/$name$exe_extension"

  bin_executable name/string -> string:
    return "$sdk_path/bin/$name$exe_extension"

  static exe_extension ::= (platform == PLATFORM_WINDOWS) ? ".exe" : ""

  /**
  Extracts the SDK version from the given $envelope.
  */
  static get_sdk_version_from --envelope/string -> string:
    // TODO(florian): we shouldn't use a non-versioned SDK here.
    // Instead the sdk_version should be inside the envelope as an Ar-file.
    return json.parse ((Sdk).firmware_get_property --envelope=envelope "sdk-version")

  /**
  Stores the given $sdk_version in the $envelope.
  */
  // TODO(florian): this shouldn't be necessary: the SDK version should
  // already be stored in the envelope when it is created.
  // It should also not be a property, as that would require us to use
  // firmware tools to extract it.
  static store_sdk_version_in --envelope/string sdk_version/string -> none:
    (Sdk).firmware_set_property --envelope=envelope "sdk-version" (json.stringify sdk_version)

/**
Builds the URL of a released SDK with the given $version on GitHub.

Chooses the download URL based on the current platform.
*/
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
  url := sdk_url version
  sdk_key := "$SDK_PATH/$version"
  path := cache.get_directory_path sdk_key: | store/cli.DirectoryStore |
    with_tmp_directory: | tmp_dir |
      out_path := "$tmp_dir/toit.tar.gz"
      download_url url --out_path=out_path
      store.with_tmp_directory: | final_out_dir/string |
        untar out_path --target=final_out_dir
        store.move "$final_out_dir/toit"
  return Sdk path version
