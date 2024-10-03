// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import encoding.json
import encoding.ubjson
import host.file
import host.pipe
import host.os
import http
import log
import net
import semver
import system
import writer show Writer

import .cache as cli
import .cache show cache-key-sdk
import .ui show Ui
import .utils

class Sdk:
  sdk-path/string
  version/string

  constructor .sdk-path .version:

  constructor --envelope-path/string --cache/cli.Cache --ui/Ui:
    sdk-version := get-sdk-version-from --envelope-path=envelope-path
    return get-sdk sdk-version --cache=cache --ui=ui

  is-source-build -> bool:
    return sdk-path.ends-with "build/host"

  compile-to-snapshot path/string --out/string --flags/List=["-O2"] -> none:
    if (semver.compare version "v2.0.0-alpha.161") < 0:
      arguments := ["-w", "$out"] + flags
      run-toit-compile arguments + [path]
    else:
      arguments := ["--snapshot", "-o", out] + flags
      run-compile arguments + [path]

  compile-snapshot-to-image -> none
      --snapshot-path/string
      --format/string="binary"
      --word-sizes/List
      --out/string:
    args := [
      "-o", out,
      "--format=$format",
      snapshot-path
    ]
    args += word-sizes.map: | size/int |
      if size != 32 and size != 64: throw "Unsupported word size: $size"
      size == 32 ? "-m32" : "-m64"
    run-snapshot-to-image args

  assets-create --output-path/string assets/Map:
    run-assets [ "-e", output-path, "create" ]
    with-tmp-directory: | tmp-dir |
      assets.do: | asset-name/string asset-description/Map |
        asset-path/string := ?
        if asset-description.contains "json":
          asset-path = "$tmp-dir/$(asset-name).json"
          write-json-to-file asset-path asset-description["json"]
        else if asset-description.contains "blob":
          asset-path = "$tmp-dir/$(asset-name).blob"
          write-blob-to-file asset-path asset-description["blob"]
        else if asset-description.contains "path":
          asset-path = asset-description["path"]
        else:
          throw "Invalid asset description: $asset-description"
        format := asset-description["format"]
        run-assets [
          "-e", output-path,
          "add",
          "--format", format,
          asset-name,
          asset-path,
        ]

  /** Extracts the asset with the given $name from the $assets-path. */
  assets-extract --name/string --assets-path/string -> any
      --format/string="auto":
    with-tmp-directory: | tmp-dir |
      result-path := "$tmp-dir/$name"
      run-assets [
        "-e", assets-path,
        "get",
        "--output", result-path,
        "--format", format,
        name,
      ]
      return file.read-content result-path
    unreachable

  /**
  Installs the container $name in the given $envelope.

  The $envelope, the $program-path and its $assets must be paths to files.
  The parameter $program-path must point to a snapshot or image.
  */
  firmware-add-container name/string --program-path/string --envelope/string -> none
      --assets/string?=null
      --critical/bool=false
      --trigger/string:
    args := [
      "container", "install",
      "-e", envelope,
      "--trigger", trigger,
      name,
      program-path,
    ]
    if assets: args += [ "--assets", assets ]
    if critical: args += [ "--critical" ]
    run-firmware args

  /**
  Sets the property $name to $value in the given $envelope.
  */
  firmware-set-property name/string value/string --envelope/string:
    if system.platform == system.PLATFORM-WINDOWS and (value.contains " " or value.contains ","):
      // Ugly work-around for Windows issue where arguments are not escaped
      // correctly.
      // See https://github.com/toitlang/toit/issues/1403 and
      //   https://github.com/toitlang/toit/blob/0e1157190578f8ca6cbdb8f4ba1db9700ae44fb9/src/resources/pipe_win.cc#L459
      value = value.replace --all "\\" "\\\\"
      value = value.replace --all "\"" "\\\""
    run-firmware [
      "property", "set",
      "-e", envelope,
      name,
      value,
    ]

  /**
  Gets the property $name from the given $envelope.
  */
  firmware-get-property name/string --envelope/string -> string:
    return (pipe.backticks [
      "$sdk-path/tools/firmware",
      "property", "get",
      "-e", envelope,
      name,
    ]).trim

  /**
  Variant of $(firmware-extract --format --envelope-path).

  Uses the format "ubjson" and decodes the result.

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
  firmware-extract --envelope-path/string --device-specific-path/string?=null -> Map:
    encoded := firmware-extract
        --format="ubjson"
        --envelope-path=envelope-path
        --device-specific-path=device-specific-path
    return ubjson.decode encoded

  /**
  Extracts the firmware from the given $envelope-path using the specified $format.

  If $device-specific-path is given, it is given to the firmware tool.
  */
  firmware-extract --envelope-path/string --format/string --device-specific-path/string?=null -> ByteArray:
    with-tmp-directory: | tmp-dir |
      out-path := "$tmp-dir/extracted-firmware"
      args := [
        "extract",
        "-e", envelope-path,
        "--format", format,
        "--output", out-path,
      ]
      if device-specific-path: args += [ "--config", device-specific-path ]

      run-firmware args
      return file.read-content out-path
    unreachable

  /**
  Lists the containers inside the given $envelope-path.
  Returns a map from container name to container description.
  Each container description has the following fields:
  - "kind": "snapshot" | "image"
  - "id": the ID of the application.
  */
  firmware-list-containers --envelope-path/string -> Map:
    // Newer versions of the SDK require explictly asking
    // for the JSON output.
    output-format := []
    if (semver.compare version "v2.0.0-alpha.88") >= 0:
      output-format = ["--output-format", "json"]

    return json.parse (pipe.backticks [
      "$sdk-path/tools/firmware",
      "container", "list",
      "-e", envelope-path,
    ] + output-format)

  /**
  Extracts the container with the given $name from the $envelope-path and
    stores it in $output-path.

  If $assets is true, extracts the assets and not the application.
  */
  firmware-extract-container --envelope-path/string --name/string --assets/bool=false --output-path/string:
    args := [
      "container", "extract",
      "-e", envelope-path,
      "--output", output-path,
      "--part", assets ? "assets" : "image",
      name,
    ]
    run-firmware args

  chip-for --envelope-path/string -> string?:
    if (semver.compare version "v2.0.0-alpha.150") < 0:
      throw "Unsupported for SDK versions older than v2.0.0-alpha.150"
    firmware := executable_ "firmware"
    json-output := pipe.backticks firmware + ["show", "--output-format", "json", "-e", envelope-path]
    decoded := json.parse json-output.trim
    return decoded.get "chip"

  /**
  Flashes the given envelope to the device at $port with the given $baud-rate.

  Combines the $envelope-path and $config-path into a single firmware while
    flashing.
  */
  flash
      --envelope-path/string
      --config-path/string
      --port/string
      --baud-rate/string?
      --partitions/List?:
    if (semver.compare version "v2.0.0-alpha.152") < 0:
      throw "Flashing is not supported for SDK versions older than v2.0.0-alpha.152"

    // TODO(florian): we shouldn't need to pass `chip` to the firmware tool.
    chip := chip-for --envelope-path=envelope-path

    arguments := [
      "flash",
      "-e", envelope-path,
      "--config", config-path,
      "--port", port,
    ]
    if baud-rate:
      arguments += [ "--baud", baud-rate ]
    if partitions and not partitions.is-empty:
      arguments += [ "--partition", partitions.join "," ]
    run-firmware arguments

  /**
  Extracts the given $envelope-path to the given $output-path.
  */
  extract-qemu-image
      --output-path/string
      --envelope-path/string
      --config-path/string
      --partitions/List?:
    if partitions and not partitions.is-empty:
      throw "Partitions are not supported for QEMU images."

    arguments := [
      "extract",
      "-e", envelope-path,
      "--config", config-path,
      "--output", output-path,
      "--format", "qemu",
    ]
    run-firmware arguments

  /**
  Installs the dependencies of the project at $project-root.
  */
  pkg-install --project-root/string:
    run-pkg [
      "install",
      "--project-root", project-root,
    ]

  run-assets arguments/List -> none:
    exit-status := pipe.run-program (executable_ "assets") + arguments
    if exit-status != 0: throw "assets tool failed with exit code $(pipe.exit-code exit-status)"

  run-firmware arguments/List -> none:
    exit-status := pipe.run-program (executable_ "firmware") + arguments
    if exit-status != 0: throw "firmware tool failed with exit code $(pipe.exit-code exit-status)"

  // Runs 'toit.compile'.
  // This is for older SDKs only.
  run-toit-compile arguments/List -> none:
    exit-status := pipe.run-program (executable_ "toit.compile") + arguments
    if exit-status != 0: throw "toit.compile failed with exit code $(pipe.exit-code exit-status)"

  // Runs 'toit compile'.
  // This is for newer SDKs.
  run-compile arguments/List -> none:
    exit-status := pipe.run-program (executable_ "compile") + arguments
    if exit-status != 0: throw "toit.compile failed with exit code $(pipe.exit-code exit-status)"

  run-pkg arguments/List -> none:
    exit-status := pipe.run-program (executable_ "pkg") + arguments
    if exit-status != 0: throw "toit.pkg failed with exit code $(pipe.exit-code exit-status)"

  run-snapshot-to-image arguments/List -> none:
    exit-status := pipe.run-program (executable_ "snapshot_to_image") + arguments
    if exit-status != 0: throw "snapshot_to_image tool failed with exit code $(pipe.exit-code exit-status)"

  static PRE-161-EXECUTABLES ::= {
    "toit.compile": ["bin/toit.compile"],
    "pkg": ["bin/toit.pkg"],
    "assets": ["tools/assets"],
    "firmware": ["tools/firmware"],
    "snapshot_to_image": ["tools/snapshot_to_image"],
  }

  static POST-161-EXECUTABLES ::= {
    "compile": ["bin/toit", "compile"],
    "pkg": ["bin/toit", "pkg"],
    "assets": ["bin/toit", "tool", "assets"],
    "firmware": ["bin/toit", "tool", "firmware"],
    "snapshot_to_image": ["bin/toit", "tool", "snapshot-to-image"],
  }

  executable_ name/string -> List:
    cmd := (semver.compare version "v2.0.0-alpha.161") < 0
        ? PRE-161-EXECUTABLES[name]
        : POST-161-EXECUTABLES[name]
    exe-extension := (system.platform == system.PLATFORM-WINDOWS) ? ".exe" : ""
    result := ["$sdk-path/$cmd[0]$exe-extension"] + cmd[1..]
    return result

  /**
  Extracts the SDK version from the given $envelope-path.
  */
  static get-sdk-version-from --envelope-path/string -> string:
    return get-sdk-version-from
        --envelope=file.read-content envelope-path

  /**
  Extracts the SDK version from the given $envelope.
  */
  static get-sdk-version-from --envelope/ByteArray -> string:
    reader := ar.ArReader.from-bytes envelope
    // Newer versions of envelopes have a metadata file.
    file := reader.find "\$metadata"
    if file != null:
      metadata := json.decode file.content
      return metadata["sdk-version"]
    // Restart the reader from the beginning.
    reader = ar.ArReader.from-bytes envelope
    file = reader.find "\$sdk-version"
    if file == null: throw "SDK version not found in envelope."
    return file.content.to-string

  static get-word-bit-size-from --envelope/ByteArray -> int:
    reader := ar.ArReader.from-bytes envelope
    file := reader.find "\$metadata"
    if file != null:
      metadata := json.decode file.content
      return metadata["word-size"] * 8
    return 32

  static get-chip-family-from --envelope/ByteArray -> string:
    reader := ar.ArReader.from-bytes envelope
    file := reader.find "\$metadata"
    if file != null:
      metadata := json.decode file.content
      // Currently the kind and chip-family align.
      return metadata["kind"]
    return "esp32"

/**
Builds the URL of a released SDK with the given $version on GitHub.

Chooses the download URL based on the current platform.
*/
sdk-url version/string -> string:
  arch := system.architecture
  platform := system.platform
  platform-str/string := ?
  if platform == system.PLATFORM-LINUX:
    if arch == system.ARCHITECTURE-X86-64:
      platform-str = "linux"
    else if arch == system.ARCHITECTURE-ARM64:
      platform-str = "aarch64"
    else if arch == system.ARCHITECTURE-ARM:
      platform-str = "rpi"
    else:
      throw "Unsupported architecture: $arch"
  else if system.platform == system.PLATFORM-MACOS:
    // TODO(florian): choose the the ARM version if we are running
    // on an ARM Mac and the version is recent enough.
    platform-str = "macos"
  else if system.platform == system.PLATFORM-WINDOWS:
    platform-str = "windows"
  else:
    throw "Unsupported platform: $system.platform"

  return "https://github.com/toitlang/toit/releases/download/$version/toit-$(platform-str).tar.gz"

reported-local-sdk-use_/bool := false

get-sdk version/string --cache/cli.Cache --ui/Ui -> Sdk:
  if is-dev-setup:
    local-sdk := os.env.get "DEV_TOIT_REPO_PATH"
    if local-sdk:
      if not reported-local-sdk-use_:
        print-on-stderr_ "Using local SDK"
        reported-local-sdk-use_ = true
      return Sdk "$local-sdk/build/host/sdk" version

  url := sdk-url version
  cache-key := cache-key-sdk --version=version
  path := cache.get-directory-path cache-key: | store/cli.DirectoryStore |
    with-tmp-directory: | tmp-dir |
      gzip-path := "$tmp-dir/toit.tar.gz"
      tar-path := "$tmp-dir/toit.tar"
      download-url url --out-path=gzip-path --ui=ui
      store.with-tmp-directory: | final-out-dir/string |
        // We don't use 'tar' to extract the archive, because that
        // doesn't work with the git-tar. It would fail to find the
        // gzip executable.
        gunzip gzip-path
        untar tar-path --target=final-out-dir
        store.move "$final-out-dir/toit"
  return Sdk path version
