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

class DeviceSpecificationException:
  message/string

  constructor .message:

  stringify -> string:
    return message

format_error_ message/string:
  throw (DeviceSpecificationException message)

check_has_key_ map/Map --holder/string="device specification" key/string:
  if not map.contains key:
    format_error_ "Missing $key in $holder."

check_is_map_ map/Map key/string --entry_type/string="Entry":
  get_map_ map key --entry_type=entry_type

get_int_ map/Map key/string -> int
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not int:
    format_error_ "$entry_type $key in $holder is not an int: $value"
  return value

get_string_ map/Map key/string -> string
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not string:
    format_error_ "$entry_type $key in $holder is not a string: $value"
  return value

get_optional_string_ map/Map key/string -> string?
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key: return null
  return get_string_ map key --holder=holder --entry_type=entry_type

get_optional_list_ map/Map key/string --type/string [--check] -> List?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  value := map[key]
  if value is not List:
    format_error_ "$entry_type $key in $holder is not a list: $value"
  value.do:
    if not check.call it:
      format_error_ "$entry_type $key in $holder is not a list of $(type)s: $value"
  return value

get_map_ map/Map key/string -> Map
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not Map:
    format_error_ "$entry_type $key in $holder is not a map: $value"
  return value

get_optional_map_ map/Map key/string -> Map?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_map_ map key --entry_type=entry_type --holder=holder

get_list_ map/Map key/string -> List
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not List:
    format_error_ "$entry_type $key in $holder is not a list: $value"
  return value

get_duration_ map/Map key/string -> Duration
    --entry_type/string="Entry"
    --holder/string="device specification":
  // Parses a string like "1h 30m 10s" or "1h30m10s" into seconds.
  // Returns 0 if the string is empty.

  if not map.contains key:
    format_error_ "Missing $key in $holder."

  entry := map[key]
  if entry is not string:
    format_error_ "$entry_type $key in $holder is not a string: $entry"

  entry_string := entry as string
  entry_string = entry_string.trim
  if entry_string == "": return Duration.ZERO

  return parse_duration entry_string --on_error=:
    format_error_ "$entry_type $key in $holder is not a valid duration: $entry"

get_optional_duration_ map/Map key/string -> Duration?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_duration_ map key --entry_type=entry_type --holder=holder

get_optional_bool_ map/Map key/string -> bool?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_bool_ map key --entry_type=entry_type --holder=holder

get_bool_ map/Map key/string -> bool
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not bool:
    format_error_ "$entry_type $key in $holder is not a boolean: $value"
  return value

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

  constructor.from_json --.path/string data/Map:
    sdk_version = get_string_ data "sdk-version"
    artemis_version = get_string_ data "artemis-version"

    if not data.contains "containers" and not data.contains "apps":
      format_error_ "Missing containers in device specification."

    if data.contains "apps" and data.contains "containers":
      format_error_ "Both 'apps' and 'containers' are present in device specification."

    if (get_int_ data "version") != 1:
      format_error_ "Unsupported device specification version $data["version"]"

    if data.contains "apps" and not data.contains "containers":
      check_is_map_ data "apps"
      data = data.copy
      data["containers"] = data["apps"]
      data.remove "apps"
    else:
      check_is_map_ data "containers"

    data["containers"].do --keys:
      check_is_map_ data["containers"] --entry_type="Container" it

    containers = data["containers"].map: | name container_description |
          Container.from_json name container_description

    connections_entry := get_list_ data "connections"
    connections_entry.do:
      if it is not Map:
        format_error_ "Connection in device specification is not a map: $it"

    connections = data["connections"].map: ConnectionInfo.from_json it

    // TODO(florian): make max-offline optional.
    max_offline_seconds = (get_duration_ data "max-offline").in_s

  static parse path/string -> DeviceSpecification:
    return DeviceSpecification.from_json --path=path (read_json path)

  /**
  Returns the path to which all other paths of this specification are
    relative to.
  */
  relative_to -> string:
    return fs.dirname path

interface ConnectionInfo:
  static from_json data/Map -> ConnectionInfo:
    check_has_key_ data --holder="connection" "type"

    if data["type"] == "wifi":
      return WifiConnectionInfo.from_json data
    if data["type"] == "cellular":
      return CellularConnectionInfo.from_json data
    format_error_ "Unknown connection type: $data["type"]"
    unreachable

  type -> string
  to_json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string
  password/string

  constructor.from_json data/Map:
    ssid = get_string_ data "ssid" --holder="wifi connection"
    password = get_string_ data "password" --holder="wifi connection"

  type -> string:
    return "wifi"

  to_json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

class CellularConnectionInfo implements ConnectionInfo:
  config/Map
  constructor.from_json data/Map:
    config = get_map_ data "config" --holder="cellular connection"

  type -> string:
    return "cellular"

  to_json -> Map:
    return {"type": type}

interface Container:
  static from_json name/string data/Map -> Container:
    if data.contains "entrypoint" and data.contains "snapshot":
      format_error_ "Container $name has both entrypoint and snapshot."

    if data.contains "entrypoint":
      return ContainerPath.from_json name data
    if data.contains "snapshot":
      return ContainerSnapshot.from_json name data

    format_error_ "Unsupported container $name: $data"
    unreachable

  /**
  Builds a snapshot and stores it at the given $output_path.

  All paths in the container are relative to $relative_to.
  */
  build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache
  type -> string
  arguments -> List?
  triggers -> List? // Of type $Trigger.

  static check_arguments_entry arguments:
    if arguments == null: return
    if arguments is not List:
      format_error_ "Arguments entry must be a list: $arguments"
    arguments.do: | argument |
      if argument is not string:
        format_error_ "Arguments entry must be a list of strings: $arguments"

abstract class ContainerBase implements Container:
  arguments/List?
  triggers/List?

  constructor.from_json name/string data/Map:
    holder := "container $name"
    arguments = get_optional_list_ data "arguments"
        --holder=holder
        --type="string"
        --check=: it is string
    triggers_list := get_optional_list_ data "triggers"
        --holder=holder
        --type="map or string"
        --check=: it is Map or it is string
    if triggers_list:
      triggers = triggers_list.map: Trigger.from_json name it
      seen_types := {}
      triggers.do: | trigger/Trigger |
        if seen_types.contains trigger.type:
          format_error_ "Duplicate trigger '$trigger.type' in container $name"
        seen_types.add trigger.type
    else:
      triggers = null

  abstract type -> string
  abstract build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache

class ContainerPath extends ContainerBase:
  entrypoint/string
  git_url/string?
  git_ref/string?

  constructor.from_json name/string data/Map:
    holder := "container $name"
    git_ref = get_optional_string_ data "branch" --holder=holder
    git_url = get_optional_string_ data "git" --holder=holder
    entrypoint = get_string_ data "entrypoint" --holder=holder
    if git_url and not git_ref:
      format_error_ "In container $name, git entry requires a branch/tag: $git_url"
    if git_url and not fs.is_relative entrypoint:
      format_error_"In container $name, git entry requires a relative path: $entrypoint"
    super.from_json name data

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

class ContainerSnapshot extends ContainerBase:
  snapshot_path/string

  constructor.from_json name/string data/Map:
    holder := "container $name"
    snapshot_path = get_string_ data "snapshot" --holder=holder
    super.from_json name data

  build_snapshot --relative_to/string --output_path/string --sdk/Sdk --cache/cli.Cache:
    path := snapshot_path
    if fs.is_relative snapshot_path:
      path = "$relative_to/$snapshot_path"
    copy_file --source=path --target=output_path

  type -> string:
    return "snapshot"

abstract class Trigger:
  static INTERVAL ::= "interval"
  static BOOT ::= "boot"
  static INSTALL ::= "install"

  abstract type -> string
  /**
  A value that is associated with the trigger.
  This is the value that is sent in the goal state.
  Triggers that don't have any value should use 1.
  */
  abstract json_value -> any

  constructor:

  constructor.from_json container_name/string data/any:
    known_triggers := {
      "boot": :: BootTrigger,
      "install": :: InstallTrigger,
      "interval": :: IntervalTrigger.from_json container_name it,
    }
    map_triggers := { "interval" }

    seen_types := {}
    trigger/Lambda? := null
    known_triggers.do: | key/string value/Lambda |
      is_map_trigger := map_triggers.contains key
      if is_map_trigger and data is Map:
        if data.contains key:
          seen_types.add key
          trigger = value
      else if not is_map_trigger and data is string:
        if data == key:
          seen_types.add key
          trigger = value
    if seen_types.size == 0:
      format_error_ "Unknown trigger in container $container_name: $data"
    if seen_types.size != 1:
      format_error_ "Container $container_name has ambiguous trigger: $data"

    return trigger.call data

class IntervalTrigger extends Trigger:
  interval/Duration

  constructor .interval:

  constructor.from_json container_name/string data/Map:
    holder := "trigger in container $container_name"
    interval = get_duration_ data "interval" --holder=holder

  type -> string:
    return Trigger.INTERVAL

  json_value -> int:
    return interval.in_s

class BootTrigger extends Trigger:
  type -> string:
    return Trigger.BOOT

  json_value -> int:
    return 1

class InstallTrigger extends Trigger:
  type -> string:
    return Trigger.INSTALL

  json_value -> int:
    return 1
