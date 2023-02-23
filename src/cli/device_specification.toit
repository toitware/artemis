// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.url as url_encoding
import host.file
import fs
import .cache as cli
import .cache show GIT_APP_PATH
import .firmware
import .sdk
import .server_config
import .utils
import .git

/**
A specification of a device.

This class contains the information needed to install/flash and
  update a device.

Relevant data includes (but is not limited to):
- the SDK version (which currently gives the firmware binary),
- max offline,
- connection information (Wi-Fi, cellular, ...),
- installed containers.
*/
class DeviceSpecification:
  sdk_version/string
  artemis_version/string
  max_offline_seconds/int
  connections/List  // Of $ConnectionInfo.
  containers/Map  // Of name -> $Container.
  path/string

  constructor
      --.path
      --.sdk_version
      --.artemis_version
      --.max_offline_seconds
      --.connections
      --.containers:

  constructor.from_json --path/string data/Map:
    if data["version"] != 1:
      throw "Unsupported device specification version: $data["version"]"

    if data.contains "apps" and not data.contains "containers":
      data = data.copy
      data["containers"] = data["apps"]

    containers := data["containers"].map: | _ container_description |
          Container.from_json container_description

    return DeviceSpecification
      --path=path
      --sdk_version=data["sdk-version"]
      --artemis_version=data["artemis-version"]
      // TODO(florian): make max-offline optional.
      --max_offline_seconds=(parse_max_offline_ (data["max-offline"])).in_s
      --connections=data["connections"].map: ConnectionInfo.from_json it
      --containers=containers

  static parse path/string -> DeviceSpecification:
    return DeviceSpecification.from_json --path=path (read_json path)

  static parse_max_offline_ max_offline_string/string -> Duration:
    // Parses a string like "1h 30m 10s" or "1h30m10s" into seconds.
    // Returns 0 if the string is empty.

    max_offline_string = max_offline_string.trim
    if max_offline_string == "": return Duration.ZERO

    UNITS ::= ["h", "m", "s"]
    splits_with_missing := UNITS.map: max_offline_string.index_of it
    splits := splits_with_missing.filter: it != -1
    if splits.is_empty or not splits.is_sorted:
      throw "Invalid max offline string: $max_offline_string"
    if splits.last != max_offline_string.size - 1:
      throw "Invalid max offline string: $max_offline_string"

    last_unit := -1
    values := {:}
    splits.do: | split/int |
      unit := max_offline_string[split]
      value_string := max_offline_string[last_unit + 1..split]
      value := int.parse value_string.trim --on_error=:
        throw "Invalid max offline string: $max_offline_string"
      values[unit] = value
      last_unit = split

    return Duration
        --h=values.get 'h' --if_absent=: 0
        --m=values.get 'm' --if_absent=: 0
        --s=values.get 's' --if_absent=: 0

  /**
  Returns the path to which all other paths of this specification are
    relative to.
  */
  relative_to -> string:
    return fs.dirname path

  to_json -> Map:
    return {
      "version": 1,
      "sdk-version": sdk_version,
      "artemis-version": artemis_version,
      "max-offline-seconds": max_offline_seconds,
      "connections": connections.map: it.to_json,
      "containers": containers.map: | _ container/Container | container.to_json,
    }

interface ConnectionInfo:
  static from_json data/Map -> ConnectionInfo:
    if data["type"] == "wifi":
      return WifiConnectionInfo.from_json data
    throw "Unknown connection type: $data["type"]"

  type -> string
  to_json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string
  password/string

  constructor --.ssid --.password:

  constructor.from_json data/Map:
    return WifiConnectionInfo --ssid=data["ssid"] --password=data["password"]

  type -> string:
    return "wifi"

  to_json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

interface Container:
  static from_json data/Map -> Container:
    if data.contains "entrypoint":
      return ContainerPath.from_json data
    if data.contains "snapshot":
      return ContainerSnapshot.from_json data
    throw "Unsupported container: $data"

  /**
  Builds a snapshot and stores it at the given $output_path.

  All paths in the container are relative to $relative_to.
  */
  build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache
  type -> string
  to_json -> Map

class ContainerPath implements Container:
  entrypoint/string
  git_url/string?
  git_ref/string?

  constructor --.entrypoint --.git_url --.git_ref:
    if git_url and not git_ref:
      throw "Git entry requires a branch/tag: $git_url"
    if git_url and not fs.is_relative entrypoint:
      throw "Git entry requires a relative path: $entrypoint"

  constructor.from_json data/Map:
    return ContainerPath
      --entrypoint=data["entrypoint"]
      --git_ref=data.get "branch"
      --git_url=data.get "git"

  build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache:
    if not git_url:
      path := entrypoint
      if fs.is_relative path:
        path = "$relative_to/$path"
      sdk.compile_to_snapshot path --out=output_path
      return

    git := Git
    git_key := "$GIT_APP_PATH/$git_url"
    cached_checkout := cache.get_directory_path git_key: | store/cli.DirectoryStore |
      store.with_tmp_directory: | tmp_dir/string |
        clone_dir := "$tmp_dir/clone"
        git.init clone_dir --origin=git_url
        git.config --repository_root=clone_dir
            --key="advice.detachedHead"
            --value="false"
        git.fetch
            --repository_root=clone_dir
            --depth=1
            --ref=git_ref
        store.move clone_dir
    // Make sure we have the ref we need in the cache.
    git.fetch --force --depth=1 --ref=git_ref --repository_root=cached_checkout
    // In case the remote updated the ref, update the local tag.
    git.tag
        --update
        --name=git_ref
        --ref="origin/$git_ref"
        --repository_root=cached_checkout
        --force

    with_tmp_directory: | tmp_dir/string |
      // Clone the repository to a temporary directory, so we
      // aren't affected by changes to the cache.
      clone_dir := "$tmp_dir/clone"
      file_uri := "file://$(url_encoding.encode cached_checkout)"
      git.init clone_dir --origin=file_uri
      git.config --repository_root=clone_dir
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository_root=clone_dir
          --ref=git_ref
      entrypoint_path := "$clone_dir/$entrypoint"
      if not file.is_file entrypoint_path:
        throw "No such file: $entrypoint_path"

      package_yaml_path := "$clone_dir/package.yaml"
      if not file.is_file package_yaml_path:
        if file.is_directory package_yaml_path:
          throw "package.yaml is a directory in $git_url"
        // Create an empty package.yaml file, so that we can safely call
        // toit.pkg without worrying that we use some file from a folder
        // above our tmp directory.
        write_blob_to_file package_yaml_path #[]

      sdk.pkg_install --project_root=clone_dir

      // TODO(florian): move into the clone_dir and compile from there.
      // Otherwise we have unnecessary absolute paths in the snapshot.
      sdk.compile_to_snapshot entrypoint_path --out=output_path


  type -> string:
    return "path"

  to_json -> Map:
    result := { "entrypoint": entrypoint }
    if git_url: result["git"] = git_url
    if git_ref: result["branch"] = git_ref
    return result

class ContainerSnapshot implements Container:
  snapshot_path/string

  constructor --.snapshot_path:

  constructor.from_json data/Map:
    return ContainerSnapshot --snapshot_path=data["snapshot"]

  build_snapshot --relative_to/string --output_path/string --sdk/Sdk --cache/cli.Cache:
    path := snapshot_path
    if fs.is_relative snapshot_path:
      path = "$relative_to/$snapshot_path"
    copy_file --source=path --target=output_path

  type -> string:
    return "snapshot"

  to_json -> Map:
    return { "snapshot": snapshot_path}
